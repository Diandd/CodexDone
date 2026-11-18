import Darwin
import Foundation
import Testing

@testable import CodexDone

@Suite(.serialized)
struct HookBridgeProcessTests: Sendable {
  @Test("后台进程继承的终端环境变量不会被当作跳转目标")
  func ignoresInheritedTerminalIdentityWithoutTerminal() throws {
    try checkTerminalIdentity(throughTerminal: false)
  }

  @Test("终端任务通过管道发送 Hook 时保留终端标识")
  func preservesTerminalIdentityWithPipedInput() throws {
    try checkTerminalIdentity(throughTerminal: true)
  }

  private func checkTerminalIdentity(throughTerminal: Bool) throws {
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let spool = root.appendingPathComponent("spool")
    let terminalID = "12345678-1234-1234-1234-123456789ABC"
    _ = try run(helper: helperURL(), root: root, spool: spool,
      terminalSessionID: "w0t1p0:" + terminalID, throughTerminal: throughTerminal,
      input: Data(#"{"hook_event_name":"UserPromptSubmit","session_id":"terminal-test","turn_id":"t1"}"#.utf8))
    let file = try #require(try jsonFiles(in: spool).first)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .millisecondsSince1970
    let event = try decoder.decode(DesktopCompletionHookEvent.self, from: Data(contentsOf: file))
    #expect(event.terminalSessionID == (throughTerminal ? terminalID : nil))
  }

  @Test("Bridge 的 stdout 和 Spool 只包含有界派生内容")
  func bridgeProcessContract() throws {
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let spool = root.appendingPathComponent("spool")
    let helper = try helperURL()

    let promptOutput = try run(
      helper: helper,
      root: root,
      spool: spool,
      input: Data(
        ###"{"hook_event_name":"UserPromptSubmit","session_id":"s","turn_id":"t1","cwd":"/tmp/Safe","prompt":"## My request:\n# 修复菜单信息层级","transcript_path":"/private/secret.jsonl"}"###.utf8
      )
    )
    #expect(promptOutput.isEmpty)
    let stopOutput = try run(
      helper: helper,
      root: root,
      spool: spool,
      input: Data(
        #"{"hook_event_name":"Stop","session_id":"s","turn_id":"t1","cwd":"/tmp/Safe","last_assistant_message":"已完成菜单布局并保留项目说明。","transcript_path":"/private/secret.jsonl"}"#.utf8
      )
    )
    #expect(stopOutput == #"{"continue":true}"#)

    let allFiles = try FileManager.default.contentsOfDirectory(
      at: spool,
      includingPropertiesForKeys: nil
    )
    let files = allFiles.filter { $0.pathExtension == "json" }
    #expect(files.count == 2)
    #expect(!allFiles.contains { $0.pathExtension == "tmp" })
    let directoryMode = try FileManager.default.attributesOfItem(atPath: spool.path)[
      .posixPermissions
    ] as? NSNumber
    #expect(directoryMode?.intValue == 0o700)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .millisecondsSince1970
    var events: [DesktopCompletionHookEvent] = []
    for file in files {
      let fileMode = try FileManager.default.attributesOfItem(atPath: file.path)[
        .posixPermissions
      ] as? NSNumber
      #expect(fileMode?.intValue == 0o600)
      let text = try String(contentsOf: file, encoding: .utf8)
      #expect(!text.contains("\"prompt\""))
      #expect(!text.contains("last_assistant_message"))
      #expect(!text.contains("tool_name"))
      #expect(!text.contains("tool_input"))
      #expect(!text.contains("private command"))
      #expect(!text.contains("private reason"))
      #expect(!text.contains("transcript"))
      events.append(try decoder.decode(DesktopCompletionHookEvent.self, from: Data(text.utf8)))
    }
    #expect(events.first { $0.eventName == .userPromptSubmit }?.conversationTitle == "修复菜单信息层级")
    #expect(events.first { $0.eventName == .stop }?.replyPreview == "已完成菜单布局并保留项目说明。")
  }

  @Test("超过四 MiB 的合法 Stop 仍返回固定 stdout 且不进入 IPC")
  func oversizedStopStillReturnsContinue() throws {
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let spool = root.appendingPathComponent("spool")
    var input = Data(#"{"prompt":""#.utf8)
    input.append(
      Data(
        repeating: 0x61,
        count: HookPayloadSanitizer.maximumPayloadBytes + 1_024
      )
    )
    input.append(
      Data(
        #"","hook_event_name":"Stop","session_id":"oversized","turn_id":"t1"}"#.utf8
      )
    )

    let output = try run(
      helper: try helperURL(),
      root: root,
      spool: spool,
      input: input
    )

    #expect(output == #"{"continue":true}"#)
    #expect(try jsonFiles(in: spool).isEmpty)
  }

  @Test("真实 Bridge 匹配发送与回复规则且只输出屏蔽布尔值")
  func bridgeReadsSuppressionRulesWithoutLeakingRuleText() throws {
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let spool = root.appendingPathComponent("spool")
    let rulesURL = root.appendingPathComponent("rules.json")
    let privateKeyword = "DO-NOT-ALERT-PRIVATE"
    let privateRegex = #"DO-NOT-(?:ALERT|NOTIFY)-REGEX"#
    let privateReplyRegex = #"FINAL-(?:ANSWER|REPLY)-MUTED"#
    try AlertSuppressionRulesFile.save(
      AlertSuppressionRules(
        submittedMessageKeywords: [privateKeyword],
        submittedMessageRegexPatterns: [privateRegex],
        assistantReplyRegexPatterns: [privateReplyRegex]
      ),
      to: rulesURL
    )
    let longPrefix = String(repeating: "前", count: 35)

    let output = try run(
      helper: try helperURL(),
      root: root,
      spool: spool,
      suppressionRulesURL: rulesURL,
      input: Data(
        """
        {"hook_event_name":"UserPromptSubmit","session_id":"blocked","turn_id":"t1","cwd":"/tmp/Safe","prompt":"## My request:\\n\(longPrefix) \(privateKeyword)"}
        """.utf8
      )
    )

    #expect(output.isEmpty)
    let file = try #require(try jsonFiles(in: spool).first)
    let data = try Data(contentsOf: file)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .millisecondsSince1970
    let event = try decoder.decode(DesktopCompletionHookEvent.self, from: data)
    #expect(event.suppressedByRule)
    #expect(!String(decoding: data, as: UTF8.self).contains(privateKeyword))

    let regexOutput = try run(
      helper: try helperURL(),
      root: root,
      spool: spool,
      suppressionRulesURL: rulesURL,
      input: Data(
        """
        {"hook_event_name":"UserPromptSubmit","session_id":"blocked-regex","turn_id":"t2","cwd":"/tmp/Safe","prompt":"## My request:\\nDO-NOT-NOTIFY-REGEX"}
        """.utf8
      )
    )
    #expect(regexOutput.isEmpty)
    let regexFile = try #require(
      try jsonFiles(in: spool).first(where: { $0 != file })
    )
    let regexData = try Data(contentsOf: regexFile)
    let regexEvent = try decoder.decode(DesktopCompletionHookEvent.self, from: regexData)
    #expect(regexEvent.suppressedByRule)
    #expect(!String(decoding: regexData, as: UTF8.self).contains(privateRegex))

    let replyOutput = try run(
      helper: try helperURL(),
      root: root,
      spool: spool,
      suppressionRulesURL: rulesURL,
      input: Data(
        """
        {"hook_event_name":"Stop","session_id":"blocked-reply","turn_id":"t3","cwd":"/tmp/Safe","last_assistant_message":"The FINAL-REPLY-MUTED response is ready"}
        """.utf8
      )
    )
    #expect(replyOutput == #"{"continue":true}"#)
    let replyFile = try #require(
      try jsonFiles(in: spool).first(where: { $0 != file && $0 != regexFile })
    )
    let replyData = try Data(contentsOf: replyFile)
    let replyEvent = try decoder.decode(DesktopCompletionHookEvent.self, from: replyData)
    #expect(replyEvent.suppressedByRule)
    #expect(!String(decoding: replyData, as: UTF8.self).contains(privateReplyRegex))
  }

  @Test("真实 Bridge 在规则文件缺失时应用可见默认屏蔽项")
  func bridgeUsesProductDefaultsWhenRulesFileIsMissing() throws {
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let spool = root.appendingPathComponent("spool")
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .millisecondsSince1970

    let promptOutput = try run(
      helper: try helperURL(),
      root: root,
      spool: spool,
      input: Data(
        #"{"hook_event_name":"UserPromptSubmit","session_id":"internal-root","turn_id":"t1","cwd":"/","prompt":"internal request"}"#.utf8
      )
    )
    #expect(promptOutput.isEmpty)
    let promptFile = try #require(try jsonFiles(in: spool).first)
    let promptEvent = try decoder.decode(
      DesktopCompletionHookEvent.self,
      from: Data(contentsOf: promptFile)
    )
    #expect(promptEvent.suppressedByRule)

    let stopOutput = try run(
      helper: try helperURL(),
      root: root,
      spool: spool,
      input: Data(
        #"{"hook_event_name":"Stop","session_id":"internal-suggestions","turn_id":"t2","cwd":"/tmp/CodexDone","last_assistant_message":"{\"suggestions\":[{\"title\":\"internal\",\"description\":\"fixture\"}]}"}"#.utf8
      )
    )
    #expect(stopOutput == #"{"continue":true}"#)
    let stopFile = try #require(try jsonFiles(in: spool).first(where: { $0 != promptFile }))
    let stopEvent = try decoder.decode(
      DesktopCompletionHookEvent.self,
      from: Data(contentsOf: stopFile)
    )
    #expect(stopEvent.suppressedByRule)
  }

  @Test("真实 Socket 只有收到 0x06 ACK 才跳过 Spool")
  func socketAcknowledgementAvoidsSpool() throws {
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let spool = root.appendingPathComponent("spool")
    let socketURL = root.appendingPathComponent("bridge.sock")
    let server = try LocalSocketTestServer(
      socketURL: socketURL,
      response: .acknowledgement(0x06, delay: 0)
    )

    let output = try run(
      helper: try helperURL(),
      root: root,
      spool: spool,
      socketURL: socketURL,
      input: Data(
        ###"{"hook_event_name":"UserPromptSubmit","session_id":"socket-session","turn_id":"t1","prompt":"## My request:\n修复菜单信息层级"}"###.utf8
      )
    )
    let receivedData = try #require(server.waitForPayload())
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .millisecondsSince1970
    let receivedEvent = try decoder.decode(DesktopCompletionHookEvent.self, from: receivedData)

    #expect(output.isEmpty)
    #expect(receivedEvent.eventName == .userPromptSubmit)
    #expect(receivedEvent.sessionID == "socket-session")
    #expect(receivedEvent.conversationTitle == "修复菜单信息层级")
    #expect(!String(decoding: receivedData, as: UTF8.self).contains("\"prompt\""))
    #expect(try jsonFiles(in: spool).isEmpty)
  }

  @Test("错误、缺失或超时 ACK 都回退到原子 Spool")
  func invalidAcknowledgementsFallBackToSpool() throws {
    let responses: [LocalSocketTestServer.Response] = [
      .acknowledgement(0x15, delay: 0),
      .closeWithoutAcknowledgement,
      .acknowledgement(0x06, delay: 0.1),
    ]

    for (index, response) in responses.enumerated() {
      let root = try makeTemporaryRoot()
      defer { try? FileManager.default.removeItem(at: root) }
      let spool = root.appendingPathComponent("spool")
      let socketURL = root.appendingPathComponent("bridge.sock")
      let server = try LocalSocketTestServer(socketURL: socketURL, response: response)
      let output = try run(
        helper: try helperURL(),
        root: root,
        spool: spool,
        socketURL: socketURL,
        input: Data(
          """
          {"hook_event_name":"Stop","session_id":"fallback-\(index)","turn_id":"t1"}
          """.utf8
        )
      )

      #expect(output == #"{"continue":true}"#)
      #expect(server.waitForPayload() != nil)
      #expect(try jsonFiles(in: spool).count == 1)
    }
  }

  @Test("Socket 不可达只写 Spool，不启动主应用")
  func socketFailureSpoolsWithoutLaunchingApplication() throws {
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let spool = root.appendingPathComponent("spool")
    let launchMarker = root.appendingPathComponent("launch-marker.txt")
    let legacyWakeExecutable = root.appendingPathComponent("legacy-wake-test.sh")
    let wakeScript = """
      #!/bin/sh
      printf 'launched\\n' >> "$CODEXDONE_BRIDGE_WAKE_MARKER"
      """
    #expect(
      FileManager.default.createFile(
        atPath: legacyWakeExecutable.path,
        contents: Data(wakeScript.utf8),
        attributes: [.posixPermissions: 0o700]
      )
    )
    let helper = try helperURL()

    let promptOutput = try run(
      helper: helper,
      root: root,
      spool: spool,
      legacyWakeExecutable: legacyWakeExecutable,
      legacyWakeMarker: launchMarker,
      input: Data(
        #"{"hook_event_name":"UserPromptSubmit","session_id":"quit","turn_id":"t1"}"#.utf8
      )
    )
    let stopOutput = try run(
      helper: helper,
      root: root,
      spool: spool,
      legacyWakeExecutable: legacyWakeExecutable,
      legacyWakeMarker: launchMarker,
      input: Data(
        #"{"hook_event_name":"Stop","session_id":"quit","turn_id":"t1"}"#.utf8
      )
    )

    #expect(promptOutput.isEmpty)
    #expect(stopOutput == #"{"continue":true}"#)
    #expect(try jsonFiles(in: spool).count == 2)
    #expect(!FileManager.default.fileExists(atPath: launchMarker.path))
    #expect(
      !FileManager.default.fileExists(
        atPath: spool.appendingPathComponent(".wake-cooldown").path
      )
    )
  }

  @Test("真实 Helper 经正式 Socket 驱动 Store 完成并由下一 Prompt 清除")
  @MainActor
  func helperSocketStoreLifecycle() async throws {
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let socketURL = root.appendingPathComponent("bridge.sock")
    let spool = root.appendingPathComponent("spool")
    let persistence = CompletionPersistence(fileURL: root.appendingPathComponent("state.json"))
    let store = DesktopCompletionStore(persistence: persistence)
    await store.load()

    var deliveredIDs: [String] = []
    store.onReadyToReview = { deliveredIDs.append($0.id) }

    let server = HookSocketServer(socketURL: socketURL)
    try server.start { event in
      await store.handlePersisting(event, deliveryMode: .live)
    }
    defer { server.stop() }

    let helper = try helperURL()
    let promptOutput = try await Task.detached {
      try run(
        helper: helper,
        root: root,
        spool: spool,
        socketURL: socketURL,
        input: Data(
          #"{"hook_event_name":"UserPromptSubmit","session_id":"e2e-session","turn_id":"turn-1","cwd":"/tmp/Private","prompt":"验证菜单主题与回复预览"}"#.utf8
        )
      )
    }.value
    #expect(promptOutput.isEmpty)
    #expect(store.sessions["e2e-session"]?.phase == .running)

    let stopOutput = try await Task.detached {
      try run(
        helper: helper,
        root: root,
        spool: spool,
        socketURL: socketURL,
        input: Data(
          #"{"hook_event_name":"Stop","session_id":"e2e-session","turn_id":"turn-1","cwd":"/tmp/Private","last_assistant_message":"已生成用于端到端验证的回复预览。"}"#.utf8
        )
      )
    }.value
    #expect(stopOutput == #"{"continue":true}"#)

    try await Task.sleep(for: .milliseconds(1_650))
    #expect(store.unreadCount == 1)
    #expect(store.sessions["e2e-session"]?.phase == .readyToReview)
    #expect(deliveredIDs.count == 1)
    #expect(store.unreadRecords.first?.conversationTitle == "验证菜单主题与回复预览")
    #expect(store.unreadRecords.first?.replyPreview == "已生成用于端到端验证的回复预览。")

    let nextPromptOutput = try await Task.detached {
      try run(
        helper: helper,
        root: root,
        spool: spool,
        socketURL: socketURL,
        input: Data(
          #"{"hook_event_name":"UserPromptSubmit","session_id":"e2e-session","turn_id":"turn-2","cwd":"/tmp/Private","prompt":"验证下一轮自动清除"}"#.utf8
        )
      )
    }.value
    #expect(nextPromptOutput.isEmpty)
    #expect(store.unreadCount == 0)
    #expect(store.sessions["e2e-session"]?.phase == .running)
    #expect(store.records.first?.conversationTitle == nil)
    #expect(store.records.first?.replyPreview == nil)
    #expect(try jsonFiles(in: spool).isEmpty)
  }

  private func makeTemporaryRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("cdb-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  private func helperURL() throws -> URL {
    let helper = Bundle.main.bundleURL
      .appendingPathComponent("Contents/Helpers/CodexDoneHookBridge")
    return try #require(
      FileManager.default.isExecutableFile(atPath: helper.path) ? helper : nil
    )
  }

  private func jsonFiles(in directoryURL: URL) throws -> [URL] {
    guard FileManager.default.fileExists(atPath: directoryURL.path) else { return [] }
    return try FileManager.default.contentsOfDirectory(
      at: directoryURL,
      includingPropertiesForKeys: nil
    ).filter { $0.pathExtension == "json" }
  }

  private func run(
    helper: URL,
    root: URL,
    spool: URL,
    socketURL: URL? = nil,
    suppressionRulesURL: URL? = nil,
    legacyWakeExecutable: URL? = nil,
    legacyWakeMarker: URL? = nil,
    terminalSessionID: String? = nil,
    throughTerminal: Bool = false,
    input: Data
  ) throws -> String {
    let process = Process()
    let inputPipe = Pipe()
    let outputPipe = Pipe()
    var environment = ProcessInfo.processInfo.environment
    environment.removeValue(forKey: "CODEXDONE_BRIDGE_WAKE_EXECUTABLE")
    environment.removeValue(forKey: "CODEXDONE_BRIDGE_WAKE_MARKER")
    environment["ITERM_SESSION_ID"] = terminalSessionID
    environment["CODEXDONE_BRIDGE_SOCKET_PATH"] = (
      socketURL ?? root.appendingPathComponent("missing.sock")
    ).path
    environment["CODEXDONE_BRIDGE_SPOOL_DIR"] = spool.path
    environment["CODEXDONE_BRIDGE_SUPPRESSION_RULES_PATH"] = (
      suppressionRulesURL ?? root.appendingPathComponent("rules.json")
    ).path
    if let legacyWakeExecutable {
      environment["CODEXDONE_BRIDGE_WAKE_EXECUTABLE"] = legacyWakeExecutable.path
    }
    if let legacyWakeMarker {
      environment["CODEXDONE_BRIDGE_WAKE_MARKER"] = legacyWakeMarker.path
    }
    process.executableURL = helper
    process.environment = environment
    process.standardInput = inputPipe
    process.standardOutput = outputPipe
    process.standardError = FileHandle.nullDevice
    if throughTerminal {
      let inputURL = root.appendingPathComponent("terminal-input.json")
      try input.write(to: inputURL)
      process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
      process.arguments = ["-q", "/dev/null", "/bin/sh", "-c", "/bin/cat \"$1\" | \"$0\"",
        helper.path, inputURL.path]
      process.standardInput = FileHandle.nullDevice
    }
    try process.run()
    if !throughTerminal {
      try inputPipe.fileHandleForWriting.write(contentsOf: input)
    }
    try inputPipe.fileHandleForWriting.close()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
    return String(
      decoding: outputPipe.fileHandleForReading.readDataToEndOfFile(),
      as: UTF8.self
    )
  }
}

private final class LocalSocketTestServer: @unchecked Sendable {
  enum Response {
    case acknowledgement(UInt8, delay: TimeInterval)
    case closeWithoutAcknowledgement
  }

  private let socketURL: URL
  private let response: Response
  private let listeningDescriptor: Int32
  private let completion = DispatchSemaphore(value: 0)
  private let stateLock = NSLock()
  private var receivedPayload: Data?

  init(socketURL: URL, response: Response) throws {
    self.socketURL = socketURL
    self.response = response
    listeningDescriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard listeningDescriptor >= 0 else {
      throw Self.posixError(operation: "socket")
    }

    var noSigPipe: Int32 = 1
    guard
      Darwin.setsockopt(
        listeningDescriptor,
        SOL_SOCKET,
        SO_NOSIGPIPE,
        &noSigPipe,
        socklen_t(MemoryLayout<Int32>.size)
      ) == 0
    else {
      throw Self.posixError(operation: "setsockopt")
    }

    let pathBytes = Array(socketURL.path.utf8) + [UInt8.zero]
    guard pathBytes.count <= MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
      throw NSError(
        domain: NSPOSIXErrorDomain,
        code: Int(ENAMETOOLONG),
        userInfo: [NSLocalizedDescriptionKey: "Test socket path is too long"]
      )
    }
    _ = Darwin.unlink(socketURL.path)
    var address = sockaddr_un()
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { destination in
      destination.copyBytes(from: pathBytes)
    }
    let bindResult = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(
          listeningDescriptor,
          $0,
          socklen_t(MemoryLayout<sockaddr_un>.size)
        )
      }
    }
    guard bindResult == 0 else { throw Self.posixError(operation: "bind") }
    guard Darwin.listen(listeningDescriptor, 1) == 0 else {
      throw Self.posixError(operation: "listen")
    }

    DispatchQueue(label: "CodexDoneTests.LocalSocketTestServer").async { [self] in
      serveOneConnection()
    }
  }

  deinit {
    Darwin.close(listeningDescriptor)
    Darwin.unlink(socketURL.path)
  }

  func waitForPayload(timeout: TimeInterval = 2) -> Data? {
    guard completion.wait(timeout: .now() + timeout) == .success else { return nil }
    stateLock.lock()
    defer { stateLock.unlock() }
    return receivedPayload
  }

  private func serveOneConnection() {
    defer { completion.signal() }
    let connection = Darwin.accept(listeningDescriptor, nil, nil)
    guard connection >= 0 else { return }
    defer { Darwin.close(connection) }
    var noSigPipe: Int32 = 1
    _ = Darwin.setsockopt(
      connection,
      SOL_SOCKET,
      SO_NOSIGPIPE,
      &noSigPipe,
      socklen_t(MemoryLayout<Int32>.size)
    )

    var payload = Data()
    var buffer = [UInt8](repeating: 0, count: 4_096)
    while true {
      let count = buffer.withUnsafeMutableBytes { rawBuffer in
        Darwin.read(connection, rawBuffer.baseAddress, rawBuffer.count)
      }
      if count > 0 {
        payload.append(contentsOf: buffer.prefix(count))
      } else if count == 0 {
        break
      } else if errno != EINTR {
        break
      }
    }
    stateLock.lock()
    receivedPayload = payload
    stateLock.unlock()

    switch response {
    case .acknowledgement(var byte, let delay):
      if delay > 0 {
        Thread.sleep(forTimeInterval: delay)
      }
      _ = Darwin.write(connection, &byte, 1)
    case .closeWithoutAcknowledgement:
      break
    }
  }

  private static func posixError(operation: String) -> NSError {
    NSError(
      domain: NSPOSIXErrorDomain,
      code: Int(errno),
      userInfo: [
        NSLocalizedDescriptionKey:
          "\(operation) failed: \(String(cString: strerror(errno)))"
      ]
    )
  }
}
