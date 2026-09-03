import Foundation

enum DesktopHookEventName: String, Codable, CaseIterable, Hashable, Sendable {
  case userPromptSubmit = "UserPromptSubmit"
  case stop = "Stop"
}
struct DesktopCompletionHookEvent: Codable, Equatable, Sendable {
  static let schemaVersion = 5
  static let releasedSchemaVersion = 4

  let version: Int
  let eventID: UUID
  let eventName: DesktopHookEventName
  let sessionID: String
  let turnID: String?
  let workingDirectory: String?
  let conversationTitle: String?
  let replyPreview: String?
  let suppressedByRule: Bool
  let receivedAt: Date

  init(
    eventID: UUID,
    eventName: DesktopHookEventName,
    sessionID: String,
    turnID: String?,
    workingDirectory: String?,
    conversationTitle: String? = nil,
    replyPreview: String? = nil,
    suppressedByRule: Bool = false,
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
    self.suppressedByRule = suppressedByRule
    self.receivedAt = receivedAt
  }

  static func supportsSchemaVersion(_ version: Int) -> Bool {
    version == releasedSchemaVersion || version == schemaVersion
  }

  private enum CodingKeys: String, CodingKey {
    case version
    case eventID
    case eventName
    case sessionID
    case turnID
    case workingDirectory
    case conversationTitle
    case replyPreview
    case suppressedByRule
    case receivedAt
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    version = try container.decode(Int.self, forKey: .version)
    eventID = try container.decode(UUID.self, forKey: .eventID)
    eventName = try container.decode(DesktopHookEventName.self, forKey: .eventName)
    sessionID = try container.decode(String.self, forKey: .sessionID)
    turnID = try container.decodeIfPresent(String.self, forKey: .turnID)
    workingDirectory = try container.decodeIfPresent(String.self, forKey: .workingDirectory)
    conversationTitle = try container.decodeIfPresent(String.self, forKey: .conversationTitle)
    replyPreview = try container.decodeIfPresent(String.self, forKey: .replyPreview)
    suppressedByRule = try container.decodeIfPresent(Bool.self, forKey: .suppressedByRule)
      ?? false
    receivedAt = try container.decode(Date.self, forKey: .receivedAt)
  }
}
