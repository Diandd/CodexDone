import Foundation

enum HookRuntimePaths {
  #if DEBUG
    private static let socketOverrideKey = "CODEXDONE_BRIDGE_SOCKET_PATH"
    private static let spoolOverrideKey = "CODEXDONE_BRIDGE_SPOOL_DIR"
    private static let suppressionRulesOverrideKey =
      "CODEXDONE_BRIDGE_SUPPRESSION_RULES_PATH"
  #endif

  static var applicationSupportRoot: URL {
    let base = FileManager.default.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first!
    return base.appendingPathComponent("CodexDone", isDirectory: true)
  }

  static var socketURL: URL {
    #if DEBUG
      if let value = ProcessInfo.processInfo.environment[socketOverrideKey], !value.isEmpty {
        return URL(fileURLWithPath: value)
      }
    #endif
    return applicationSupportRoot.appendingPathComponent("bridge.sock")
  }

  static var instanceLockURL: URL {
    applicationSupportRoot.appendingPathComponent("instance.lock")
  }

  static var spoolDirectoryURL: URL {
    #if DEBUG
      if let value = ProcessInfo.processInfo.environment[spoolOverrideKey], !value.isEmpty {
        return URL(fileURLWithPath: value, isDirectory: true)
      }
    #endif
    return applicationSupportRoot.appendingPathComponent("HookSpool", isDirectory: true)
  }

  static var completionStateURL: URL {
    applicationSupportRoot.appendingPathComponent("completion-state.json")
  }

  static var alertSuppressionRulesURL: URL {
    #if DEBUG
      if let value = ProcessInfo.processInfo.environment[suppressionRulesOverrideKey],
        !value.isEmpty
      {
        return URL(fileURLWithPath: value)
      }
    #endif
    return applicationSupportRoot.appendingPathComponent("alert-suppression-rules.json")
  }

  static var installedHookBridgeURL: URL {
    applicationSupportRoot
      .appendingPathComponent("HookBridge", isDirectory: true)
      .appendingPathComponent("CodexDoneHookBridge")
  }

  static var customSoundURL: URL {
    applicationSupportRoot
      .appendingPathComponent("Sounds", isDirectory: true)
      .appendingPathComponent("completion.audio")
  }

  static var overlayBackgroundImageURL: URL {
    applicationSupportRoot
      .appendingPathComponent("Appearance", isDirectory: true)
      .appendingPathComponent("overlay-background.image")
  }
}
