import AppKit
import Observation
import ServiceManagement

enum LaunchAtLoginState: Equatable {
  case enabled
  case disabled
  case requiresApproval
  case updating
  case failed

  var title: String {
    switch self {
    case .enabled: L10n.text("已启用")
    case .disabled: L10n.text("未启用")
    case .requiresApproval: L10n.text("等待系统批准")
    case .updating: L10n.text("正在更新")
    case .failed: L10n.text("更新失败")
    }
  }
}

enum CodexApplicationOpenFailure: Equatable, Sendable {
  case applicationNotFound
  case launchFailed

  var userMessage: String {
    switch self {
    case .applicationNotFound:
      L10n.text("未找到 Codex.app。")
    case .launchFailed:
      L10n.text("Codex.app 无法打开。")
    }
  }
}

@MainActor
@Observable
final class SystemIntegrationService {
  static let codexBundleIdentifier = "com.openai.codex"

  private(set) var launchAtLoginState: LaunchAtLoginState
  private(set) var lastCodexOpenFailure: CodexApplicationOpenFailure?
  private let service: SMAppService

  init(service: SMAppService = .mainApp) {
    self.service = service
    launchAtLoginState = Self.resolve(service.status)
    lastCodexOpenFailure = nil
  }

  func refresh() {
    launchAtLoginState = Self.resolve(service.status)
  }

  func codexAppServerExecutableURL() -> URL? {
    Self.resolveCodexAppServerExecutableURL(
      registeredApplicationURL: NSWorkspace.shared.urlForApplication(
        withBundleIdentifier: Self.codexBundleIdentifier
      ),
      homeDirectoryURL: FileManager.default.homeDirectoryForCurrentUser,
      isExecutable: FileManager.default.isExecutableFile(atPath:)
    )
  }

  func setLaunchAtLoginEnabled(_ enabled: Bool) {
    launchAtLoginState = .updating
    do {
      if enabled { try service.register() } else { try service.unregister() }
      refresh()
    } catch {
      refresh()
      if launchAtLoginState != (enabled ? .enabled : .disabled) {
        launchAtLoginState = .failed
      }
    }
  }

  func openLoginItemsSettings() {
    SMAppService.openSystemSettingsLoginItems()
  }

  @discardableResult
  func openDiagnosticLogs() -> Bool {
    AppLog.lifecycle.notice("The user opened system diagnostics")
    guard
      let consoleURL = NSWorkspace.shared.urlForApplication(
        withBundleIdentifier: "com.apple.Console"
      )
    else {
      return false
    }
    NSWorkspace.shared.openApplication(
      at: consoleURL,
      configuration: NSWorkspace.OpenConfiguration()
    )
    return true
  }

  func setDockIconVisible(_ visible: Bool) {
    NSApp.setActivationPolicy(visible ? .regular : .accessory)
  }

  @discardableResult
  func openCodexApplication() -> Bool {
    let workspace = NSWorkspace.shared
    let registeredApplicationURL = workspace.urlForApplication(
      withBundleIdentifier: Self.codexBundleIdentifier
    )
    guard
      let applicationURL = Self.resolveCodexApplicationURL(
        registeredApplicationURL: registeredApplicationURL,
        homeDirectoryURL: FileManager.default.homeDirectoryForCurrentUser,
        fileExists: FileManager.default.fileExists(atPath:)
      )
    else {
      lastCodexOpenFailure = .applicationNotFound
      return false
    }
    lastCodexOpenFailure = nil
    workspace.openApplication(
      at: applicationURL,
      configuration: NSWorkspace.OpenConfiguration()
    ) { [weak self] application, error in
      Task { @MainActor [weak self] in
        self?.lastCodexOpenFailure = application == nil || error != nil ? .launchFailed : nil
      }
    }
    return true
  }

  static func resolveCodexApplicationURL(
    registeredApplicationURL: URL?,
    homeDirectoryURL: URL,
    fileExists: (String) -> Bool
  ) -> URL? {
    var candidates: [URL] = []
    if let registeredApplicationURL {
      candidates.append(registeredApplicationURL)
    }
    candidates.append(URL(fileURLWithPath: "/Applications/Codex.app", isDirectory: true))
    candidates.append(
      homeDirectoryURL
        .appendingPathComponent("Applications", isDirectory: true)
        .appendingPathComponent("Codex.app", isDirectory: true)
    )

    var visitedPaths: Set<String> = []
    return candidates.first { candidate in
      let path = candidate.standardizedFileURL.path
      return visitedPaths.insert(path).inserted && fileExists(path)
    }
  }

  static func resolveCodexAppServerExecutableURL(
    registeredApplicationURL: URL?,
    homeDirectoryURL: URL,
    isExecutable: (String) -> Bool
  ) -> URL? {
    var applicationCandidates: [URL] = []
    if let registeredApplicationURL {
      applicationCandidates.append(registeredApplicationURL)
    }
    applicationCandidates.append(
      URL(fileURLWithPath: "/Applications/ChatGPT.app", isDirectory: true)
    )
    applicationCandidates.append(
      URL(fileURLWithPath: "/Applications/Codex.app", isDirectory: true)
    )
    for applicationName in ["ChatGPT.app", "Codex.app"] {
      applicationCandidates.append(
        homeDirectoryURL
          .appendingPathComponent("Applications", isDirectory: true)
          .appendingPathComponent(applicationName, isDirectory: true)
      )
    }

    var visitedPaths: Set<String> = []
    for applicationURL in applicationCandidates {
      let executableURL = applicationURL
        .appendingPathComponent("Contents", isDirectory: true)
        .appendingPathComponent("Resources", isDirectory: true)
        .appendingPathComponent("codex", isDirectory: false)
        .standardizedFileURL
      guard visitedPaths.insert(executableURL.path).inserted else { continue }
      if isExecutable(executableURL.path) {
        return executableURL
      }
    }
    return nil
  }

  private static func resolve(_ status: SMAppService.Status) -> LaunchAtLoginState {
    switch status {
    case .enabled: .enabled
    case .requiresApproval: .requiresApproval
    case .notRegistered, .notFound: .disabled
    @unknown default: .disabled
    }
  }
}
