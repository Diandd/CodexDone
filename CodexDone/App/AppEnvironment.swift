import AppKit
import Foundation
import Observation
import UserNotifications

enum HookDisplayState: Equatable, Sendable {
  case notInstalled
  case checking
  case enabled
  case ran
  case untrusted
  case modified
  case disabled
  case missing
  case notChecked
  case unavailable

  var title: String {
    switch self {
    case .notInstalled: L10n.text("未安装")
    case .checking: L10n.text("正在检查")
    case .enabled: L10n.text("已启用")
    case .ran: L10n.text("已运行")
    case .untrusted: L10n.text("待信任")
    case .modified: L10n.text("需重新信任")
    case .disabled: L10n.text("已关闭")
    case .missing: L10n.text("未发现")
    case .notChecked: L10n.text("待检查")
    case .unavailable: L10n.text("状态暂不可用")
    }
  }

  var symbolName: String {
    switch self {
    case .enabled: "checkmark.circle.fill"
    case .ran: "checkmark.circle"
    case .checking: "arrow.triangle.2.circlepath"
    case .notInstalled: "minus.circle"
    case .untrusted, .modified, .disabled, .missing: "exclamationmark.triangle.fill"
    case .notChecked, .unavailable: "questionmark.circle"
    }
  }

  var isReady: Bool { self == .enabled }

  var needsAction: Bool {
    switch self {
    case .untrusted, .modified, .disabled, .missing, .notInstalled: true
    default: false
    }
  }
}

@MainActor
@Observable
final class AppEnvironment {
  let localization: ApplicationLocalization
  let completionStore: DesktopCompletionStore
  let alertCoordinator: CompletionAlertCoordinator
  let systemIntegrationService: SystemIntegrationService

  private(set) var hookInspection = HookInstallationInspection(
    isInstalled: false,
    helperIsExecutable: false,
    configurationPath: "",
    detail: L10n.text("正在检查")
  )
  private(set) var isSocketListening = false
  private(set) var spoolCount = 0
  private(set) var hookStatusInspection = CodexHookStatusInspection.notChecked
  private(set) var isHookStatusRefreshing = false
  private(set) var notificationAuthorizationStatus = UNAuthorizationStatus.notDetermined
  private(set) var hookOperationMessage: String?
  private(set) var alertOperationMessage: String?
  private(set) var overlayAppearanceOperationMessage: String?
  private(set) var isHookOperationInProgress = false
  private(set) var statusItemShowsUnreadCount = true
  private(set) var notchUnreadIndicatorEnabled =
    NotchUnreadIndicatorPreference.defaultEnabled

  @ObservationIgnored private let hookInstaller: HookInstaller
  @ObservationIgnored private let hookStatusService: CodexHookStatusService
  @ObservationIgnored private let socketServer: HookSocketServer
  @ObservationIgnored private let spoolConsumer: HookSpoolConsumer
  @ObservationIgnored private var spoolPollingTask: Task<Void, Never>?
  @ObservationIgnored private var alertDeliveryTasks: [String: Task<Void, Never>] = [:]
  @ObservationIgnored private var alertDeliveryGenerations: [String: UUID] = [:]
  @ObservationIgnored private var didStart = false
  #if DEBUG
    @ObservationIgnored private let isUITest: Bool
  #endif

  init(
    isUITest: Bool = false,
    localization: ApplicationLocalization = .shared
  ) {
    #if DEBUG
      self.isUITest = isUITest
    #else
      _ = isUITest
    #endif
    self.localization = localization
    completionStore = DesktopCompletionStore()
    #if DEBUG
      let overlayAppearanceService =
        isUITest
        ? OverlayAppearanceService(
          customImageURL: FileManager.default.temporaryDirectory
            .appendingPathComponent(
              "CodexDoneUITest-\(ProcessInfo.processInfo.processIdentifier)",
              isDirectory: true
            )
            .appendingPathComponent("overlay-background.image")
        )
        : nil
    #else
      let overlayAppearanceService: OverlayAppearanceService? = nil
    #endif
    alertCoordinator = CompletionAlertCoordinator(
      localization: localization,
      overlayAppearanceService: overlayAppearanceService
    )
    systemIntegrationService = SystemIntegrationService()
    hookInstaller = HookInstaller(
      installedHelperURL: HookRuntimePaths.installedHookBridgeURL
    )
    hookStatusService = CodexHookStatusService()
    socketServer = HookSocketServer()
    spoolConsumer = HookSpoolConsumer()
    if UserDefaults.standard.object(
      forKey: ProductConfiguration.statusItemShowsUnreadCountKey
    ) != nil {
      statusItemShowsUnreadCount = UserDefaults.standard.bool(
        forKey: ProductConfiguration.statusItemShowsUnreadCountKey
      )
    }
    notchUnreadIndicatorEnabled = NotchUnreadIndicatorPreference.isEnabled(
      in: UserDefaults.standard
    )

    completionStore.onReadyToReview = { [weak self] record in
      self?.scheduleAlertDelivery(
        AlertPresentation(completion: record),
        completionRecordID: record.id
      )
    }
    completionStore.onDismissAlert = { [weak self] sessionID in
      self?.dismissAlert(sessionID: sessionID)
    }
    completionStore.onUnreadCountChanged = { [weak self] unreadCount in
      self?.alertCoordinator.synchronizeNotchUnreadIndicator(unreadCount: unreadCount)
    }
    alertCoordinator.notificationService.onNotificationOpened = { [weak self] recordID in
      Task { @MainActor in
        _ = recordID
        self?.openCodex()
      }
    }
  }

  var menuBarTitle: String { completionStore.menuBarTitle }
  var soundService: CompletionSoundService { alertCoordinator.soundService }
  var overlayAppearanceService: OverlayAppearanceService {
    alertCoordinator.overlayAppearanceService
  }

  func setStatusItemShowsUnreadCount(_ visible: Bool) {
    guard visible != statusItemShowsUnreadCount else { return }
    statusItemShowsUnreadCount = visible
    UserDefaults.standard.set(
      visible,
      forKey: ProductConfiguration.statusItemShowsUnreadCountKey
    )
  }

  func setNotchUnreadIndicatorEnabled(_ enabled: Bool) {
    guard enabled != notchUnreadIndicatorEnabled else { return }
    notchUnreadIndicatorEnabled = enabled
    UserDefaults.standard.set(enabled, forKey: NotchUnreadIndicatorPreference.storageKey)
    alertCoordinator.synchronizeNotchUnreadIndicator(
      unreadCount: completionStore.unreadCount
    )
  }

  func refreshNotchUnreadIndicatorPlacement() {
    alertCoordinator.synchronizeNotchUnreadIndicator(
      unreadCount: completionStore.unreadCount
    )
  }

  var hookConnectionIsReady: Bool {
    hookInspection.isInstalled && hookStatusInspection.allRequiredHooksAreReady
  }

  var hookConnectionStatusTitle: String {
    guard hookInspection.isInstalled else { return L10n.text("未安装") }
    if isHookStatusRefreshing, hookStatusInspection.availability == .notChecked {
      return L10n.text("正在检查")
    }
    guard hookStatusInspection.availability == .available else {
      return hookStatusInspection.availability == .notChecked
        ? L10n.text("待检查")
        : L10n.text("状态暂不可用")
    }
    if hookStatusInspection.allRequiredHooksAreReady { return L10n.text("已连接") }

    let states = DesktopHookEventName.allCases.map(hookDisplayState(for:))
    if states.contains(.modified) { return L10n.text("需重新信任") }
    if states.contains(.untrusted) { return L10n.text("待在 Codex 中信任") }
    if states.contains(.disabled) { return L10n.text("有 Hook 已关闭") }
    return L10n.text("Hook 未完整发现")
  }

  var hookConnectionSymbolName: String {
    guard hookInspection.isInstalled else { return "link.badge.plus" }
    if isHookStatusRefreshing, hookStatusInspection.availability == .notChecked {
      return "arrow.triangle.2.circlepath"
    }
    if hookConnectionIsReady { return "checkmark.circle.fill" }
    if hookStatusInspection.availability == .available {
      return "exclamationmark.triangle.fill"
    }
    return "questionmark.circle"
  }

  func hookDisplayState(for eventName: DesktopHookEventName) -> HookDisplayState {
    guard hookInspection.isInstalled else { return .notInstalled }
    switch hookStatusInspection.availability {
    case .available:
      guard let status = hookStatusInspection.status(for: eventName) else { return .missing }
      switch status.trustStatus {
      case .modified: return .modified
      case .untrusted: return .untrusted
      case .managed, .trusted:
        return status.isEnabled ? .enabled : .disabled
      }
    case .notChecked:
      if isHookStatusRefreshing { return .checking }
      return hasConfirmedCurrentHookEvent(eventName) ? .ran : .notChecked
    case .unavailable:
      return hasConfirmedCurrentHookEvent(eventName) ? .ran : .unavailable
    }
  }

  var notificationAuthorizationTitle: String {
    switch notificationAuthorizationStatus {
    case .authorized: L10n.text("已允许")
    case .denied: L10n.text("已拒绝")
    case .provisional: L10n.text("临时允许")
    case .ephemeral: L10n.text("临时会话")
    case .notDetermined: L10n.text("尚未请求")
    @unknown default: L10n.text("未知")
    }
  }

  func start() async {
    guard !didStart else { return }
    didStart = true

    #if DEBUG
      if isUITest {
        let showInitializationGuide = ProcessInfo.processInfo.arguments.contains(
          "--ui-test-show-initialization-guide"
        )
        let simulateHooksUninstalled = ProcessInfo.processInfo.arguments.contains(
          "--ui-test-hooks-uninstalled"
        )
        let hooksAreInstalled = !showInitializationGuide && !simulateHooksUninstalled
        let multipleRecords = ProcessInfo.processInfo.arguments.contains(
          "--ui-test-multiple-records"
        )
        let liveMenuTransition = ProcessInfo.processInfo.arguments.contains(
          "--ui-test-menu-live-transition"
        )
        if !liveMenuTransition {
          completionStore.injectUITestRecords(multipleSessions: multipleRecords)
        }
        hookInspection = HookInstallationInspection(
          isInstalled: hooksAreInstalled,
          helperIsExecutable: true,
          configurationPath: "UI Test",
          detail: hooksAreInstalled
            ? L10n.text("UI 测试模拟已安装")
            : L10n.text("UI 测试模拟未安装")
        )
        hookStatusInspection =
          hooksAreInstalled
          ? .available(
            Dictionary(
              uniqueKeysWithValues: DesktopHookEventName.allCases.map {
                ($0, CodexHookRuntimeStatus(isEnabled: true, trustStatus: .trusted))
              }
            )
          )
          : .notChecked
        isSocketListening = true
        notificationAuthorizationStatus = showInitializationGuide ? .notDetermined : .authorized
        return
      }
    #endif

    AppLog.lifecycle.notice("CodexDone startup began")
    await completionStore.load()
    _ = await spoolConsumer.drain { [weak self] event in
      await self?.consumeSpoolEvent(
        event,
        deliveryMode: .startupMode(for: event)
      ) ?? false
    }
    do {
      try socketServer.start { [weak self] event in
        await self?.consumeSocketEvent(event) ?? false
      }
      isSocketListening = true
      AppLog.hooks.notice("The local Hook socket is listening")
    } catch {
      isSocketListening = false
      hookOperationMessage = L10n.text("Socket 启动失败，事件将使用 Spool。")
      AppLog.hooks.error("The local Hook socket could not start; Spool fallback remains active")
    }
    _ = await spoolConsumer.drain { [weak self] event in
      await self?.consumeSpoolEvent(
        event,
        deliveryMode: .startupMode(for: event)
      ) ?? false
    }
    await refreshHealth()
    startSpoolPolling()
  }

  func stop() {
    guard didStart else { return }
    didStart = false
    spoolPollingTask?.cancel()
    spoolPollingTask = nil
    for task in alertDeliveryTasks.values { task.cancel() }
    alertDeliveryTasks.removeAll()
    alertDeliveryGenerations.removeAll()
    socketServer.stop()
    isSocketListening = false
    alertCoordinator.dismissAll(alertIDs: Set(completionStore.records.map(\.id)))
  }

  func refreshHealth() async {
    #if DEBUG
      if isUITest { return }
    #endif
    hookInspection = await hookInstaller.inspect()
    spoolCount = await spoolConsumer.pendingCount()
    notificationAuthorizationStatus =
      await alertCoordinator.notificationService.authorizationStatus()
    systemIntegrationService.refresh()
    await refreshHookStatus()
  }

  func installHooks() async {
    guard !isHookOperationInProgress else { return }
    isHookOperationInProgress = true
    defer { isHookOperationInProgress = false }
    #if DEBUG
      if isUITest {
        hookInspection = HookInstallationInspection(
          isInstalled: true,
          helperIsExecutable: true,
          configurationPath: "UI Test",
          detail: L10n.text("UI 测试模拟已安装")
        )
        hookStatusInspection = .available(
          Dictionary(
            uniqueKeysWithValues: DesktopHookEventName.allCases.map {
              ($0, CodexHookRuntimeStatus(isEnabled: false, trustStatus: .untrusted))
            }
          )
        )
        hookOperationMessage = L10n.text("Hooks 已安装，请在 Codex 中信任并启用。")
        return
      }
    #endif
    do {
      hookInspection = try await hookInstaller.install()
      hookStatusInspection = .notChecked
      await refreshHookStatus()
      hookOperationMessage = L10n.text("Hooks 已安装，请在 Codex 中信任并启用。")
      AppLog.hooks.notice("CodexDone hooks were merged into the user configuration")
    } catch {
      hookOperationMessage = error.localizedDescription
      hookInspection = await hookInstaller.inspect()
      hookStatusInspection = .notChecked
      await refreshHookStatus()
    }
  }

  func uninstallHooks() async {
    guard !isHookOperationInProgress else { return }
    isHookOperationInProgress = true
    defer { isHookOperationInProgress = false }
    do {
      hookInspection = try await hookInstaller.uninstall()
      hookStatusInspection = .notChecked
      hookOperationMessage = L10n.text("CodexDone Hooks 已移除。")
      AppLog.hooks.notice("CodexDone-owned hooks were removed")
    } catch {
      hookOperationMessage = error.localizedDescription
      hookInspection = await hookInstaller.inspect()
      hookStatusInspection = .notChecked
      await refreshHookStatus()
    }
  }

  func requestNotificationAuthorization() async {
    #if DEBUG
      if isUITest {
        notificationAuthorizationStatus = .authorized
        return
      }
    #endif
    _ = await alertCoordinator.notificationService.requestAuthorization()
    notificationAuthorizationStatus =
      await alertCoordinator.notificationService.authorizationStatus()
  }

  func selectLanguage(_ preference: ApplicationLanguagePreference) {
    localization.select(preference)
    hookOperationMessage = nil
    alertOperationMessage = nil
    overlayAppearanceOperationMessage = nil
  }

  func sendTestAlert(
    sequence: Int = 1,
    visualModeOverride: AlertVisualMode? = nil
  ) async {
    let alert = AlertPresentation(
      id: "test-\(UUID().uuidString.lowercased())",
      situation: .completion,
      sessionID: "test-alert-\(sequence)",
      conversationTitle: sequence == 1
        ? L10n.text("检查 CodexDone 提醒样式")
        : L10n.text("验证多对话叠加"),
      projectDisplayName: sequence == 1 ? "CodexDone" : "ProjectSprout"
    )
    await alertCoordinator.deliver(
      alert,
      visualModeOverride: visualModeOverride
    )
  }

  func openCodex() {
    _ = systemIntegrationService.openCodexApplication()
  }

  func importCustomSound(from url: URL) {
    do {
      try soundService.importAudio(from: url)
      alertOperationMessage = L10n.text("自定义音频已导入。")
    } catch {
      alertOperationMessage = error.localizedDescription
    }
  }

  func removeCustomSound() {
    do {
      try soundService.removeCustomSound()
      alertOperationMessage = L10n.text("自定义音频已移除。")
    } catch {
      alertOperationMessage = L10n.text("自定义音频无法移除。")
    }
  }

  func importOverlayBackground(from url: URL) {
    do {
      try overlayAppearanceService.importImage(from: url)
      overlayAppearanceOperationMessage = L10n.text("自定义背景图已导入。")
    } catch {
      overlayAppearanceOperationMessage = error.localizedDescription
    }
  }

  func removeOverlayBackground() {
    do {
      try overlayAppearanceService.removeCustomImage()
      overlayAppearanceOperationMessage = L10n.text("自定义背景图已移除。")
    } catch {
      overlayAppearanceOperationMessage = L10n.text("自定义背景图无法移除。")
    }
  }

  func restoreOverlayAppearanceDefaults() {
    overlayAppearanceService.restoreDefaults()
    overlayAppearanceOperationMessage = L10n.text("全屏外观已恢复默认。")
  }

  private func refreshHookStatus() async {
    guard !isHookStatusRefreshing else { return }
    guard
      hookInspection.isInstalled,
      let handlerCommand = hookInspection.handlerCommand
    else {
      hookStatusInspection = .notChecked
      return
    }

    isHookStatusRefreshing = true
    defer { isHookStatusRefreshing = false }
    let configurationPath = hookInspection.configurationPath
    let result = await hookStatusService.inspect(
      executableURL: systemIntegrationService.codexAppServerExecutableURL(),
      workingDirectory: FileManager.default.homeDirectoryForCurrentUser,
      configurationPath: configurationPath,
      handlerCommand: handlerCommand
    )
    guard
      hookInspection.isInstalled,
      hookInspection.configurationPath == configurationPath,
      hookInspection.handlerCommand == handlerCommand
    else {
      return
    }
    hookStatusInspection = result
    if result.availability == .available {
      if result.allRequiredHooksAreReady {
        AppLog.hooks.notice("The official Hook status query verified all required hooks")
      } else {
        AppLog.hooks.notice("The official Hook status query found required user action")
      }
    } else {
      AppLog.hooks.error("The official Hook status query was unavailable")
    }
  }

  private func hasConfirmedCurrentHookEvent(_ eventName: DesktopHookEventName) -> Bool {
    let receivedAt: Date?
    switch eventName {
    case .userPromptSubmit: receivedAt = completionStore.lastUserPromptAt
    case .stop: receivedAt = completionStore.lastStopAt
    }
    return hookInspection.isConfirmedByHookEvent(receivedAt: receivedAt)
  }

  private func scheduleAlertDelivery(
    _ alert: AlertPresentation,
    completionRecordID: String?
  ) {
    alertDeliveryTasks.removeValue(forKey: alert.sessionID)?.cancel()
    let generation = UUID()
    alertDeliveryGenerations[alert.sessionID] = generation
    alertDeliveryTasks[alert.sessionID] = Task { @MainActor [weak self] in
      guard let self, !Task.isCancelled else { return }
      await self.alertCoordinator.deliver(
        alert,
        unreadCount: self.completionStore.unreadCount
      )
      guard
        !Task.isCancelled,
        self.alertDeliveryGenerations[alert.sessionID] == generation
      else {
        self.alertCoordinator.removeNotifications(alertIDs: [alert.id])
        return
      }
      if let completionRecordID {
        self.completionStore.markNotificationDelivered(recordID: completionRecordID)
      }
      self.alertDeliveryTasks.removeValue(forKey: alert.sessionID)
      self.alertDeliveryGenerations.removeValue(forKey: alert.sessionID)
    }
  }

  private func dismissAlert(sessionID: String) {
    alertDeliveryTasks.removeValue(forKey: sessionID)?.cancel()
    alertDeliveryGenerations.removeValue(forKey: sessionID)
    alertCoordinator.dismiss(
      sessionID: sessionID,
      alertIDs: Set(completionStore.recordIDs(for: sessionID)),
      remainingUnreadCount: completionStore.unreadCount
    )
  }

  private func startSpoolPolling() {
    spoolPollingTask?.cancel()
    spoolPollingTask = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        guard let self else { return }
        _ = await self.spoolConsumer.drain { [weak self] event in
          await self?.consumeSpoolEvent(
            event,
            deliveryMode: .startupMode(for: event)
          ) ?? false
        }
        self.spoolCount = await self.spoolConsumer.pendingCount()
        try? await Task.sleep(for: .seconds(1))
      }
    }
  }

  private func consumeSpoolEvent(
    _ event: DesktopCompletionHookEvent,
    deliveryMode: HookEventDeliveryMode
  ) async -> Bool {
    AppLog.hooks.notice("A spooled Desktop hook event was consumed")
    return await completionStore.handlePersisting(
      event,
      deliveryMode: deliveryMode,
      ingress: .spool
    )
  }

  private func consumeSocketEvent(_ event: DesktopCompletionHookEvent) async -> Bool {
    AppLog.hooks.notice("A live Desktop hook event was received")
    return await completionStore.handlePersisting(
      event,
      deliveryMode: .live,
      ingress: .socket
    )
  }
}
