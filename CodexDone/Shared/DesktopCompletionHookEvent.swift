import Foundation

enum DesktopHookEventName: String, Codable, CaseIterable, Hashable, Sendable {
  case userPromptSubmit = "UserPromptSubmit"
  case stop = "Stop"
}
struct DesktopCompletionHookEvent: Codable, Equatable, Sendable {
  static let schemaVersion = 4

  let version: Int
  let eventID: UUID
  let eventName: DesktopHookEventName
  let sessionID: String
  let turnID: String?
  let workingDirectory: String?
  let conversationTitle: String?
  let replyPreview: String?
  let receivedAt: Date

  init(
    eventID: UUID,
    eventName: DesktopHookEventName,
    sessionID: String,
    turnID: String?,
    workingDirectory: String?,
    conversationTitle: String? = nil,
    replyPreview: String? = nil,
    receivedAt: Date
  ) {
    version = Self.schemaVersion
    self.eventID = eventID
    self.eventName = eventName
    self.sessionID = sessionID
    self.turnID = turnID
    self.workingDirectory = workingDirectory
    self.conversationTitle = conversationTitle
    self.replyPreview = replyPreview
    self.receivedAt = receivedAt
  }
}
