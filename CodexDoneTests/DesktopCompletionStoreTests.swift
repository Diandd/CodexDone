import Foundation
import Testing

@testable import CodexDone

@Suite(.serialized)
@MainActor
struct DesktopCompletionStoreTests {
  @Test("未读数量变化通过单一 Store 投影通知视觉层")
  func unreadCountChangesAreProjectedFromTheStore() async throws {
    let fixture = try Fixture()
    let store = DesktopCompletionStore(persistence: fixture.persistence)
    await store.load()
    var projectedCounts: [Int] = []
    store.onUnreadCountChanged = { projectedCounts.append($0) }

    store.injectUITestRecords(multipleSessions: true)
    store.acknowledgeAll()

    #expect(projectedCounts == [2, 0])
  }

  @Test("HUD 点击只确认对应会话并保留其他未读")
  func hudClickAcknowledgesOnlyTheMatchingSession() async throws {
    let fixture = try Fixture()
    let store = DesktopCompletionStore(persistence: fixture.persistence)
    await store.load()
    store.injectUITestRecords(multipleSessions: true)
    let sessionID = "ui-test-session-codexdone"
    let recordID = try #require(
      store.unreadRecords.first { $0.sessionID == sessionID }?.id
    )
    var returnedSessionID: String?

    HUDAlertClickAction.perform(
      sessionID: sessionID,
      unreadRecordID: recordID,
      acknowledgeRecord: { store.acknowledge(recordID: $0) },
      returnToCodex: { returnedSessionID = $0 }
    )

    #expect(returnedSessionID == sessionID)
    #expect(store.unreadCount == 1)
    #expect(store.sessions[sessionID]?.phase == .idle)
    #expect(store.sessions["ui-test-session-sprout"]?.phase == .readyToReview)
    #expect(store.unreadRecords.first?.sessionID == "ui-test-session-sprout")
    #expect(await store.flushPersistence())
  }

  @Test("Stop 防抖后只提醒一次，重复事件被去重")
  func stopDebouncesAndDeduplicates() async throws {
    let fixture = try Fixture()
    let store = DesktopCompletionStore(persistence: fixture.persistence)
    await store.load()
    var deliveredIDs: [String] = []
    store.onReadyToReview = { deliveredIDs.append($0.id) }

    let prompt = fixture.event(
      .userPromptSubmit,
      turn: "turn-1",
      conversationTitle: "调整菜单信息层级"
    )
    let stop = fixture.event(
      .stop,
      turn: "turn-1",
      replyPreview: "已完成菜单信息层级调整。"
    )
    #expect(!store.hasProcessedEventID(prompt.eventID))
    await store.handlePersisting(prompt, deliveryMode: .live)
    #expect(store.hasProcessedEventID(prompt.eventID))
    await store.handlePersisting(stop, deliveryMode: .live)
    await store.handlePersisting(stop, deliveryMode: .live)

    #expect(store.unreadCount == 0)
    try await Task.sleep(for: .milliseconds(1_650))
    #expect(store.unreadCount == 1)
    #expect(deliveredIDs.count == 1)
    #expect(store.sessions["session-1"]?.phase == .readyToReview)
    let recordID = try #require(store.unreadRecords.first?.id)
    #expect(store.unreadRecords.first?.conversationTitle == "调整菜单信息层级")
    #expect(store.unreadRecords.first?.replyPreview == "已完成菜单信息层级调整。")

    store.acknowledge(recordID: recordID)
    #expect(await store.flushPersistence())
    #expect(store.records.first?.conversationTitle == nil)
    #expect(store.records.first?.replyPreview == nil)
    #expect(store.sessions["session-1"]?.conversationTitle == nil)
    #expect(store.sessions["session-1"]?.replyPreview == nil)
  }

  @Test("同一 session 的新 Stop 替换旧未读并保持 ready 状态一致")
  func newerStopReplacesUnreadForSameSession() async throws {
    let fixture = try Fixture()
    let store = DesktopCompletionStore(persistence: fixture.persistence)
    await store.load()
    var deliveredIDs: [String] = []
    var dismissedSessionIDs: [String] = []
    store.onReadyToReview = { deliveredIDs.append($0.id) }
    store.onDismissAlert = { dismissedSessionIDs.append($0) }

    await store.handlePersisting(
      fixture.event(.userPromptSubmit, turn: "turn-1"),
      deliveryMode: .live
    )
    let firstStop = fixture.event(.stop, turn: "turn-1")
    await store.handlePersisting(firstStop, deliveryMode: .live)
    try await Task.sleep(for: .milliseconds(1_650))

    #expect(store.unreadCount == 1)
    #expect(store.unreadRecords.first?.id == firstStop.eventID.uuidString.lowercased())
    #expect(store.sessions["session-1"]?.phase == .readyToReview)

    await store.handlePersisting(
      fixture.event(.userPromptSubmit, turn: "turn-2"),
      deliveryMode: .live
    )
    let secondStop = fixture.event(.stop, turn: "turn-2")
    await store.handlePersisting(secondStop, deliveryMode: .live)
    try await Task.sleep(for: .milliseconds(1_650))

    #expect(store.unreadCount == 1)
    #expect(store.unreadRecords.first?.id == secondStop.eventID.uuidString.lowercased())
    #expect(
      store.records.first { $0.id == firstStop.eventID.uuidString.lowercased() }?.isAcknowledged
        == true)
    #expect(store.sessions["session-1"]?.phase == .readyToReview)
    #expect(store.sessions["session-1"]?.turnID == "turn-2")
    #expect(store.sessions["session-1"]?.pendingEventID == nil)
    #expect(
      deliveredIDs == [
        firstStop.eventID.uuidString.lowercased(),
        secondStop.eventID.uuidString.lowercased(),
      ])
    #expect(dismissedSessionIDs == ["session-1"])

    store.acknowledge(recordID: firstStop.eventID.uuidString.lowercased())
    #expect(store.unreadCount == 1)
    #expect(store.sessions["session-1"]?.phase == .readyToReview)
  }

  @Test("排队消息在防抖期间触发新 Prompt 时取消完成提醒")
  func promptCancelsPendingStop() async throws {
    let fixture = try Fixture()
    let store = DesktopCompletionStore(persistence: fixture.persistence)
    await store.load()

    await store.handlePersisting(
      fixture.event(.userPromptSubmit, turn: "turn-1"),
      deliveryMode: .live
    )
    await store.handlePersisting(
      fixture.event(.stop, turn: "turn-1"),
      deliveryMode: .live
    )
    await store.handlePersisting(
      fixture.event(.userPromptSubmit, turn: "turn-2"),
      deliveryMode: .live
    )
    try await Task.sleep(for: .milliseconds(1_650))

    #expect(store.unreadCount == 0)
    #expect(store.sessions["session-1"]?.phase == .running)
  }

  @Test("没有用户 Prompt 的 Stop 不生成后台任务记录")
  func stopWithoutPromptDoesNotCreateRecord() async throws {
    let fixture = try Fixture()
    let store = DesktopCompletionStore(persistence: fixture.persistence)
    await store.load()

    let stop = fixture.event(
      .stop,
      turn: "background-turn",
      replyPreview: #"{"suggestions":[]}"#
    )
    await store.handlePersisting(stop, deliveryMode: .live, ingress: .spool)
    try await Task.sleep(for: .milliseconds(1_650))

    #expect(store.unreadCount == 0)
    #expect(store.records.isEmpty)
    #expect(store.sessions["session-1"]?.phase == .idle)
    #expect(store.hookEventDiagnostics.count == 1)
    #expect(store.hookEventDiagnostics.first?.id == stop.eventID)
    #expect(store.hookEventDiagnostics.first?.ingress == .spool)
    #expect(store.hookEventDiagnostics.first?.payloadKind == .structuredText)
    #expect(store.hookEventDiagnostics.first?.outcome == .ignoredWithoutPrompt)
  }

  @Test("屏蔽的本轮不进入未读且诊断只记录通用结果")
  func suppressedTurnDoesNotCreateUnreadRecord() async throws {
    let fixture = try Fixture()
    let store = DesktopCompletionStore(persistence: fixture.persistence)
    await store.load()
    var deliveredIDs: [String] = []
    store.onReadyToReview = { deliveredIDs.append($0.id) }

    await store.handlePersisting(
      fixture.event(
        .userPromptSubmit,
        turn: "blocked-turn",
        conversationTitle: "无需提醒",
        suppressedByRule: true
      ),
      deliveryMode: .live
    )
    await store.handlePersisting(
      fixture.event(.stop, turn: "blocked-turn", replyPreview: "已完成。"),
      deliveryMode: .live
    )

    #expect(store.unreadCount == 0)
    #expect(deliveredIDs.isEmpty)
    #expect(store.sessions["session-1"]?.phase == .idle)
    #expect(store.hookEventDiagnostics.first?.outcome == .suppressedByRule)
  }

  @Test("回复正则命中的 Stop 不进入未读且不投递提醒")
  func suppressedStopReplyDoesNotCreateUnreadRecord() async throws {
    let fixture = try Fixture()
    let store = DesktopCompletionStore(persistence: fixture.persistence)
    await store.load()
    var deliveredIDs: [String] = []
    store.onReadyToReview = { deliveredIDs.append($0.id) }

    await store.handlePersisting(
      fixture.event(
        .userPromptSubmit,
        turn: "reply-blocked-turn",
        conversationTitle: "检查自动回复"
      ),
      deliveryMode: .live
    )
    await store.handlePersisting(
      fixture.event(
        .stop,
        turn: "reply-blocked-turn",
        replyPreview: "命中回复规则",
        suppressedByRule: true
      ),
      deliveryMode: .live
    )

    #expect(store.unreadCount == 0)
    #expect(deliveredIDs.isEmpty)
    #expect(store.sessions["session-1"]?.phase == .idle)
    #expect(store.hookEventDiagnostics.first?.outcome == .suppressedByRule)
  }

  @Test("诊断记录只保存事件元数据并跟踪防抖结果")
  func diagnosticsTrackOutcomeWithoutContent() async throws {
    let fixture = try Fixture()
    let store = DesktopCompletionStore(persistence: fixture.persistence)
    await store.load()
    let prompt = fixture.event(
      .userPromptSubmit,
      turn: "turn-private",
      conversationTitle: "PRIVATE_TITLE_SENTINEL"
    )
    let stop = fixture.event(
      .stop,
      turn: "turn-private",
      replyPreview: #"{"private":"REPLY_SENTINEL"}"#
    )

    await store.handlePersisting(prompt, deliveryMode: .live, ingress: .socket)
    await store.handlePersisting(stop, deliveryMode: .live, ingress: .socket)

    #expect(store.hookEventDiagnostics.count == 2)
    #expect(
      store.hookEventDiagnostics.first { $0.id == prompt.eventID }?.outcome
        == .trackingStarted
    )
    #expect(
      store.hookEventDiagnostics.first { $0.id == stop.eventID }?.outcome
        == .waitingForDebounce
    )
    #expect(
      store.hookEventDiagnostics.first { $0.id == stop.eventID }?.payloadKind
        == .structuredText
    )

    let diagnosticData = try JSONEncoder().encode(store.hookEventDiagnostics)
    let diagnosticText = try #require(String(data: diagnosticData, encoding: .utf8))
    #expect(!diagnosticText.contains("PRIVATE_TITLE_SENTINEL"))
    #expect(!diagnosticText.contains("REPLY_SENTINEL"))
    #expect(!diagnosticText.contains("session-1"))
    #expect(!diagnosticText.contains("turn-private"))

    try await Task.sleep(for: .milliseconds(1_650))
    #expect(
      store.hookEventDiagnostics.first { $0.id == stop.eventID }?.outcome
        == .readyToReview
    )

    store.clearHookEventDiagnostics()
    #expect(await store.flushPersistence())
    let restored = DesktopCompletionStore(persistence: fixture.persistence)
    await restored.load()
    #expect(restored.hookEventDiagnostics.isEmpty)
  }

  @Test("下一次 Prompt 自动清除同一 session 未读但不影响其他 session")
  func promptAcknowledgesOnlySameSession() async throws {
    let fixture = try Fixture()
    let store = DesktopCompletionStore(persistence: fixture.persistence)
    await store.load()
    await store.handlePersisting(
      fixture.event(.userPromptSubmit, session: "session-1", turn: "turn-1"),
      deliveryMode: .live
    )
    await store.handlePersisting(
      fixture.event(.userPromptSubmit, session: "session-2", turn: "turn-1"),
      deliveryMode: .live
    )
    await store.handlePersisting(
      fixture.event(.stop, session: "session-1", turn: "turn-1"),
      deliveryMode: .live
    )
    await store.handlePersisting(
      fixture.event(.stop, session: "session-2", turn: "turn-1"),
      deliveryMode: .live
    )
    try await Task.sleep(for: .milliseconds(1_650))
    #expect(store.unreadCount == 2)
    #expect(store.menuBarTitle == L10n.format("%lld 条对话可查看", Int64(2)))

    await store.handlePersisting(
      fixture.event(.userPromptSubmit, session: "session-1", turn: "turn-2"),
      deliveryMode: .live
    )

    #expect(store.unreadCount == 1)
    #expect(store.unreadRecords.first?.sessionID == "session-2")
    #expect(store.sessions["session-1"]?.phase == .running)
    #expect(store.sessions["session-2"]?.phase == .readyToReview)
    #expect(store.menuBarTitle == L10n.format("%lld 条对话可查看", Int64(1)))
  }

  @Test("下一次 Prompt 清除旧记录内容并只保留新一轮主题")
  func nextPromptRedactsPreviousContent() async throws {
    let fixture = try Fixture()
    let store = DesktopCompletionStore(persistence: fixture.persistence)
    await store.load()

    await store.handlePersisting(
      fixture.event(
        .userPromptSubmit,
        turn: "turn-1",
        conversationTitle: "第一轮聊天主题"
      ),
      deliveryMode: .live
    )
    let stop = fixture.event(
      .stop,
      turn: "turn-1",
      replyPreview: "第一轮回复预览"
    )
    await store.handlePersisting(stop, deliveryMode: .live)
    try await Task.sleep(for: .milliseconds(1_650))
    let recordID = stop.eventID.uuidString.lowercased()
    #expect(store.records.first { $0.id == recordID }?.conversationTitle == "第一轮聊天主题")

    await store.handlePersisting(
      fixture.event(
        .userPromptSubmit,
        turn: "turn-2",
        conversationTitle: "第二轮聊天主题"
      ),
      deliveryMode: .live
    )

    let oldRecord = store.records.first { $0.id == recordID }
    #expect(oldRecord?.isAcknowledged == true)
    #expect(oldRecord?.conversationTitle == nil)
    #expect(oldRecord?.replyPreview == nil)
    #expect(store.sessions["session-1"]?.conversationTitle == "第二轮聊天主题")
    #expect(store.sessions["session-1"]?.replyPreview == nil)
  }

  @Test("较旧 Stop 晚到时不能覆盖较新的 Prompt")
  func olderStopCannotOverrideNewerPrompt() async throws {
    let fixture = try Fixture()
    let store = DesktopCompletionStore(persistence: fixture.persistence)
    await store.load()
    let base = Date(timeIntervalSince1970: 1_000)

    await store.handlePersisting(
      fixture.event(
        .userPromptSubmit,
        turn: "turn-new",
        receivedAt: base.addingTimeInterval(2)
      ),
      deliveryMode: .live
    )
    await store.handlePersisting(
      fixture.event(
        .stop,
        turn: "turn-old",
        receivedAt: base.addingTimeInterval(1)
      ),
      deliveryMode: .live
    )
    try await Task.sleep(for: .milliseconds(100))

    #expect(store.sessions["session-1"]?.phase == .running)
    #expect(store.sessions["session-1"]?.turnID == "turn-new")
    #expect(store.unreadCount == 0)
  }

  @Test("相同接收时间时 Prompt 确定性优先于 Stop")
  func promptWinsTimestampTieRegardlessOfArrivalOrder() async throws {
    let timestamp = Date(timeIntervalSince1970: 2_000)

    let stopFirstFixture = try Fixture()
    let stopFirstStore = DesktopCompletionStore(persistence: stopFirstFixture.persistence)
    await stopFirstStore.load()
    await stopFirstStore.handlePersisting(
      stopFirstFixture.event(.stop, turn: "turn-1", receivedAt: timestamp),
      deliveryMode: .live
    )
    await stopFirstStore.handlePersisting(
      stopFirstFixture.event(.userPromptSubmit, turn: "turn-2", receivedAt: timestamp),
      deliveryMode: .live
    )

    let promptFirstFixture = try Fixture()
    let promptFirstStore = DesktopCompletionStore(persistence: promptFirstFixture.persistence)
    await promptFirstStore.load()
    await promptFirstStore.handlePersisting(
      promptFirstFixture.event(.userPromptSubmit, turn: "turn-2", receivedAt: timestamp),
      deliveryMode: .live
    )
    await promptFirstStore.handlePersisting(
      promptFirstFixture.event(.stop, turn: "turn-1", receivedAt: timestamp),
      deliveryMode: .live
    )

    #expect(stopFirstStore.sessions["session-1"]?.phase == .running)
    #expect(stopFirstStore.sessions["session-1"]?.turnID == "turn-2")
    #expect(promptFirstStore.sessions["session-1"]?.phase == .running)
    #expect(promptFirstStore.sessions["session-1"]?.turnID == "turn-2")
  }

  @Test("相同时间、事件类型和 turn 按 eventID 确定性排序")
  func sameTypeTimestampTieIsDeterministic() async throws {
    let timestamp = Date(timeIntervalSince1970: 3_000)
    let lowerID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    let higherID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

    let firstFixture = try Fixture()
    let firstStore = DesktopCompletionStore(persistence: firstFixture.persistence)
    await firstStore.load()
    await firstStore.handlePersisting(
      firstFixture.event(
        .userPromptSubmit,
        turn: "turn-1",
        receivedAt: timestamp,
        eventID: higherID,
        workingDirectory: "/tmp/Higher"
      ),
      deliveryMode: .live
    )
    await firstStore.handlePersisting(
      firstFixture.event(
        .userPromptSubmit,
        turn: "turn-1",
        receivedAt: timestamp,
        eventID: lowerID,
        workingDirectory: "/tmp/Lower"
      ),
      deliveryMode: .live
    )

    let secondFixture = try Fixture()
    let secondStore = DesktopCompletionStore(persistence: secondFixture.persistence)
    await secondStore.load()
    await secondStore.handlePersisting(
      secondFixture.event(
        .userPromptSubmit,
        turn: "turn-1",
        receivedAt: timestamp,
        eventID: lowerID,
        workingDirectory: "/tmp/Lower"
      ),
      deliveryMode: .live
    )
    await secondStore.handlePersisting(
      secondFixture.event(
        .userPromptSubmit,
        turn: "turn-1",
        receivedAt: timestamp,
        eventID: higherID,
        workingDirectory: "/tmp/Higher"
      ),
      deliveryMode: .live
    )

    #expect(firstStore.sessions["session-1"]?.projectDisplayName == "Higher")
    #expect(secondStore.sessions["session-1"]?.projectDisplayName == "Higher")
  }

  @Test("重启恢复 pending 事件时创建未读但不补发旧提醒")
  func restartFinalizesWithoutReplayingAlert() async throws {
    let fixture = try Fixture()
    let first = DesktopCompletionStore(persistence: fixture.persistence)
    await first.load()
    await first.handlePersisting(
      fixture.event(.userPromptSubmit, turn: "turn-1"),
      deliveryMode: .live
    )
    let stop = fixture.event(.stop, turn: "turn-1")
    await first.handlePersisting(stop, deliveryMode: .live)

    let restored = DesktopCompletionStore(persistence: fixture.persistence)
    var delivered = 0
    restored.onReadyToReview = { _ in delivered += 1 }
    await restored.load()
    try await Task.sleep(for: .milliseconds(100))
    await restored.flushPersistence()

    #expect(restored.unreadCount == 1)
    #expect(delivered == 0)
    #expect(restored.records.first?.notificationDelivered == true)
  }

  @Test("已持久化事件在重启后仍去重")
  func restartPreservesDeduplication() async throws {
    let fixture = try Fixture()
    let first = DesktopCompletionStore(persistence: fixture.persistence)
    await first.load()
    let prompt = fixture.event(.userPromptSubmit, turn: "turn-1")
    await first.handlePersisting(prompt, deliveryMode: .live)

    let restored = DesktopCompletionStore(persistence: fixture.persistence)
    await restored.load()
    let loadedPromptAt = restored.lastUserPromptAt
    await restored.handlePersisting(prompt, deliveryMode: .live)

    #expect(restored.sessions.count == 1)
    #expect(restored.lastUserPromptAt == loadedPromptAt)
  }

  @Test("启动时的新鲜 Spool 会提醒，过旧 Spool 只恢复未读")
  func startupSpoolFreshnessControlsAlertDelivery() async throws {
    let now = Date.now

    let freshFixture = try Fixture()
    let freshStore = DesktopCompletionStore(persistence: freshFixture.persistence)
    await freshStore.load()
    var freshDeliveries = 0
    freshStore.onReadyToReview = { _ in freshDeliveries += 1 }
    let freshPrompt = freshFixture.event(
      .userPromptSubmit,
      turn: "fresh-turn",
      receivedAt: now.addingTimeInterval(-3)
    )
    let freshStop = freshFixture.event(
      .stop,
      turn: "fresh-turn",
      receivedAt: now.addingTimeInterval(-2)
    )
    await freshStore.handlePersisting(
      freshPrompt,
      deliveryMode: .startupMode(for: freshPrompt, now: now)
    )
    await freshStore.handlePersisting(
      freshStop,
      deliveryMode: .startupMode(for: freshStop, now: now)
    )
    try await Task.sleep(for: .milliseconds(100))

    #expect(freshStore.unreadCount == 1)
    #expect(freshDeliveries == 1)

    let staleFixture = try Fixture()
    let staleStore = DesktopCompletionStore(persistence: staleFixture.persistence)
    await staleStore.load()
    var staleDeliveries = 0
    staleStore.onReadyToReview = { _ in staleDeliveries += 1 }
    let stalePrompt = staleFixture.event(
      .userPromptSubmit,
      turn: "stale-turn",
      receivedAt: now.addingTimeInterval(
        -(HookEventDeliveryMode.startupAlertFreshnessWindow + 2)
      )
    )
    let staleStop = staleFixture.event(
      .stop,
      turn: "stale-turn",
      receivedAt: now.addingTimeInterval(
        -(HookEventDeliveryMode.startupAlertFreshnessWindow + 1)
      )
    )
    await staleStore.handlePersisting(
      stalePrompt,
      deliveryMode: .startupMode(for: stalePrompt, now: now)
    )
    await staleStore.handlePersisting(
      staleStop,
      deliveryMode: .startupMode(for: staleStop, now: now)
    )
    try await Task.sleep(for: .milliseconds(100))

    #expect(staleStore.unreadCount == 1)
    #expect(staleDeliveries == 0)
    #expect(staleStore.records.first?.notificationDelivered == true)
  }

  private struct Fixture {
    let root: URL
    let persistence: CompletionPersistence

    init() throws {
      root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      persistence = CompletionPersistence(fileURL: root.appendingPathComponent("state.json"))
    }

    func event(
      _ name: DesktopHookEventName,
      session: String = "session-1",
      turn: String,
      receivedAt: Date = .now,
      eventID: UUID = UUID(),
      workingDirectory: String = "/tmp/CodexDone",
      conversationTitle: String? = nil,
      replyPreview: String? = nil,
      suppressedByRule: Bool = false
    ) -> DesktopCompletionHookEvent {
      DesktopCompletionHookEvent(
        eventID: eventID,
        eventName: name,
        sessionID: session,
        turnID: turn,
        workingDirectory: workingDirectory,
        conversationTitle: conversationTitle,
        replyPreview: replyPreview,
        suppressedByRule: suppressedByRule,
        receivedAt: receivedAt
      )
    }
  }
}
