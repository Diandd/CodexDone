import Foundation

enum AlertSituation: String, Codable, CaseIterable, Equatable, Sendable {
  case completion
}

struct AlertPresentation: Equatable, Identifiable, Sendable {
  let id: String
  let situation: AlertSituation
  let sessionID: String
  let conversationTitle: String?
  let projectDisplayName: String

  init(
    id: String,
    situation: AlertSituation,
    sessionID: String,
    conversationTitle: String?,
    projectDisplayName: String
  ) {
    self.id = id
    self.situation = situation
    self.sessionID = sessionID
    self.conversationTitle = conversationTitle
    self.projectDisplayName = projectDisplayName
  }

  init(completion record: ConversationCompletionRecord) {
    self.init(
      id: record.id,
      situation: .completion,
      sessionID: record.sessionID,
      conversationTitle: record.conversationTitle,
      projectDisplayName: record.projectDisplayName
    )
  }
}

enum ConversationCompletionPhase: String, Codable, Equatable, Sendable {
  case idle
  case running
  case pendingCompletionDebounce
  case readyToReview
}

struct CompletionSessionState: Codable, Equatable, Identifiable, Sendable {
  var id: String { sessionID }

  let sessionID: String
  var phase: ConversationCompletionPhase
  var turnID: String?
  var projectDisplayName: String
  var lastEventAt: Date
  var pendingEventID: UUID?
  var conversationTitle: String? = nil
  var replyPreview: String? = nil
  var suppressesCurrentTurn = false
}

struct ConversationCompletionRecord: Codable, Equatable, Identifiable, Sendable {
  let id: String
  let sessionID: String
  let turnID: String?
  let projectDisplayName: String
  let completedAt: Date
  var isAcknowledged: Bool
  var notificationDelivered: Bool
  var conversationTitle: String? = nil
  var replyPreview: String? = nil
}

struct CompletionPersistedState: Codable, Equatable, Sendable {
  static let currentVersion = 6

  var version = currentVersion
  var sessions: [CompletionSessionState] = []
  var records: [ConversationCompletionRecord] = []
  var processedEventIDs: [UUID] = []
  var hookEventDiagnostics: [HookEventDiagnosticRecord] = []
  var lastUserPromptAt: Date? = nil
  var lastStopAt: Date? = nil
}

enum HookEventIngress: String, Codable, Equatable, Sendable {
  case socket
  case spool

  var title: String {
    switch self {
    case .socket: "Socket"
    case .spool: "Spool"
    }
  }
}

enum HookEventPayloadKind: String, Codable, Equatable, Sendable {
  case none
  case text
  case structuredText

  var title: String {
    switch self {
    case .none: L10n.text("未派生短内容")
    case .text: L10n.text("已派生文本")
    case .structuredText: L10n.text("已派生结构化文本")
    }
  }

  init(event: DesktopCompletionHookEvent) {
    let boundedText =
      switch event.eventName {
      case .userPromptSubmit: event.conversationTitle
      case .stop: event.replyPreview
      }
    guard
      let firstCharacter = boundedText?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .first
    else {
      self = .none
      return
    }
    self = firstCharacter == "{" || firstCharacter == "[" ? .structuredText : .text
  }
}

enum HookEventDiagnosticOutcome: String, Codable, Equatable, Sendable {
  case trackingStarted
  case trackingStartedAndClearedUnread
  case waitingForDebounce
  case ignoredWithoutPrompt
  case ignoredOlderEvent
  case cancelledByNewPrompt
  case supersededByNewStop
  case suppressedByRule
  case readyToReview
  case restoredWithoutAlert

  var title: String {
    switch self {
    case .trackingStarted: L10n.text("开始跟踪本轮")
    case .trackingStartedAndClearedUnread: L10n.text("开始跟踪并清除旧未读")
    case .waitingForDebounce: L10n.text("等待防抖")
    case .ignoredWithoutPrompt: L10n.text("忽略：未观察到 Prompt")
    case .ignoredOlderEvent: L10n.text("忽略：事件顺序较旧")
    case .cancelledByNewPrompt: L10n.text("已被新 Prompt 取消")
    case .supersededByNewStop: L10n.text("已被新 Stop 替换")
    case .suppressedByRule: L10n.text("已按屏蔽规则忽略")
    case .readyToReview: L10n.text("已生成待查看")
    case .restoredWithoutAlert: L10n.text("已恢复待查看，未补发提醒")
    }
  }
}

struct HookEventDiagnosticRecord: Codable, Equatable, Identifiable, Sendable {
  let id: UUID
  let eventName: DesktopHookEventName
  let receivedAt: Date
  let ingress: HookEventIngress
  let payloadKind: HookEventPayloadKind
  var outcome: HookEventDiagnosticOutcome
}

enum CompletionEffect: Equatable, Sendable {
  case cancelPendingAlert(sessionID: String)
  case dismissAlert(sessionID: String)
  case scheduleCompletion(sessionID: String, eventID: UUID, after: Duration)
  case deliverAlert(recordID: String)
}

enum HookEventDeliveryMode: Equatable, Sendable {
  case live
  case replayWithoutAlert

  static let startupAlertFreshnessWindow: TimeInterval = 10 * 60

  static func startupMode(
    for event: DesktopCompletionHookEvent,
    now: Date = .now
  ) -> Self {
    let age = max(0, now.timeIntervalSince(event.receivedAt))
    return age <= startupAlertFreshnessWindow ? .live : .replayWithoutAlert
  }
}
