import Foundation

enum CodexHookStatusAvailability: Equatable, Sendable {
  case notChecked
  case available
  case unavailable
}

enum CodexHookTrustStatus: String, Equatable, Hashable, Sendable {
  case managed
  case untrusted
  case trusted
  case modified

  var isTrusted: Bool {
    self == .managed || self == .trusted
  }
}

struct CodexHookRuntimeStatus: Equatable, Sendable {
  let isEnabled: Bool
  let trustStatus: CodexHookTrustStatus

  var isReady: Bool {
    isEnabled && trustStatus.isTrusted
  }
}

struct CodexHookStatusInspection: Equatable, Sendable {
  let availability: CodexHookStatusAvailability
  let statuses: [DesktopHookEventName: CodexHookRuntimeStatus]

  static let notChecked = CodexHookStatusInspection(
    availability: .notChecked,
    statuses: [:]
  )
  static let unavailable = CodexHookStatusInspection(
    availability: .unavailable,
    statuses: [:]
  )

  static func available(
    _ statuses: [DesktopHookEventName: CodexHookRuntimeStatus]
  ) -> CodexHookStatusInspection {
    CodexHookStatusInspection(availability: .available, statuses: statuses)
  }

  func status(for eventName: DesktopHookEventName) -> CodexHookRuntimeStatus? {
    statuses[eventName]
  }

  var allRequiredHooksAreReady: Bool {
    availability == .available
      && DesktopHookEventName.allCases.allSatisfy { statuses[$0]?.isReady == true }
  }
}

actor CodexHookStatusService {
  private static let hooksListRequestID = 2
  private static let maximumResponseBytes = 2 * 1_024 * 1_024

  func inspect(
    executableURL: URL?,
    workingDirectory: URL,
    configurationPath: String,
    handlerCommand: String,
    timeout: TimeInterval = 5
  ) -> CodexHookStatusInspection {
    guard let executableURL else { return .unavailable }

    let process = Process()
    let standardInput = Pipe()
    let standardOutput = Pipe()
    process.executableURL = executableURL
    process.arguments = ["app-server"]
    process.currentDirectoryURL = workingDirectory
    process.standardInput = standardInput
    process.standardOutput = standardOutput
    process.standardError = FileHandle.nullDevice

    let timeoutState = ProcessTimeoutState()
    let processBox = ProcessBox(process)

    do {
      try process.run()
      DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
        guard processBox.process.isRunning else { return }
        timeoutState.markTimedOut()
        processBox.process.terminate()
      }

      try standardInput.fileHandleForWriting.write(
        contentsOf: try Self.makeInitializeRequest()
      )
      let initializeOutput = try Self.readResponse(
        from: standardOutput.fileHandleForReading,
        throughRequestID: 1
      )
      guard
        !timeoutState.didTimeOut,
        Self.hasSuccessfulResponse(in: initializeOutput, requestID: 1)
      else {
        try? standardInput.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        return .unavailable
      }

      try standardInput.fileHandleForWriting.write(
        contentsOf: try Self.makeHooksListRequest(workingDirectory: workingDirectory)
      )
      let output = try Self.readResponse(
        from: standardOutput.fileHandleForReading,
        throughRequestID: Self.hooksListRequestID
      )
      try? standardInput.fileHandleForWriting.close()
      if process.isRunning { process.terminate() }
      process.waitUntilExit()
      guard !timeoutState.didTimeOut else {
        return .unavailable
      }
      return Self.parseOutput(
        output,
        configurationPath: configurationPath,
        handlerCommand: handlerCommand
      )
    } catch {
      if process.isRunning {
        process.terminate()
      }
      return .unavailable
    }
  }

  nonisolated static func parseOutput(
    _ output: Data,
    configurationPath: String,
    handlerCommand: String
  ) -> CodexHookStatusInspection {
    guard output.count <= maximumResponseBytes else { return .unavailable }

    let targetPath = normalizedPath(configurationPath)
    for line in output.split(separator: 0x0A, omittingEmptySubsequences: true) {
      guard
        let object = try? JSONSerialization.jsonObject(with: Data(line)),
        let envelope = object as? [String: Any],
        (envelope["id"] as? NSNumber)?.intValue == hooksListRequestID,
        envelope["error"] == nil,
        let result = envelope["result"] as? [String: Any],
        let entries = result["data"] as? [[String: Any]]
      else {
        continue
      }

      var statuses: [DesktopHookEventName: CodexHookRuntimeStatus] = [:]
      for entry in entries {
        guard let hooks = entry["hooks"] as? [[String: Any]] else { continue }
        for hook in hooks {
          guard
            hook["handlerType"] as? String == "command",
            hook["command"] as? String == handlerCommand,
            let sourcePath = hook["sourcePath"] as? String,
            normalizedPath(sourcePath) == targetPath,
            let event = desktopEventName(from: hook["eventName"] as? String),
            let enabled = hook["enabled"] as? Bool,
            let trustValue = hook["trustStatus"] as? String,
            let trustStatus = CodexHookTrustStatus(rawValue: trustValue)
          else {
            continue
          }

          let candidate = CodexHookRuntimeStatus(
            isEnabled: enabled,
            trustStatus: trustStatus
          )
          statuses[event] = combine(statuses[event], candidate)
        }
      }
      return .available(statuses)
    }
    return .unavailable
  }

  private nonisolated static func makeInitializeRequest() throws -> Data {
    try encodeMessages([[
      "method": "initialize",
      "id": 1,
      "params": [
        "clientInfo": [
          "name": "codex_done",
          "title": ProductConfiguration.displayName,
          "version": ProductConfiguration.marketingVersion,
        ],
        "capabilities": ["experimentalApi": false],
      ],
    ]])
  }

  private nonisolated static func makeHooksListRequest(
    workingDirectory: URL
  ) throws -> Data {
    try encodeMessages([
      ["method": "initialized", "params": [:]],
      [
        "method": "hooks/list",
        "id": hooksListRequestID,
        "params": ["cwds": [workingDirectory.standardizedFileURL.path]],
      ],
    ])
  }

  private nonisolated static func encodeMessages(
    _ messages: [[String: Any]]
  ) throws -> Data {
    var payload = Data()
    for message in messages {
      payload.append(try JSONSerialization.data(withJSONObject: message))
      payload.append(0x0A)
    }
    return payload
  }

  private nonisolated static func readResponse(
    from handle: FileHandle,
    throughRequestID requestID: Int
  ) throws -> Data {
    var response = Data()
    while true {
      let remaining = maximumResponseBytes + 1 - response.count
      guard remaining > 0 else { return response }
      let available = handle.availableData
      guard !available.isEmpty else {
        return response
      }
      response.append(contentsOf: available.prefix(remaining))
      if containsResponse(in: response, requestID: requestID) {
        return response
      }
    }
  }

  private nonisolated static func containsResponse(
    in output: Data,
    requestID: Int
  ) -> Bool {
    responseEnvelope(in: output, requestID: requestID) != nil
  }

  private nonisolated static func hasSuccessfulResponse(
    in output: Data,
    requestID: Int
  ) -> Bool {
    guard let envelope = responseEnvelope(in: output, requestID: requestID) else {
      return false
    }
    return envelope["error"] == nil && envelope["result"] != nil
  }

  private nonisolated static func responseEnvelope(
    in output: Data,
    requestID: Int
  ) -> [String: Any]? {
    for line in output.split(separator: 0x0A, omittingEmptySubsequences: true) {
      guard
        let object = try? JSONSerialization.jsonObject(with: Data(line)),
        let envelope = object as? [String: Any],
        (envelope["id"] as? NSNumber)?.intValue == requestID
      else {
        continue
      }
      return envelope
    }
    return nil
  }

  private nonisolated static func normalizedPath(_ path: String) -> String {
    URL(fileURLWithPath: path).standardizedFileURL.path
  }

  private nonisolated static func desktopEventName(
    from appServerName: String?
  ) -> DesktopHookEventName? {
    switch appServerName {
    case "userPromptSubmit": .userPromptSubmit
    case "stop": .stop
    default: nil
    }
  }

  private nonisolated static func combine(
    _ existing: CodexHookRuntimeStatus?,
    _ candidate: CodexHookRuntimeStatus
  ) -> CodexHookRuntimeStatus {
    guard let existing else { return candidate }
    return CodexHookRuntimeStatus(
      isEnabled: existing.isEnabled && candidate.isEnabled,
      trustStatus: lessTrusted(existing.trustStatus, candidate.trustStatus)
    )
  }

  private nonisolated static func lessTrusted(
    _ lhs: CodexHookTrustStatus,
    _ rhs: CodexHookTrustStatus
  ) -> CodexHookTrustStatus {
    let order: [CodexHookTrustStatus: Int] = [
      .modified: 0,
      .untrusted: 1,
      .trusted: 2,
      .managed: 3,
    ]
    return (order[lhs] ?? 0) <= (order[rhs] ?? 0) ? lhs : rhs
  }
}

private final class ProcessBox: @unchecked Sendable {
  let process: Process

  init(_ process: Process) {
    self.process = process
  }
}

private final class ProcessTimeoutState: @unchecked Sendable {
  private let lock = NSLock()
  private var value = false

  var didTimeOut: Bool {
    lock.withLock { value }
  }

  func markTimedOut() {
    lock.withLock { value = true }
  }
}
