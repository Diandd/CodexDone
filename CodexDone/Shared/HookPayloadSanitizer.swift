import CryptoKit
import Foundation

enum HookPayloadSanitizationError: Error, Equatable {
  case payloadTooLarge
  case malformedJSON
  case unsupportedEvent
  case missingSessionID
  case invalidField
}

enum HookPayloadSanitizer {
  static let maximumPayloadBytes = 4 * 1_024 * 1_024
  static let maximumConversationTitleCharacters = 30
  static let maximumReplyPreviewCharacters = 180

  static func event(
    from data: Data,
    source: AgentSource = .codex,
    terminalSessionID: String? = nil,
    suppressionRules: AlertSuppressionRules = AlertSuppressionRules(),
    receivedAt: Date = .now
  ) throws -> DesktopCompletionHookEvent {
    guard data.count <= maximumPayloadBytes else {
      throw HookPayloadSanitizationError.payloadTooLarge
    }
    guard
      let object = try? JSONSerialization.jsonObject(with: data),
      let dictionary = object as? [String: Any]
    else {
      throw HookPayloadSanitizationError.malformedJSON
    }

    guard
      let rawEventName = boundedString(dictionary["hook_event_name"], maximumLength: 64),
      let eventName = DesktopHookEventName(rawValue: rawEventName)
    else {
      throw HookPayloadSanitizationError.unsupportedEvent
    }
    guard
      let rawSessionID = boundedString(dictionary["session_id"], maximumLength: 512),
      !rawSessionID.isEmpty
    else {
      throw HookPayloadSanitizationError.missingSessionID
    }

    let sessionID = source.scopedSessionID(rawSessionID)
    let turnID = boundedString(dictionary["turn_id"], maximumLength: 512)
    let workingDirectory = boundedString(dictionary["cwd"], maximumLength: 4_096)
    let rawPrompt = dictionary["prompt"] as? String
    let rawAssistantReply = dictionary["last_assistant_message"] as? String
    let submittedPrompt = rawPrompt.map { String(contentAfterRequestMarker(in: $0)) }
    let conversationTitle =
      eventName == .userPromptSubmit
      ? conversationTitle(from: rawPrompt)
      : nil
    let replyPreview =
      eventName == .stop
      ? normalizedPreview(
        from: rawAssistantReply,
        maximumCharacters: maximumReplyPreviewCharacters
      )
      : nil
    let eventID = deterministicEventID(
      eventName: eventName,
      sessionID: sessionID,
      turnID: turnID,
      receivedAt: receivedAt
    )
    let suppressedByRule = suppressionRules.suppresses(
      submittedMessage: eventName == .userPromptSubmit ? submittedPrompt : nil,
      assistantReply: eventName == .stop ? rawAssistantReply : nil,
      workingDirectory: workingDirectory
    )

    return DesktopCompletionHookEvent(
      eventID: eventID,
      eventName: eventName,
      sessionID: sessionID,
      turnID: turnID,
      workingDirectory: workingDirectory,
      conversationTitle: conversationTitle,
      replyPreview: replyPreview,
      suppressedByRule: suppressedByRule,
      receivedAt: receivedAt,
      terminalSessionID: normalizedTerminalSessionID(terminalSessionID)
    )
  }

  static func normalizedTerminalSessionID(_ value: String?) -> String? {
    guard let value, let id = value.split(separator: ":").last,
      UUID(uuidString: String(id)) != nil else { return nil }
    return String(id).uppercased()
  }

  private static func conversationTitle(from raw: String?) -> String? {
    guard let raw, !raw.contains("\0") else { return nil }
    let source = contentAfterRequestMarker(in: raw)
    guard
      var title = normalizedPreview(
        from: String(source),
        maximumCharacters: maximumConversationTitleCharacters
      )
    else {
      return nil
    }
    if title == "/goal" { return nil }
    if title.hasPrefix("/goal ") {
      title.removeFirst("/goal ".count)
    }
    title = title.trimmingCharacters(in: CharacterSet(charactersIn: "#*- \t"))
    return title.isEmpty
      ? nil
      : ellipsized(title, maximumCharacters: maximumConversationTitleCharacters)
  }

  private static func contentAfterRequestMarker(in raw: String) -> Substring {
    let markers = ["## My request:", "## My Request:", "## 我的请求："]
    for marker in markers {
      if let range = raw.range(of: marker, options: .backwards) {
        return raw[range.upperBound...]
      }
    }
    return raw[...]
  }

  private static func normalizedPreview(
    from value: Any?,
    maximumCharacters: Int
  ) -> String? {
    guard let raw = value as? String, !raw.contains("\0") else { return nil }
    var characters: [Character] = []
    characters.reserveCapacity(maximumCharacters + 1)
    var pendingSpace = false

    for character in raw {
      if character.isWhitespace {
        pendingSpace = !characters.isEmpty
        continue
      }
      if pendingSpace, characters.count < maximumCharacters + 1 {
        characters.append(" ")
      }
      pendingSpace = false
      characters.append(character)
      if characters.count > maximumCharacters {
        break
      }
    }

    let normalized = String(characters)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else { return nil }
    return ellipsized(normalized, maximumCharacters: maximumCharacters)
  }

  private static func ellipsized(
    _ value: String,
    maximumCharacters: Int
  ) -> String {
    guard value.count > maximumCharacters else { return value }
    return String(value.prefix(maximumCharacters - 1)) + "…"
  }

  private static func boundedString(_ value: Any?, maximumLength: Int) -> String? {
    guard let value = value as? String else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard
      !trimmed.contains("\0"),
      trimmed.utf8.count <= maximumLength
    else {
      return nil
    }
    return trimmed.isEmpty ? nil : trimmed
  }

  private static func deterministicEventID(
    eventName: DesktopHookEventName,
    sessionID: String,
    turnID: String?,
    receivedAt: Date
  ) -> UUID {
    let fallbackTimestamp = Int(receivedAt.timeIntervalSince1970.rounded())
    let eventDiscriminator = turnID ?? "received-at:\(fallbackTimestamp)"
    let canonical = [
      eventName.rawValue,
      sessionID,
      eventDiscriminator,
    ]
    .joined(separator: "\u{001F}")
    var bytes = Array(SHA256.hash(data: Data(canonical.utf8)).prefix(16))
    bytes[6] = (bytes[6] & 0x0F) | 0x50
    bytes[8] = (bytes[8] & 0x3F) | 0x80
    let hex = bytes.map { String(format: "%02x", $0) }.joined()
    let uuidString = [
      String(hex.prefix(8)),
      String(hex.dropFirst(8).prefix(4)),
      String(hex.dropFirst(12).prefix(4)),
      String(hex.dropFirst(16).prefix(4)),
      String(hex.dropFirst(20).prefix(12)),
    ].joined(separator: "-")
    return UUID(uuidString: uuidString)!
  }
}
