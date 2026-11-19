import Foundation
import Testing

@testable import CodexDone

struct CompletionReducerTests {
  private let date = Date(timeIntervalSince1970: 1_787_760_000)

  @Test("提交后切走窗口仍捕获原终端并随完成消息持久化") @MainActor
  func terminalIdentitySurvivesCompletion() async throws {
    let terminal = "12345678-1234-1234-1234-123456789ABC"
    let target = SystemIntegrationService.promptReturnTarget(
      foreground: CodexReturnTarget(processIdentifier: 201, bundleIdentifier: "com.apple.finder"),
      departedTerminal: CodexReturnTarget(processIdentifier: 200, bundleIdentifier: "com.googlecode.iterm2"),
      secondsSinceDeparture: 1
    )
    let prompt = await SystemIntegrationService().captureTerminalSession(
      for: makeEvent(.userPromptSubmit, turnID: "turn-1"),
      target: target,
      readSessionID: { "w0t1p0:" + terminal }
    )
    let running = CompletionReducer.reduce(session: nil, event: prompt).0
    let stop = makeEvent(.stop, turnID: "turn-1")
    let pending = CompletionReducer.reduce(session: running, event: stop).0
    let result = try #require(CompletionReducer.finalize(session: pending, eventID: stop.eventID,
      completedAt: .now, suppressAlert: false))
    let restored = try JSONDecoder().decode(ConversationCompletionRecord.self,
      from: JSONEncoder().encode(result.1))
    #expect(restored.terminalSessionID == terminal)
    let oldEvent = try JSONDecoder().decode(DesktopCompletionHookEvent.self,
      from: JSONEncoder().encode(stop))
    #expect(oldEvent.terminalSessionID == nil)
  }

  @Test("只在缺少终端标识的 iTerm2 提交事件中读取当前标签页") @MainActor
  func terminalCaptureDoesNotGuessAtCompletionOrReplaceAnExplicitTarget() async {
    let service = SystemIntegrationService()
    let iterm = CodexReturnTarget(processIdentifier: 200, bundleIdentifier: "com.googlecode.iterm2")
    let desktop = CodexReturnTarget(processIdentifier: 201, bundleIdentifier: "com.openai.codex")
    let prompt = makeEvent(.userPromptSubmit, turnID: "turn-1")
    var explicit = prompt
    explicit.terminalSessionID = "12345678-1234-1234-1234-123456789ABC"
    let cases: [(DesktopCompletionHookEvent, CodexReturnTarget?)] = [
      (prompt, nil), (prompt, desktop), (explicit, iterm),
      (makeEvent(.stop, turnID: "turn-1"), iterm),
    ]
    var readCount = 0
    for (event, target) in cases {
      let captured = await service.captureTerminalSession(for: event, target: target) {
        readCount += 1
        return "ABCDEFAB-1234-1234-1234-123456789ABC"
      }
      #expect(captured == event)
    }
    #expect(readCount == 0)
    let denied = await service.captureTerminalSession(for: prompt, target: iterm) { nil }
    #expect(denied == prompt)
  }

  @Test("会话转到桌面后清除上一轮终端标识")
  func desktopPromptClearsPreviousTerminalIdentity() {
    var prompt = makeEvent(.userPromptSubmit, turnID: "terminal-turn")
    prompt.terminalSessionID = "12345678-1234-1234-1234-123456789ABC"
    let terminal = CompletionReducer.reduce(session: nil, event: prompt).0
    let desktop = CompletionReducer.reduce(session: terminal,
      event: makeEvent(.userPromptSubmit, turnID: "desktop-turn")).0
    #expect(desktop.terminalSessionID == nil)
    let stopped = CompletionReducer.reduce(session: desktop,
      event: makeEvent(.stop, turnID: "desktop-turn")).0
    #expect(stopped.terminalSessionID == nil)
  }

  @Test("UserPromptSubmit 进入 running")
  func promptStartsRunning() {
    let event = makeEvent(
      .userPromptSubmit,
      turnID: "turn-1",
      conversationTitle: "调整菜单信息层级"
    )
    let (session, effects) = CompletionReducer.reduce(session: nil, event: event)

    #expect(session.phase == .running)
    #expect(session.turnID == "turn-1")
    #expect(session.projectDisplayName == "CodexDone")
    #expect(session.conversationTitle == "调整菜单信息层级")
    #expect(session.replyPreview == nil)
    #expect(effects.isEmpty)
  }

  @Test("Stop 先进入 1.5 秒 pending，不直接完成")
  func stopStartsDebounce() {
    let running = CompletionReducer.reduce(
      session: nil,
      event: makeEvent(.userPromptSubmit, turnID: "turn-1")
    ).0
    let stop = makeEvent(.stop, turnID: "turn-1", replyPreview: "已完成菜单调整。")
    let (session, effects) = CompletionReducer.reduce(session: running, event: stop)

    #expect(session.phase == .pendingCompletionDebounce)
    #expect(session.pendingEventID == stop.eventID)
    #expect(session.replyPreview == "已完成菜单调整。")
    #expect(
      effects == [
        .scheduleCompletion(
          sessionID: "session-1",
          eventID: stop.eventID,
          after: .milliseconds(1_500)
        )
      ]
    )
  }

  @Test("没有用户 Prompt 的 Stop 不创建待查看记录")
  func stopWithoutPromptIsIgnored() {
    let stop = makeEvent(
      .stop,
      turnID: "background-turn",
      replyPreview: #"{"suggestions":[]}"#
    )

    let (session, effects) = CompletionReducer.reduce(session: nil, event: stop)

    #expect(session.phase == .idle)
    #expect(session.pendingEventID == nil)
    #expect(session.replyPreview == nil)
    #expect(effects.isEmpty)
  }

  @Test("命中屏蔽规则的本轮在 Stop 时直接结束且不生成提醒")
  func suppressedTurnEndsWithoutReviewItem() {
    let prompt = makeEvent(
      .userPromptSubmit,
      turnID: "turn-blocked",
      conversationTitle: "忽略这类消息",
      suppressedByRule: true
    )
    let running = CompletionReducer.reduce(session: nil, event: prompt).0
    let stop = makeEvent(.stop, turnID: "turn-blocked", replyPreview: "本轮已停止。")

    let (session, effects) = CompletionReducer.reduce(session: running, event: stop)

    #expect(running.suppressesCurrentTurn)
    #expect(session.phase == .idle)
    #expect(session.pendingEventID == nil)
    #expect(session.conversationTitle == nil)
    #expect(session.replyPreview == nil)
    #expect(!session.suppressesCurrentTurn)
    #expect(effects.isEmpty)
  }

  @Test("Stop 回复规则命中时直接结束且不生成提醒")
  func suppressedStopReplyEndsWithoutReviewItem() {
    let prompt = makeEvent(
      .userPromptSubmit,
      turnID: "turn-reply-blocked",
      conversationTitle: "检查最终结果"
    )
    let running = CompletionReducer.reduce(session: nil, event: prompt).0
    let stop = makeEvent(
      .stop,
      turnID: "turn-reply-blocked",
      replyPreview: "无需提醒的自动回复",
      suppressedByRule: true
    )

    let (session, effects) = CompletionReducer.reduce(session: running, event: stop)

    #expect(!running.suppressesCurrentTurn)
    #expect(session.phase == .idle)
    #expect(session.pendingEventID == nil)
    #expect(session.conversationTitle == nil)
    #expect(session.replyPreview == nil)
    #expect(effects.isEmpty)
  }

  @Test("防抖确认后只表达 readyToReview")
  func finalizeBecomesReadyToReview() {
    let prompt = makeEvent(
      .userPromptSubmit,
      turnID: "turn-1",
      conversationTitle: "调整菜单信息层级"
    )
    let running = CompletionReducer.reduce(session: nil, event: prompt).0
    let stop = makeEvent(.stop, turnID: "turn-1", replyPreview: "已完成菜单调整。")
    let pending = CompletionReducer.reduce(session: running, event: stop).0
    let result = CompletionReducer.finalize(
      session: pending,
      eventID: stop.eventID,
      completedAt: date.addingTimeInterval(2),
      suppressAlert: false
    )

    #expect(result?.0.phase == .readyToReview)
    #expect(result?.1.projectDisplayName == "CodexDone")
    #expect(result?.1.conversationTitle == "调整菜单信息层级")
    #expect(result?.1.replyPreview == "已完成菜单调整。")
    #expect(result?.1.isAcknowledged == false)
    #expect(result?.0.lastEventAt == stop.receivedAt)
    #expect(result?.2 == [.deliverAlert(recordID: stop.eventID.uuidString.lowercased())])
  }

  @Test("缺少 cwd 的后续事件不会抹掉已知项目名")
  func missingWorkingDirectoryPreservesProjectName() {
    let prompt = makeEvent(.userPromptSubmit, turnID: "turn-1")
    let running = CompletionReducer.reduce(session: nil, event: prompt).0
    let stop = DesktopCompletionHookEvent(
      eventID: UUID(),
      eventName: .stop,
      sessionID: "session-1",
      turnID: "turn-1",
      workingDirectory: nil,
      receivedAt: date.addingTimeInterval(1)
    )

    let pending = CompletionReducer.reduce(session: running, event: stop).0

    #expect(pending.projectDisplayName == "CodexDone")
  }

  @Test("同一 session 的下一次 Prompt 清除 pending 或 ready")
  func nextPromptClearsPreviousCycle() {
    let firstPrompt = makeEvent(.userPromptSubmit, turnID: "turn-1")
    let running = CompletionReducer.reduce(session: nil, event: firstPrompt).0
    let stop = makeEvent(.stop, turnID: "turn-1")
    let pending = CompletionReducer.reduce(session: running, event: stop).0
    let prompt = makeEvent(.userPromptSubmit, turnID: "turn-2")
    let (nextRunning, effects) = CompletionReducer.reduce(session: pending, event: prompt)

    #expect(nextRunning.phase == .running)
    #expect(nextRunning.turnID == "turn-2")
    #expect(effects == [.cancelPendingAlert(sessionID: "session-1")])
  }

  private func makeEvent(
    _ name: DesktopHookEventName,
    turnID: String,
    conversationTitle: String? = nil,
    replyPreview: String? = nil,
    suppressedByRule: Bool = false
  ) -> DesktopCompletionHookEvent {
    DesktopCompletionHookEvent(
      eventID: UUID(),
      eventName: name,
      sessionID: "session-1",
      turnID: turnID,
      workingDirectory: "/tmp/CodexDone",
      conversationTitle: conversationTitle,
      replyPreview: replyPreview,
      suppressedByRule: suppressedByRule,
      receivedAt: date
    )
  }
}
