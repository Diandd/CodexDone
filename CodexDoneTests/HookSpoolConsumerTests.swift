import Darwin
import Foundation
import Testing

@testable import CodexDone

private actor HookEventCollector {
  private(set) var events: [DesktopCompletionHookEvent] = []
  func append(_ event: DesktopCompletionHookEvent) { events.append(event) }
}
@MainActor
struct HookSpoolConsumerTests {
  @Test("Spool 按时间重放并删除已消费与损坏文件")
  func drainsSpool() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .millisecondsSince1970
    let events = [
      DesktopCompletionHookEvent(
        eventID: UUID(), eventName: .userPromptSubmit, sessionID: "s", turnID: "t",
        workingDirectory: "/tmp/Safe", receivedAt: Date(timeIntervalSince1970: 1)),
      DesktopCompletionHookEvent(
        eventID: UUID(), eventName: .stop, sessionID: "s", turnID: "t",
        workingDirectory: "/tmp/Safe", receivedAt: Date(timeIntervalSince1970: 2)),
    ]
    for (index, event) in events.enumerated() {
      let file = root.appendingPathComponent("\(index).json")
      try encoder.encode(event).write(to: file)
      try FileManager.default.setAttributes(
        [.modificationDate: Date(timeIntervalSince1970: TimeInterval(index + 1))],
        ofItemAtPath: file.path
      )
    }
    try Data("not-json".utf8).write(to: root.appendingPathComponent("bad.json"))
    let consumer = HookSpoolConsumer(directoryURL: root)
    let collector = HookEventCollector()

    let delivered = await consumer.drain { event in
      await collector.append(event)
      return true
    }
    let collected = await collector.events

    #expect(delivered == 2)
    #expect(collected.map(\.eventName) == [.userPromptSubmit, .stop])
    #expect(await consumer.pendingCount() == 0)
  }

  @Test("开发期 Spool 版本不匹配时直接删除且不投递")
  func discardsUnsupportedSpoolVersion() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let event = DesktopCompletionHookEvent(
      eventID: UUID(),
      eventName: .stop,
      sessionID: "unsupported-session",
      turnID: "unsupported-turn",
      workingDirectory: "/tmp/Safe",
      receivedAt: .now
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .millisecondsSince1970
    var object = try #require(
      JSONSerialization.jsonObject(with: encoder.encode(event)) as? [String: Any]
    )
    object["version"] = 1
    try JSONSerialization.data(withJSONObject: object)
      .write(to: root.appendingPathComponent("unsupported.json"))
    let consumer = HookSpoolConsumer(directoryURL: root)
    let collector = HookEventCollector()

    let delivered = await consumer.drain { event in
      await collector.append(event)
      return true
    }
    let collected = await collector.events

    #expect(delivered == 0)
    #expect(collected.isEmpty)
    #expect(await consumer.pendingCount() == 0)
  }

  @Test("升级后继续消费 0.2 Bridge 留下的 v4 Spool")
  func acceptsReleasedV020SpoolEvent() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let event = DesktopCompletionHookEvent(
      eventID: UUID(),
      eventName: .userPromptSubmit,
      sessionID: "released-session",
      turnID: "released-turn",
      workingDirectory: "/tmp/ReleasedProject",
      conversationTitle: "来自 0.2 的事件",
      receivedAt: .now
    )
    try releasedV020EventData(event).write(to: root.appendingPathComponent("released.json"))
    let consumer = HookSpoolConsumer(directoryURL: root)
    let collector = HookEventCollector()

    let delivered = await consumer.drain { received in
      await collector.append(received)
      return true
    }
    let received = await collector.events.first

    #expect(delivered == 1)
    #expect(received?.version == DesktopCompletionHookEvent.releasedSchemaVersion)
    #expect(received?.suppressedByRule == false)
    #expect(received?.conversationTitle == "来自 0.2 的事件")
    #expect(await consumer.pendingCount() == 0)
  }

  @Test("持久化失败时保留 Spool，重复 eventID 可在恢复后补写并删除")
  func retainsSpoolUntilDuplicateEventPersists() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let spool = root.appendingPathComponent("spool")
    let stateURL = root.appendingPathComponent("state.json")
    try FileManager.default.createDirectory(at: spool, withIntermediateDirectories: true)

    let persistence = CompletionPersistence(fileURL: stateURL)
    let store = DesktopCompletionStore(persistence: persistence)
    await store.load()
    try FileManager.default.createDirectory(at: stateURL, withIntermediateDirectories: true)

    let event = DesktopCompletionHookEvent(
      eventID: UUID(),
      eventName: .userPromptSubmit,
      sessionID: "retry-session",
      turnID: "retry-turn",
      workingDirectory: "/tmp/Safe",
      receivedAt: .now
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .millisecondsSince1970
    try encoder.encode(event).write(to: spool.appendingPathComponent("event.json"))
    let consumer = HookSpoolConsumer(directoryURL: spool)

    let firstDrain = await consumer.drain { event in
      await store.handlePersisting(event, deliveryMode: .live)
    }
    #expect(firstDrain == 0)
    #expect(await consumer.pendingCount() == 1)
    #expect(store.persistenceErrorMessage != nil)

    try FileManager.default.removeItem(at: stateURL)
    let secondDrain = await consumer.drain { event in
      await store.handlePersisting(event, deliveryMode: .live)
    }
    #expect(secondDrain == 1)
    #expect(await consumer.pendingCount() == 0)
    #expect(store.persistenceErrorMessage == nil)

    let restored = DesktopCompletionStore(persistence: persistence)
    await restored.load()
    #expect(restored.sessions["retry-session"]?.phase == .running)
  }

  @Test("Stop 首次持久化失败不防抖提醒，恢复后重投只提醒一次")
  func failedStopPersistenceDoesNotAlertBeforeRetry() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let spool = root.appendingPathComponent("spool")
    let stateURL = root.appendingPathComponent("state.json")
    try FileManager.default.createDirectory(at: spool, withIntermediateDirectories: true)

    let persistence = CompletionPersistence(fileURL: stateURL)
    let store = DesktopCompletionStore(persistence: persistence)
    await store.load()
    let promptEvent = DesktopCompletionHookEvent(
      eventID: UUID(),
      eventName: .userPromptSubmit,
      sessionID: "retry-stop-session",
      turnID: "retry-stop-turn",
      workingDirectory: "/tmp/Safe",
      receivedAt: .now.addingTimeInterval(-1)
    )
    #expect(await store.handlePersisting(promptEvent, deliveryMode: .live))
    #expect(store.sessions["retry-stop-session"]?.phase == .running)
    try FileManager.default.removeItem(at: stateURL)
    try FileManager.default.createDirectory(at: stateURL, withIntermediateDirectories: true)

    let event = DesktopCompletionHookEvent(
      eventID: UUID(),
      eventName: .stop,
      sessionID: "retry-stop-session",
      turnID: "retry-stop-turn",
      workingDirectory: "/tmp/Safe",
      receivedAt: .now
    )
    try write(event, to: spool.appendingPathComponent("event.json"))
    let consumer = HookSpoolConsumer(directoryURL: spool)
    var deliveredIDs: [String] = []
    store.onReadyToReview = { deliveredIDs.append($0.id) }

    let firstDrain = await consumer.drain { event in
      await store.handlePersisting(event, deliveryMode: .live)
    }
    #expect(firstDrain == 0)
    #expect(await consumer.pendingCount() == 1)
    try await Task.sleep(for: .milliseconds(1_650))
    #expect(deliveredIDs.isEmpty)
    #expect(store.unreadCount == 0)
    #expect(store.sessions["retry-stop-session"]?.phase == .running)

    try FileManager.default.removeItem(at: stateURL)
    let secondDrain = await consumer.drain { event in
      await store.handlePersisting(event, deliveryMode: .live)
    }
    #expect(secondDrain == 1)
    #expect(await consumer.pendingCount() == 0)
    try await Task.sleep(for: .milliseconds(1_650))
    #expect(deliveredIDs == [event.eventID.uuidString.lowercased()])
    #expect(store.unreadCount == 1)
    #expect(store.sessions["retry-stop-session"]?.phase == .readyToReview)

    await store.handlePersisting(event, deliveryMode: .live)
    try await Task.sleep(for: .milliseconds(100))
    #expect(deliveredIDs.count == 1)
    #expect(store.unreadCount == 1)
  }

  @Test("Stop 持久化失败后跨重启由 Spool 恢复且不补发第二次提醒")
  func failedStopPersistenceRetriesAcrossRestart() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let spool = root.appendingPathComponent("spool")
    let stateURL = root.appendingPathComponent("state.json")
    try FileManager.default.createDirectory(at: spool, withIntermediateDirectories: true)

    let persistence = CompletionPersistence(fileURL: stateURL)
    let firstStore = DesktopCompletionStore(persistence: persistence)
    await firstStore.load()
    let promptEvent = DesktopCompletionHookEvent(
      eventID: UUID(),
      eventName: .userPromptSubmit,
      sessionID: "restart-stop-session",
      turnID: "restart-stop-turn",
      workingDirectory: "/tmp/Safe",
      receivedAt: .now.addingTimeInterval(-1)
    )
    #expect(await firstStore.handlePersisting(promptEvent, deliveryMode: .live))
    let durableRunningState = try Data(contentsOf: stateURL)
    try FileManager.default.removeItem(at: stateURL)
    try FileManager.default.createDirectory(at: stateURL, withIntermediateDirectories: true)

    let event = DesktopCompletionHookEvent(
      eventID: UUID(),
      eventName: .stop,
      sessionID: "restart-stop-session",
      turnID: "restart-stop-turn",
      workingDirectory: "/tmp/Safe",
      receivedAt: .now
    )
    try write(event, to: spool.appendingPathComponent("event.json"))
    let consumer = HookSpoolConsumer(directoryURL: spool)
    var firstDeliveries = 0
    firstStore.onReadyToReview = { _ in firstDeliveries += 1 }

    #expect(await consumer.drain { event in
      await firstStore.handlePersisting(event, deliveryMode: .live)
    } == 0)
    try await Task.sleep(for: .milliseconds(1_650))
    #expect(firstDeliveries == 0)
    #expect(await consumer.pendingCount() == 1)

    try FileManager.default.removeItem(at: stateURL)
    try durableRunningState.write(to: stateURL, options: .atomic)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: stateURL.path
    )
    let retryStore = DesktopCompletionStore(persistence: persistence)
    await retryStore.load()
    #expect(retryStore.sessions["restart-stop-session"]?.phase == .running)
    var retryDeliveries = 0
    retryStore.onReadyToReview = { _ in retryDeliveries += 1 }
    #expect(await consumer.drain { event in
      await retryStore.handlePersisting(event, deliveryMode: .live)
    } == 1)
    try await Task.sleep(for: .milliseconds(1_650))
    #expect(retryDeliveries == 1)
    #expect(retryStore.unreadCount == 1)
    #expect(await retryStore.flushPersistence())

    let restoredStore = DesktopCompletionStore(persistence: persistence)
    var restoredDeliveries = 0
    restoredStore.onReadyToReview = { _ in restoredDeliveries += 1 }
    await restoredStore.load()
    try await Task.sleep(for: .milliseconds(100))
    #expect(restoredStore.unreadCount == 1)
    #expect(restoredDeliveries == 0)
  }

  @Test("Socket 仅在处理链确认成功后回复固定 ACK")
  func socketAcknowledgesOnlySuccessfulHandoff() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let socketURL = root.appendingPathComponent("bridge.sock")
    let server = HookSocketServer(socketURL: socketURL)
    let collector = HookEventCollector()
    try server.start { event in
      await collector.append(event)
      return event.eventName == .userPromptSubmit
    }
    defer { server.stop() }

    let directoryPermissions = try FileManager.default.attributesOfItem(atPath: root.path)[
      .posixPermissions
    ] as? NSNumber
    let socketPermissions = try FileManager.default.attributesOfItem(atPath: socketURL.path)[
      .posixPermissions
    ] as? NSNumber
    #expect(directoryPermissions?.intValue == 0o700)
    #expect(socketPermissions?.intValue == 0o600)

    let accepted = DesktopCompletionHookEvent(
      eventID: UUID(),
      eventName: .userPromptSubmit,
      sessionID: "socket-session",
      turnID: "turn-1",
      workingDirectory: "/tmp/Safe",
      receivedAt: .now
    )
    let rejected = DesktopCompletionHookEvent(
      eventID: UUID(),
      eventName: .stop,
      sessionID: "socket-session",
      turnID: "turn-1",
      workingDirectory: "/tmp/Safe",
      receivedAt: .now
    )

    #expect(try send(accepted, to: socketURL) == HookSocketServer.acknowledgementByte)
    #expect(
      try sendRaw(releasedV020EventData(accepted), to: socketURL)
        == HookSocketServer.acknowledgementByte
    )
    #expect(try send(rejected, to: socketURL) == nil)
    #expect(try sendRaw(Data("not-json".utf8), to: socketURL) == nil)
    let collectedCount = await collector.events.count
    #expect(collectedCount == 3)
  }

  @Test("Socket 目录无法设为私有时启动硬失败")
  func socketFailsWhenPrivateDirectoryCannotBePrepared() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let blocker = root.appendingPathComponent("not-a-directory")
    try Data().write(to: blocker)
    let server = HookSocketServer(socketURL: blocker.appendingPathComponent("bridge.sock"))

    #expect(throws: HookSocketServerError.self) {
      try server.start { _ in true }
    }
  }

  private func send(
    _ event: DesktopCompletionHookEvent,
    to socketURL: URL
  ) throws -> UInt8? {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .millisecondsSince1970
    return try sendRaw(encoder.encode(event), to: socketURL)
  }

  private func write(_ event: DesktopCompletionHookEvent, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .millisecondsSince1970
    try encoder.encode(event).write(to: url)
  }

  private func releasedV020EventData(_ event: DesktopCompletionHookEvent) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .millisecondsSince1970
    var object = try #require(
      JSONSerialization.jsonObject(with: encoder.encode(event)) as? [String: Any]
    )
    object["version"] = DesktopCompletionHookEvent.releasedSchemaVersion
    object.removeValue(forKey: "suppressedByRule")
    return try JSONSerialization.data(withJSONObject: object)
  }

  private func sendRaw(_ data: Data, to socketURL: URL) throws -> UInt8? {
    let client = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard client >= 0 else { throw SocketTestError.socketCreationFailed }
    defer { Darwin.close(client) }

    let pathBytes = Array(socketURL.path.utf8) + [UInt8.zero]
    var address = sockaddr_un()
    guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
      throw SocketTestError.pathTooLong
    }
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { destination in
      destination.copyBytes(from: pathBytes)
    }
    let connected = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(client, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard connected == 0 else { throw SocketTestError.connectFailed }

    let written = data.withUnsafeBytes { bytes in
      Darwin.write(client, bytes.baseAddress, bytes.count)
    }
    guard written == data.count else { throw SocketTestError.writeFailed }
    Darwin.shutdown(client, SHUT_WR)

    var pollDescriptor = pollfd(fd: client, events: Int16(POLLIN), revents: 0)
    guard Darwin.poll(&pollDescriptor, 1, 1_000) > 0 else {
      throw SocketTestError.responseTimedOut
    }
    var byte: UInt8 = 0
    let count = Darwin.read(client, &byte, MemoryLayout<UInt8>.size)
    return count == 1 ? byte : nil
  }
}

private enum SocketTestError: Error {
  case socketCreationFailed
  case pathTooLong
  case connectFailed
  case writeFailed
  case responseTimedOut
}
