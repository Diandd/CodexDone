import Foundation
import Testing

@testable import CodexDone

struct CompletionReducerTests {
  private let date = Date(timeIntervalSince1970: 1_787_760_000)

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
    replyPreview: String? = nil
  ) -> DesktopCompletionHookEvent {
    DesktopCompletionHookEvent(
      eventID: UUID(),
      eventName: name,
      sessionID: "session-1",
      turnID: turnID,
      workingDirectory: "/tmp/CodexDone",
      conversationTitle: conversationTitle,
      replyPreview: replyPreview,
      receivedAt: date
    )
  }
}
