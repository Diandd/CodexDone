import Foundation

enum CompletionReducer {
  static let stopDebounce: Duration = .milliseconds(1_500)

  static func reduce(
    session existing: CompletionSessionState?,
    event: DesktopCompletionHookEvent
  ) -> (CompletionSessionState, [CompletionEffect]) {
    let projectName = event.workingDirectory == nil
      ? (existing?.projectDisplayName ?? projectDisplayName(for: nil))
      : projectDisplayName(for: event.workingDirectory)
    var session = existing ?? CompletionSessionState(
      sessionID: event.sessionID,
      phase: .idle,
      turnID: nil,
      projectDisplayName: projectName,
      lastEventAt: event.receivedAt,
      pendingEventID: nil
    )
    var effects: [CompletionEffect] = []

    switch event.eventName {
    case .userPromptSubmit:
      if session.phase == .pendingCompletionDebounce {
        effects.append(.cancelPendingAlert(sessionID: event.sessionID))
      }
      if session.phase == .readyToReview {
        effects.append(.dismissAlert(sessionID: event.sessionID))
      }
      session.phase = .running
      session.turnID = event.turnID
      session.pendingEventID = nil
      session.conversationTitle = event.conversationTitle
      session.replyPreview = nil

    case .stop:
      guard
        session.phase == .running || session.phase == .pendingCompletionDebounce
      else {
        session.replyPreview = nil
        break
      }
      if session.phase == .pendingCompletionDebounce {
        effects.append(.cancelPendingAlert(sessionID: event.sessionID))
      }
      session.phase = .pendingCompletionDebounce
      session.turnID = event.turnID
      session.pendingEventID = event.eventID
      session.replyPreview = event.replyPreview
      effects.append(
        .scheduleCompletion(
          sessionID: event.sessionID,
          eventID: event.eventID,
          after: stopDebounce
        )
      )
    }

    session.projectDisplayName = projectName
    session.lastEventAt = event.receivedAt
    return (session, effects)
  }

  static func finalize(
    session: CompletionSessionState,
    eventID: UUID,
    completedAt: Date,
    suppressAlert: Bool
  ) -> (CompletionSessionState, ConversationCompletionRecord, [CompletionEffect])? {
    guard
      session.phase == .pendingCompletionDebounce,
      session.pendingEventID == eventID
    else {
      return nil
    }

    var updated = session
    updated.phase = .readyToReview
    updated.pendingEventID = nil
    let record = ConversationCompletionRecord(
      id: eventID.uuidString.lowercased(),
      sessionID: session.sessionID,
      turnID: session.turnID,
      projectDisplayName: session.projectDisplayName,
      completedAt: completedAt,
      isAcknowledged: false,
      notificationDelivered: suppressAlert,
      conversationTitle: session.conversationTitle,
      replyPreview: session.replyPreview
    )
    let effects: [CompletionEffect] = suppressAlert ? [] : [.deliverAlert(recordID: record.id)]
    return (updated, record, effects)
  }

  static func projectDisplayName(for workingDirectory: String?) -> String {
    guard let workingDirectory, !workingDirectory.isEmpty else {
      return L10n.text("Codex 对话")
    }
    let name = URL(fileURLWithPath: workingDirectory).lastPathComponent
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { return L10n.text("Codex 对话") }
    return String(name.prefix(80))
  }
}
