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
  case terminalSessionNotFound
  case terminalAutomationDenied

  var userMessage: String {
    switch self {
    case .applicationNotFound:
      L10n.text("未找到 Codex.app。")
    case .launchFailed:
      L10n.text("Codex.app 无法打开。")
    case .terminalSessionNotFound:
      L10n.text("未找到对应的 iTerm2 会话，窗口可能已关闭。")
    case .terminalAutomationDenied:
      L10n.text("请在系统设置 → 隐私与安全性 → 自动化中允许 CodexDone 控制 iTerm2。")
    }
  }
}

enum CodexReturnRoute: Equatable, Sendable {
  case desktop
  case unsupportedCLI
}

struct CodexReturnTarget: Equatable, Sendable {
  let processIdentifier: pid_t
  let bundleIdentifier: String?
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

  func captureCodexReturnTarget() -> CodexReturnTarget? {
    guard let application = NSWorkspace.shared.frontmostApplication else { return nil }
    return Self.resolveCodexReturnTarget(
      processIdentifier: application.processIdentifier,
      currentProcessIdentifier: ProcessInfo.processInfo.processIdentifier,
      bundleIdentifier: application.bundleIdentifier,
      currentBundleIdentifier: Bundle.main.bundleIdentifier,
      isTerminated: application.isTerminated
    )
  }

  @discardableResult
  func returnToCodex(_ target: CodexReturnTarget?) -> Bool {
    guard let target else { return openCodexApplication() }

    guard Self.canReturnToCodex(target) else {
      lastCodexOpenFailure = nil
      return false
    }
    if activate(target) {
      lastCodexOpenFailure = nil
      return true
    }
    return openCodexApplication()
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

  func openTerminalSession(_ sessionID: String) async {
    guard let script = Self.terminalActivationScript(sessionID: sessionID) else { return }
    let result: CodexApplicationOpenFailure? = await Task.detached {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
      process.arguments = ["-e", script]
      let output = Pipe()
      let errors = Pipe()
      process.standardOutput = output
      process.standardError = errors
      do {
        try process.run()
        process.waitUntilExit()
        let error = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        if error.contains("-1743") { return .terminalAutomationDenied }
        let response = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return process.terminationStatus == 0 && response.trimmingCharacters(in: .whitespacesAndNewlines) == "found"
          ? nil : .terminalSessionNotFound
      } catch {
        return .terminalSessionNotFound
      }
    }.value
    lastCodexOpenFailure = result
  }

  nonisolated static func terminalActivationScript(sessionID: String) -> String? {
    guard let id = HookPayloadSanitizer.normalizedTerminalSessionID(sessionID) else { return nil }
    return """
    with timeout of 10 seconds
      tell application id "com.googlecode.iterm2"
        repeat with terminalWindow in windows
          repeat with terminalTab in tabs of terminalWindow
            repeat with terminalSession in sessions of terminalTab
              if unique ID of terminalSession is "\(id)" then
                select terminalSession
                select terminalTab
                select terminalWindow
                activate
                return "found"
              end if
            end repeat
          end repeat
        end repeat
      end tell
    end timeout
    return "missing"
    """
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

  static func resolveCodexReturnTarget(
    processIdentifier: pid_t,
    currentProcessIdentifier: pid_t,
    bundleIdentifier: String?,
    currentBundleIdentifier: String?,
    isTerminated: Bool
  ) -> CodexReturnTarget? {
    guard
      processIdentifier > 0,
      processIdentifier != currentProcessIdentifier,
      !isTerminated
    else {
      return nil
    }
    if let bundleIdentifier, bundleIdentifier == currentBundleIdentifier {
      return nil
    }
    return CodexReturnTarget(
      processIdentifier: processIdentifier,
      bundleIdentifier: bundleIdentifier
    )
  }

  static func returnRoute(for target: CodexReturnTarget) -> CodexReturnRoute {
    target.bundleIdentifier == codexBundleIdentifier ? .desktop : .unsupportedCLI
  }

  static func canReturnToCodex(_ target: CodexReturnTarget?) -> Bool {
    guard let target else { return true }
    return returnRoute(for: target) == .desktop
  }

  static func requestApplicationActivation(
    isAlreadyActive: Bool,
    coordinatedActivation: () -> Bool,
    fallbackActivation: () -> Bool
  ) -> Bool {
    if isAlreadyActive {
      return true
    }
    if coordinatedActivation() {
      return true
    }
    return fallbackActivation()
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

  private func activate(_ target: CodexReturnTarget) -> Bool {
    let processApplication = NSRunningApplication(processIdentifier: target.processIdentifier)
    let matchingProcessApplication: NSRunningApplication? = processApplication.flatMap {
      application -> NSRunningApplication? in
      guard !application.isTerminated else { return nil }
      if let bundleIdentifier = target.bundleIdentifier,
        application.bundleIdentifier != bundleIdentifier
      {
        return nil
      }
      return application
    }
    let application = matchingProcessApplication
      ?? target.bundleIdentifier.flatMap { bundleIdentifier in
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
          .first(where: { !$0.isTerminated })
      }
    guard let application, !application.isTerminated else { return false }
    return Self.requestApplicationActivation(
      isAlreadyActive: application.isActive,
      coordinatedActivation: {
        NSApp.yieldActivation(to: application)
        return application.activate(
          from: NSRunningApplication.current,
          options: [.activateAllWindows]
        )
      },
      fallbackActivation: {
        application.activate(options: [.activateAllWindows])
      }
    )
  }
}
