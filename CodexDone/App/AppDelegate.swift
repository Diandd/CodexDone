import AppKit
import Darwin

enum InitializationGuidePresentationPolicy {
  static func launchContext(
    forceForUITest: Bool,
    isUITest: Bool,
    hasPresentedInitializationGuide: Bool,
    helperRequiresUpdate: Bool
  ) -> InitializationGuideLaunchContext? {
    if forceForUITest {
      return helperRequiresUpdate ? .hookUpdate : .standard
    }
    guard !isUITest else { return nil }
    if helperRequiresUpdate { return .hookUpdate }
    return hasPresentedInitializationGuide ? nil : .standard
  }
}

final class ApplicationInstanceLock {
  private let lockURL: URL
  private let fileManager: FileManager
  private var descriptor: Int32 = -1

  init(
    lockURL: URL = HookRuntimePaths.instanceLockURL,
    fileManager: FileManager = .default
  ) {
    self.lockURL = lockURL
    self.fileManager = fileManager
  }

  @discardableResult
  func acquire() -> Bool {
    if descriptor >= 0 { return true }
    let directoryURL = lockURL.deletingLastPathComponent()
    do {
      try fileManager.createDirectory(
        at: directoryURL,
        withIntermediateDirectories: true
      )
      try fileManager.setAttributes(
        [.posixPermissions: 0o700],
        ofItemAtPath: directoryURL.path
      )
    } catch {
      return false
    }

    let candidate = Darwin.open(
      lockURL.path,
      O_CREAT | O_RDWR | O_CLOEXEC | O_EXLOCK | O_NONBLOCK,
      S_IRUSR | S_IWUSR
    )
    guard candidate >= 0 else { return false }
    guard Darwin.fchmod(candidate, S_IRUSR | S_IWUSR) == 0 else {
      Darwin.close(candidate)
      return false
    }
    descriptor = candidate
    return true
  }

  func release() {
    guard descriptor >= 0 else { return }
    Darwin.close(descriptor)
    descriptor = -1
  }

  deinit {
    release()
  }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  let environment: AppEnvironment
  private let instanceLock = ApplicationInstanceLock()
  private var statusItemController: StatusItemController?
  private var initializationGuideWindowController: InitializationGuideWindowController?
  private var hasFinishedStartup = false

  override init() {
    #if DEBUG
      let isUITest =
        ProcessInfo.processInfo.arguments.contains("--ui-test") || Self.isXCTestHost
      environment = AppEnvironment(isUITest: isUITest)
    #else
      environment = AppEnvironment()
    #endif
    super.init()
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    let arguments = ProcessInfo.processInfo.arguments
    #if DEBUG
      let bypassInstanceLock =
        arguments.contains("--ui-test")
        || arguments.contains("--offscreen-audio-smoke")
        || arguments.contains("--install-hooks-smoke")
        || Self.isXCTestHost
    #else
      let bypassInstanceLock = false
    #endif
    guard bypassInstanceLock || instanceLock.acquire() else {
      AppLog.lifecycle.notice("Another CodexDone instance is already active")
      NSApplication.shared.terminate(nil)
      return
    }

    applyBundledApplicationIcon()
    ApplicationAppearancePreference(
      storedValue: UserDefaults.standard.string(forKey: "appearance.colorScheme")
    ).applyToApplication()
    let showDockIcon = UserDefaults.standard.bool(forKey: "general.showDockIcon")
    environment.systemIntegrationService.setDockIconVisible(showDockIcon)

    #if DEBUG
      if let smoke = offscreenAudioSmokeArguments(arguments) {
        Task { @MainActor [weak self] in
          await self?.runOffscreenAudioSmoke(smoke)
          NSApplication.shared.terminate(nil)
        }
        return
      }
      if let reportURL = hookInstallSmokeReportURL(arguments) {
        Task { @MainActor [weak self] in
          await self?.runHookInstallSmoke(reportURL: reportURL)
          NSApplication.shared.terminate(nil)
        }
        return
      }
    #endif

    statusItemController = StatusItemController(environment: environment)

    Task { @MainActor [weak self, environment] in
      await environment.start()
      self?.hasFinishedStartup = true
      self?.presentInitializationGuideIfNeeded(arguments: arguments)
      #if DEBUG
        if arguments.contains("--ui-test-show-overlay")
          || arguments.contains("--ui-test-show-hud")
          || arguments.contains("--ui-test-show-notch")
          || arguments.contains("--ui-test-show-multiple-overlay")
        {
          try? await Task.sleep(for: .milliseconds(300))
          if arguments.contains("--ui-test-show-multiple-overlay") {
            await environment.sendTestAlert(sequence: 1)
            try? await Task.sleep(for: .milliseconds(100))
            await environment.sendTestAlert(sequence: 2)
          } else {
            await environment.sendTestAlert()
          }
        }
      #endif
    }

    #if DEBUG
      if ProcessInfo.processInfo.arguments.contains("--ui-test-open-menu-popover") {
        Task { @MainActor [weak self] in
          try? await Task.sleep(for: .milliseconds(700))
          self?.statusItemController?.showPopover()
          if arguments.contains("--ui-test-menu-live-transition") {
            // Leave the empty state visible long enough for XCUITest to
            // observe it before simulating an event arriving from outside.
            try? await Task.sleep(for: .seconds(2))
            self?.environment.completionStore.injectUITestRecords()
          }
        }
      }
    #endif
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    false
  }

  func applicationDidBecomeActive(_ notification: Notification) {
    guard hasFinishedStartup else { return }
    Task { @MainActor [weak self] in
      await self?.environment.refreshHealth()
    }
  }

  func applicationWillTerminate(_ notification: Notification) {
    environment.stop()
    instanceLock.release()
  }

  private func applyBundledApplicationIcon() {
    guard
      let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
      let icon = NSImage(contentsOf: iconURL)
    else { return }
    NSApplication.shared.applicationIconImage = icon
  }

  private func presentInitializationGuideIfNeeded(arguments: [String]) {
    #if DEBUG
      let isUITest = arguments.contains("--ui-test") || Self.isXCTestHost
      let forceForUITest = arguments.contains("--ui-test-show-initialization-guide")
    #else
      _ = arguments
      let isUITest = false
      let forceForUITest = false
    #endif
    guard
      let launchContext = InitializationGuidePresentationPolicy.launchContext(
        forceForUITest: forceForUITest,
        isUITest: isUITest,
        hasPresentedInitializationGuide: hasPresentedInitializationGuide,
        helperRequiresUpdate: environment.hookInspection.helperRequiresUpdate
      )
    else {
      return
    }

    if !isUITest {
      UserDefaults.standard.set(
        true,
        forKey: ProductConfiguration.initializationGuidePresentedKey
      )
    }
    presentInitializationGuide(launchContext: launchContext)
  }

  func presentInitializationGuide() {
    presentInitializationGuide(launchContext: .standard)
  }

  private func presentInitializationGuide(
    launchContext: InitializationGuideLaunchContext
  ) {
    if let controller = initializationGuideWindowController,
      controller.window?.isVisible == true
    {
      controller.present()
      return
    }
    let controller = InitializationGuideWindowController(
      environment: environment,
      launchContext: launchContext
    )
    initializationGuideWindowController = controller
    controller.present()
  }

  private var hasPresentedInitializationGuide: Bool {
    UserDefaults.standard.bool(forKey: ProductConfiguration.initializationGuidePresentedKey)
  }

  #if DEBUG
    private static var isXCTestHost: Bool {
      ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
  #endif

  #if DEBUG
    private struct OffscreenAudioSmokeArguments {
      let sourceAudio: URL
      let report: URL
    }

    private struct OffscreenAudioSmokeReport: Encodable {
      let version = 1
      let passed: Bool
      let defaultPlayback: Bool
      let customImport: Bool
      let customPlayback: Bool
      let failure: String?
    }

    private struct HookInstallSmokeReport: Encodable {
      let version = 1
      let passed: Bool
      let installed: Bool
      let helperExecutable: Bool
    }

    private func offscreenAudioSmokeArguments(
      _ arguments: [String]
    ) -> OffscreenAudioSmokeArguments? {
      guard
        let marker = arguments.firstIndex(of: "--offscreen-audio-smoke"),
        arguments.indices.contains(marker + 2)
      else {
        return nil
      }
      let source = URL(fileURLWithPath: arguments[marker + 1])
      let report = URL(fileURLWithPath: arguments[marker + 2])
      guard CompletionSoundService.supportedExtensions.contains(
        source.pathExtension.lowercased()
      ) else { return nil }
      return OffscreenAudioSmokeArguments(sourceAudio: source, report: report)
    }

    private func runOffscreenAudioSmoke(_ arguments: OffscreenAudioSmokeArguments) async {
      let suiteName = "CodexDone.OffscreenAudioSmoke.\(UUID().uuidString)"
      guard let defaults = UserDefaults(suiteName: suiteName) else { return }
      defer { defaults.removePersistentDomain(forName: suiteName) }
      defaults.set(true, forKey: "alerts.completion.soundEnabled")
      defaults.set(false, forKey: "alerts.completion.useCustomSound")
      defaults.set("Glass", forKey: "alerts.completion.builtInSound")
      let destination = arguments.report.deletingLastPathComponent()
        .appendingPathComponent("imported-test-sound.audio")
      let service = CompletionSoundService(
        defaults: defaults,
        customSoundURL: destination
      )

      let defaultPlayback = service.play(
        sessionID: "offscreen-default",
        situation: .completion
      )
      try? await Task.sleep(for: .milliseconds(400))
      service.stopAll()
      var customImport = false
      var customPlayback = false
      var failure: String?
      do {
        try service.importAudio(from: arguments.sourceAudio)
        customImport = true
        defaults.set(true, forKey: "alerts.completion.useCustomSound")
        customPlayback = service.preview(situation: .completion)
        try? await Task.sleep(for: .milliseconds(400))
        service.stopAll()
      } catch {
        failure = "custom audio validation or playback failed"
      }

      let report = OffscreenAudioSmokeReport(
        passed: defaultPlayback && customImport && customPlayback,
        defaultPlayback: defaultPlayback,
        customImport: customImport,
        customPlayback: customPlayback,
        failure: failure
      )
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      if let data = try? encoder.encode(report) {
        try? data.write(to: arguments.report, options: .atomic)
      }
    }

    private func hookInstallSmokeReportURL(_ arguments: [String]) -> URL? {
      guard
        let marker = arguments.firstIndex(of: "--install-hooks-smoke"),
        arguments.indices.contains(marker + 1)
      else {
        return nil
      }
      return URL(fileURLWithPath: arguments[marker + 1])
    }

    private func runHookInstallSmoke(reportURL: URL) async {
      await environment.installHooks()
      let inspection = environment.hookInspection
      let report = HookInstallSmokeReport(
        passed: inspection.isInstalled && inspection.helperIsExecutable,
        installed: inspection.isInstalled,
        helperExecutable: inspection.helperIsExecutable
      )
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      if let data = try? encoder.encode(report) {
        try? data.write(to: reportURL, options: .atomic)
      }
    }
  #endif

}
