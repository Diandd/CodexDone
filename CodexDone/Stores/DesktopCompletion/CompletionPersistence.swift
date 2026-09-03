import Foundation

actor CompletionPersistence {
  static let maximumSessions = 50
  static let maximumRecords = 50
  static let maximumProcessedEventIDs = 500
  static let maximumHookEventDiagnostics = 20

  private let fileURL: URL
  private let fileManager: FileManager

  init(
    fileURL: URL = HookRuntimePaths.completionStateURL,
    fileManager: FileManager = .default
  ) {
    self.fileURL = fileURL
    self.fileManager = fileManager
  }

  func load() throws -> CompletionPersistedState {
    guard fileManager.fileExists(atPath: fileURL.path) else {
      return CompletionPersistedState()
    }
    let data = try Data(contentsOf: fileURL)
    let envelope = try JSONDecoder().decode(StateVersionEnvelope.self, from: data)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .millisecondsSince1970
    let state: CompletionPersistedState
    switch envelope.version {
    case CompletionPersistedState.currentVersion:
      state = try decoder.decode(CompletionPersistedState.self, from: data)
    case ReleasedCompletionPersistedState.version:
      state = try decoder.decode(ReleasedCompletionPersistedState.self, from: data).migrated()
    default:
      return CompletionPersistedState()
    }
    return normalized(state)
  }

  func save(_ state: CompletionPersistedState) throws {
    let parent = fileURL.deletingLastPathComponent()
    try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
    try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
    let parentAttributes = try fileManager.attributesOfItem(atPath: parent.path)
    guard
      let parentPermissions = parentAttributes[.posixPermissions] as? NSNumber,
      parentPermissions.intValue & 0o777 == 0o700
    else {
      throw CocoaError(.fileWriteNoPermission)
    }

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .millisecondsSince1970
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(normalized(state))
    try data.write(to: fileURL, options: .atomic)
    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    let fileAttributes = try fileManager.attributesOfItem(atPath: fileURL.path)
    guard
      let filePermissions = fileAttributes[.posixPermissions] as? NSNumber,
      filePermissions.intValue & 0o777 == 0o600
    else {
      throw CocoaError(.fileWriteNoPermission)
    }
  }

  private func normalized(_ state: CompletionPersistedState) -> CompletionPersistedState {
    var copy = state
    copy.version = CompletionPersistedState.currentVersion
    copy.sessions = Array(
      state.sessions
        .map { session in
          var redacted = session
          if redacted.phase == .idle || redacted.phase == .running {
            redacted.conversationTitle = nil
            redacted.replyPreview = nil
          }
          return redacted
        }
        .sorted(by: sessionPrecedes)
        .prefix(Self.maximumSessions)
    )
    copy.records = Array(
      state.records
        .map { record in
          var redacted = record
          if redacted.isAcknowledged {
            redacted.conversationTitle = nil
            redacted.replyPreview = nil
          }
          return redacted
        }
        .sorted { $0.completedAt > $1.completedAt }
        .prefix(Self.maximumRecords)
    )
    copy.processedEventIDs = Array(state.processedEventIDs.suffix(Self.maximumProcessedEventIDs))
    copy.hookEventDiagnostics = Array(
      state.hookEventDiagnostics
        .sorted { lhs, rhs in
          if lhs.receivedAt != rhs.receivedAt {
            return lhs.receivedAt > rhs.receivedAt
          }
          return lhs.id.uuidString < rhs.id.uuidString
        }
        .prefix(Self.maximumHookEventDiagnostics)
    )
    return copy
  }

  private func sessionPrecedes(
    _ lhs: CompletionSessionState,
    _ rhs: CompletionSessionState
  ) -> Bool {
    let lhsIsActive = lhs.phase != .idle
    let rhsIsActive = rhs.phase != .idle
    if lhsIsActive != rhsIsActive { return lhsIsActive }
    if lhs.lastEventAt != rhs.lastEventAt { return lhs.lastEventAt > rhs.lastEventAt }
    return lhs.sessionID < rhs.sessionID
  }
}

private struct StateVersionEnvelope: Decodable {
  let version: Int
}

private struct ReleasedCompletionPersistedState: Decodable {
  static let version = 5

  let sessions: [ReleasedCompletionSessionState]
  let records: [ConversationCompletionRecord]
  let processedEventIDs: [UUID]
  let hookEventDiagnostics: [HookEventDiagnosticRecord]
  let lastUserPromptAt: Date?
  let lastStopAt: Date?

  func migrated() -> CompletionPersistedState {
    CompletionPersistedState(
      sessions: sessions.map { $0.migrated() },
      records: records,
      processedEventIDs: processedEventIDs,
      hookEventDiagnostics: hookEventDiagnostics,
      lastUserPromptAt: lastUserPromptAt,
      lastStopAt: lastStopAt
    )
  }
}

private struct ReleasedCompletionSessionState: Decodable {
  let sessionID: String
  let phase: ConversationCompletionPhase
  let turnID: String?
  let projectDisplayName: String
  let lastEventAt: Date
  let pendingEventID: UUID?
  let conversationTitle: String?
  let replyPreview: String?

  func migrated() -> CompletionSessionState {
    CompletionSessionState(
      sessionID: sessionID,
      phase: phase,
      turnID: turnID,
      projectDisplayName: projectDisplayName,
      lastEventAt: lastEventAt,
      pendingEventID: pendingEventID,
      conversationTitle: conversationTitle,
      replyPreview: replyPreview,
      suppressesCurrentTurn: false
    )
  }
}
