import Foundation

struct AlertSuppressionRules: Codable, Equatable, Sendable {
  static let currentVersion = 4
  static let maximumRuleCount = 50
  static let maximumRuleCharacters = 80
  static let regexEvaluationTimeoutMilliseconds = 25
  static let defaultInternalSuggestionsReplyRegex = #"^\s*\{\s*"suggestions"\s*:\s*\["#
  static let defaultRootProjectName = "/"

  var version = currentVersion
  var submittedMessageKeywords: [String] = []
  var submittedMessageRegexPatterns: [String] = []
  var assistantReplyRegexPatterns: [String] = []
  var projectNames: [String] = []

  init(
    submittedMessageKeywords: [String] = [],
    submittedMessageRegexPatterns: [String] = [],
    assistantReplyRegexPatterns: [String] = [],
    projectNames: [String] = []
  ) {
    self.submittedMessageKeywords = Self.normalizedRules(
      submittedMessageKeywords,
      using: Self.normalizedKeywordRule,
      duplicateComparisonOptions: [.caseInsensitive, .diacriticInsensitive]
    )
    self.submittedMessageRegexPatterns = Self.normalizedRules(
      submittedMessageRegexPatterns,
      using: Self.normalizedRegexRule,
      duplicateComparisonOptions: []
    )
    self.assistantReplyRegexPatterns = Self.normalizedRules(
      assistantReplyRegexPatterns,
      using: Self.normalizedRegexRule,
      duplicateComparisonOptions: []
    )
    self.projectNames = Self.normalizedRules(
      projectNames,
      using: Self.normalizedRule,
      duplicateComparisonOptions: [.caseInsensitive, .diacriticInsensitive]
    )
  }

  func normalized() -> Self {
    Self(
      submittedMessageKeywords: submittedMessageKeywords,
      submittedMessageRegexPatterns: submittedMessageRegexPatterns,
      assistantReplyRegexPatterns: assistantReplyRegexPatterns,
      projectNames: projectNames
    )
  }

  static var productDefaults: Self {
    Self(
      assistantReplyRegexPatterns: [defaultInternalSuggestionsReplyRegex],
      projectNames: [defaultRootProjectName]
    )
  }

  func includingProductDefaults() -> Self {
    let defaults = Self.productDefaults
    return Self(
      submittedMessageKeywords: submittedMessageKeywords,
      submittedMessageRegexPatterns: submittedMessageRegexPatterns,
      assistantReplyRegexPatterns:
        assistantReplyRegexPatterns + defaults.assistantReplyRegexPatterns,
      projectNames: projectNames + defaults.projectNames
    )
  }

  func suppresses(
    submittedMessage: String?,
    assistantReply: String?,
    workingDirectory: String?
  ) -> Bool {
    if let submittedMessage, !submittedMessage.isEmpty {
      let normalizedMessage = Self.normalizedWhitespace(submittedMessage)
      if submittedMessageKeywords.contains(where: { keyword in
        normalizedMessage.range(
          of: keyword,
          options: [.caseInsensitive, .diacriticInsensitive]
        ) != nil
      })
      {
        return true
      }
    }

    let regexCandidates = [
      RegexMatchCandidate(
        content: submittedMessage,
        patterns: submittedMessageRegexPatterns
      ),
      RegexMatchCandidate(
        content: assistantReply,
        patterns: assistantReplyRegexPatterns
      ),
    ]
    if Self.matchesRegex(candidates: regexCandidates) {
      return true
    }

    guard
      let projectName = Self.projectName(from: workingDirectory),
      projectNames.contains(where: { candidate in
        candidate.compare(
          projectName,
          options: [.caseInsensitive, .diacriticInsensitive]
        ) == .orderedSame
      })
    else {
      return false
    }
    return true
  }

  static func normalizedRule(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !trimmed.contains("\0") else { return nil }
    return String(trimmed.prefix(maximumRuleCharacters))
  }

  static func normalizedRegexRule(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard
      !trimmed.isEmpty,
      !trimmed.contains("\0"),
      trimmed.count <= maximumRuleCharacters,
      (try? Regex(trimmed)) != nil
    else {
      return nil
    }
    return trimmed
  }

  static func normalizedKeywordRule(_ value: String) -> String? {
    guard !value.contains("\0") else { return nil }
    let normalized = normalizedWhitespace(value)
    guard !normalized.isEmpty else { return nil }
    return String(normalized.prefix(maximumRuleCharacters))
  }

  private static func normalizedRules(
    _ values: [String],
    using normalizer: (String) -> String?,
    duplicateComparisonOptions: String.CompareOptions
  ) -> [String] {
    var normalized: [String] = []
    normalized.reserveCapacity(min(values.count, maximumRuleCount))
    for value in values {
      guard let rule = normalizer(value) else { continue }
      guard
        !normalized.contains(where: {
          $0.compare(
            rule,
            options: duplicateComparisonOptions
          ) == .orderedSame
        })
      else {
        continue
      }
      normalized.append(rule)
      if normalized.count == maximumRuleCount { break }
    }
    return normalized
  }

  private static func matchesRegex(candidates: [RegexMatchCandidate]) -> Bool {
    let candidates = candidates.filter {
      $0.content?.isEmpty == false && !$0.patterns.isEmpty
    }
    guard !candidates.isEmpty else { return false }

    let result = RegexMatchResult()
    let finished = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .userInitiated).async {
      let matched = candidates.contains { candidate in
        guard let content = candidate.content else { return false }
        return candidate.patterns.contains { pattern in
          guard let regex = try? Regex(pattern) else { return false }
          return content.contains(regex)
        }
      }
      result.store(matched)
      finished.signal()
    }

    guard
      finished.wait(
        timeout: .now() + .milliseconds(regexEvaluationTimeoutMilliseconds)
      ) == .success
    else {
      return false
    }
    return result.load()
  }

  private static func projectName(from workingDirectory: String?) -> String? {
    guard let workingDirectory, !workingDirectory.isEmpty else { return nil }
    let name = URL(fileURLWithPath: workingDirectory).lastPathComponent
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return name.isEmpty ? nil : String(name.prefix(maximumRuleCharacters))
  }

  private static func normalizedWhitespace(_ value: String) -> String {
    var result = ""
    result.reserveCapacity(min(value.count, maximumRuleCharacters))
    var hasPendingSpace = false

    for character in value {
      if character.isWhitespace {
        hasPendingSpace = !result.isEmpty
        continue
      }
      if hasPendingSpace {
        result.append(" ")
        hasPendingSpace = false
      }
      result.append(character)
    }
    return result
  }
}

private struct RegexMatchCandidate: Sendable {
  let content: String?
  let patterns: [String]
}

private final class RegexMatchResult: @unchecked Sendable {
  private let lock = NSLock()
  private var value = false

  func store(_ newValue: Bool) {
    lock.lock()
    value = newValue
    lock.unlock()
  }

  func load() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return value
  }
}

enum AlertSuppressionRulesFile {
  static let maximumFileBytes = 64 * 1_024

  static func load(
    from fileURL: URL = HookRuntimePaths.alertSuppressionRulesURL,
    fileManager: FileManager = .default
  ) -> AlertSuppressionRules {
    guard fileManager.fileExists(atPath: fileURL.path) else {
      return .productDefaults
    }
    do {
      let values = try fileURL.resourceValues(
        forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
      )
      guard
        values.isRegularFile == true,
        values.isSymbolicLink != true,
        (values.fileSize ?? maximumFileBytes + 1) <= maximumFileBytes
      else {
        return AlertSuppressionRules()
      }
      let data = try Data(contentsOf: fileURL)
      let envelope = try JSONDecoder().decode(VersionEnvelope.self, from: data)
      switch envelope.version {
      case AlertSuppressionRules.currentVersion:
        return try JSONDecoder().decode(AlertSuppressionRules.self, from: data).normalized()
      case PreviousAlertSuppressionRules.version:
        return try JSONDecoder().decode(AlertSuppressionRules.self, from: data)
          .includingProductDefaults()
      case LegacyAlertSuppressionRules.minimumVersion...LegacyAlertSuppressionRules.maximumVersion:
        return try JSONDecoder().decode(LegacyAlertSuppressionRules.self, from: data)
          .migrated()
          .includingProductDefaults()
      default:
        return AlertSuppressionRules()
      }
    } catch {
      return AlertSuppressionRules()
    }
  }

  static func save(
    _ rules: AlertSuppressionRules,
    to fileURL: URL = HookRuntimePaths.alertSuppressionRulesURL,
    fileManager: FileManager = .default
  ) throws {
    let parent = fileURL.deletingLastPathComponent()
    try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
    try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(rules.normalized())
    guard data.count <= maximumFileBytes else {
      throw CocoaError(.fileWriteUnknown)
    }
    try data.write(to: fileURL, options: .atomic)
    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
  }

  private struct VersionEnvelope: Decodable {
    let version: Int
  }
}

private enum PreviousAlertSuppressionRules {
  static let version = 3
}

private struct LegacyAlertSuppressionRules: Decodable {
  static let minimumVersion = 1
  static let maximumVersion = 2

  let version: Int
  let messageKeywords: [String]?
  let messageRegexPatterns: [String]?
  let projectNames: [String]?

  func migrated() -> AlertSuppressionRules {
    AlertSuppressionRules(
      submittedMessageKeywords: messageKeywords ?? [],
      submittedMessageRegexPatterns: version >= 2 ? (messageRegexPatterns ?? []) : [],
      assistantReplyRegexPatterns: [],
      projectNames: projectNames ?? []
    )
  }
}
