import AppKit
import Foundation
import Observation
import UserNotifications

enum HookDisplayState: Equatable, Sendable {
  case notInstalled
  case checking
  case enabled
  case ran
  case outdated
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
    case .outdated: L10n.text("需更新")
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
    case .outdated, .untrusted, .modified, .disabled, .missing:
      "exclamationmark.triangle.fill"
    case .notChecked, .unavailable: "questionmark.circle"
    }
  }

  var isReady: Bool { self == .enabled }

  var needsAction: Bool {
    switch self {
    case .outdated, .untrusted, .modified, .disabled, .missing, .notInstalled: true
    default: false
    }
  }
}

@MainActor
enum HUDAlertClickAction {
  static func perform(
    sessionID: String,
    unreadRecordID: String?,
    acknowledgeRecord: (String) -> Void,
    returnToCodex: (String) -> Void
  ) {
    if let unreadRecordID {
      acknowledgeRecord(unreadRecordID)
    }
    returnToCodex(sessionID)
  }
}

@MainActor
enum NotchAlertClickAction {
  static func perform(
    requestedSessionID: String?,
    latestUnreadSessionID: String?,
    acknowledgesAll: Bool,
    opensCodex: Bool,
    acknowledgeAll: () -> Void,
    returnToCodex: (String?) -> Void
  ) {
    let returnSessionID = requestedSessionID ?? latestUnreadSessionID
    if acknowledgesAll {
      acknowledgeAll()
    }
    if opensCodex {
      returnToCodex(returnSessionID)
    }
  }
}

@MainActor
@Observable
final class AlertSuppressionRuleStore {
  private(set) var rules: AlertSuppressionRules
  private(set) var operationMessage: String?

  @ObservationIgnored private let fileURL: URL
  @ObservationIgnored private let fileManager: FileManager

  init(
    fileURL: URL = HookRuntimePaths.alertSuppressionRulesURL,
    fileManager: FileManager = .default
  ) {
    self.fileURL = fileURL
    self.fileManager = fileManager
    rules = AlertSuppressionRulesFile.load(from: fileURL, fileManager: fileManager)
  }

  var submittedMessageKeywords: [String] { rules.submittedMessageKeywords }
  var submittedMessageRegexPatterns: [String] { rules.submittedMessageRegexPatterns }
  var assistantReplyRegexPatterns: [String] { rules.assistantReplyRegexPatterns }
  var projectNames: [String] { rules.projectNames }

  @discardableResult
  func addSubmittedMessageKeyword(_ value: String) -> Bool {
    add(value, to: .submittedMessageKeyword)
  }

  @discardableResult
  func addProjectName(_ value: String) -> Bool {
    add(value, to: .projectName)
  }

  @discardableResult
  func addSubmittedMessageRegex(_ value: String) -> Bool {
    add(value, to: .submittedMessageRegex)
  }

  @discardableResult
  func addAssistantReplyRegex(_ value: String) -> Bool {
    add(value, to: .assistantReplyRegex)
  }

  func removeSubmittedMessageKeyword(_ value: String) {
    update(
      AlertSuppressionRules(
        submittedMessageKeywords: rules.submittedMessageKeywords.filter {
          !Self.sameRule($0, value)
        },
        submittedMessageRegexPatterns: rules.submittedMessageRegexPatterns,
        assistantReplyRegexPatterns: rules.assistantReplyRegexPatterns,
        projectNames: rules.projectNames
      )
    )
  }

  func removeSubmittedMessageRegex(_ value: String) {
    update(
      AlertSuppressionRules(
        submittedMessageKeywords: rules.submittedMessageKeywords,
        submittedMessageRegexPatterns: rules.submittedMessageRegexPatterns.filter {
          $0 != value
        },
        assistantReplyRegexPatterns: rules.assistantReplyRegexPatterns,
        projectNames: rules.projectNames
      )
    )
  }

  func removeAssistantReplyRegex(_ value: String) {
    update(
      AlertSuppressionRules(
        submittedMessageKeywords: rules.submittedMessageKeywords,
        submittedMessageRegexPatterns: rules.submittedMessageRegexPatterns,
        assistantReplyRegexPatterns: rules.assistantReplyRegexPatterns.filter {
          $0 != value
        },
        projectNames: rules.projectNames
      )
    )
  }

  func removeProjectName(_ value: String) {
    update(
      AlertSuppressionRules(
        submittedMessageKeywords: rules.submittedMessageKeywords,
        submittedMessageRegexPatterns: rules.submittedMessageRegexPatterns,
        assistantReplyRegexPatterns: rules.assistantReplyRegexPatterns,
        projectNames: rules.projectNames.filter { !Self.sameRule($0, value) }
      )
    )
  }

  private enum RuleKind: Equatable {
    case submittedMessageKeyword
    case submittedMessageRegex
    case assistantReplyRegex
    case projectName
  }

  private func add(_ value: String, to kind: RuleKind) -> Bool {
    let normalized: String?
    switch kind {
    case .submittedMessageRegex, .assistantReplyRegex:
      normalized = AlertSuppressionRules.normalizedRegexRule(value)
    case .submittedMessageKeyword:
      normalized = AlertSuppressionRules.normalizedKeywordRule(value)
    case .projectName:
      normalized = AlertSuppressionRules.normalizedRule(value)
    }
    guard let normalized else {
      operationMessage = kind == .submittedMessageRegex || kind == .assistantReplyRegex
        ? L10n.text("请输入有效的正则表达式")
        : L10n.text("请输入有效的屏蔽规则")
      return false
    }
    let existing: [String]
    switch kind {
    case .submittedMessageKeyword: existing = rules.submittedMessageKeywords
    case .submittedMessageRegex: existing = rules.submittedMessageRegexPatterns
    case .assistantReplyRegex: existing = rules.assistantReplyRegexPatterns
    case .projectName: existing = rules.projectNames
    }
    let containsDuplicate = kind == .submittedMessageRegex || kind == .assistantReplyRegex
      ? existing.contains(normalized)
      : existing.contains(where: { Self.sameRule($0, normalized) })
    if containsDuplicate {
      operationMessage = nil
      return true
    }
    guard existing.count < AlertSuppressionRules.maximumRuleCount else {
      operationMessage = L10n.format(
        "每类最多可添加 %lld 条规则",
        Int64(AlertSuppressionRules.maximumRuleCount)
      )
      return false
    }

    let updated: AlertSuppressionRules
    switch kind {
    case .submittedMessageKeyword:
      updated = AlertSuppressionRules(
        submittedMessageKeywords: rules.submittedMessageKeywords + [normalized],
        submittedMessageRegexPatterns: rules.submittedMessageRegexPatterns,
        assistantReplyRegexPatterns: rules.assistantReplyRegexPatterns,
        projectNames: rules.projectNames
      )
    case .submittedMessageRegex:
      updated = AlertSuppressionRules(
        submittedMessageKeywords: rules.submittedMessageKeywords,
        submittedMessageRegexPatterns: rules.submittedMessageRegexPatterns + [normalized],
        assistantReplyRegexPatterns: rules.assistantReplyRegexPatterns,
        projectNames: rules.projectNames
      )
    case .assistantReplyRegex:
      updated = AlertSuppressionRules(
        submittedMessageKeywords: rules.submittedMessageKeywords,
        submittedMessageRegexPatterns: rules.submittedMessageRegexPatterns,
        assistantReplyRegexPatterns: rules.assistantReplyRegexPatterns + [normalized],
        projectNames: rules.projectNames
      )
    case .projectName:
      updated = AlertSuppressionRules(
        submittedMessageKeywords: rules.submittedMessageKeywords,
        submittedMessageRegexPatterns: rules.submittedMessageRegexPatterns,
        assistantReplyRegexPatterns: rules.assistantReplyRegexPatterns,
        projectNames: rules.projectNames + [normalized]
      )
    }
    return update(updated)
  }

  @discardableResult
  private func update(_ updated: AlertSuppressionRules) -> Bool {
    guard updated != rules else {
      operationMessage = nil
      return true
    }
    do {
      try AlertSuppressionRulesFile.save(updated, to: fileURL, fileManager: fileManager)
      rules = updated
      operationMessage = nil
      return true
    } catch {
      operationMessage = L10n.text("屏蔽规则无法保存")
      return false
    }
  }

  private static func sameRule(_ lhs: String, _ rhs: String) -> Bool {
    lhs.compare(rhs, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
  }
}

@MainActor
@Observable
final class AppEnvironment {
  let localization: ApplicationLocalization
  let completionStore: DesktopCompletionStore
  let alertCoordinator: CompletionAlertCoordinator
  let systemIntegrationService: SystemIntegrationService
  let alertSuppressionRuleStore: AlertSuppressionRuleStore

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

  private(set) var additionalHookInspections: [AgentSource: HookInstallationInspection] = [:]
  @ObservationIgnored private let additionalHookInstallers: [AgentSource: HookInstaller]
  @ObservationIgnored private let hookInstaller: HookInstaller
  @ObservationIgnored private let hookStatusService: CodexHookStatusService
  @ObservationIgnored private let socketServer: HookSocketServer
  @ObservationIgnored private let spoolConsumer: HookSpoolConsumer
  @ObservationIgnored private var spoolPollingTask: Task<Void, Never>?
  @ObservationIgnored private var alertDeliveryTasks: [String: Task<Void, Never>] = [:]
  @ObservationIgnored private var alertDeliveryGenerations: [String: UUID] = [:]
  @ObservationIgnored private var codexReturnTargets: [String: CodexReturnTarget] = [:]
  @ObservationIgnored private var codexReturnTargetSessionOrder: [String] = []
  @ObservationIgnored private var pendingCodexReturnTargetEventIDs: Set<UUID> = []
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
      let suppressionRulesURL =
        isUITest
        ? FileManager.default.temporaryDirectory
          .appendingPathComponent(
            "CodexDoneUITest-\(ProcessInfo.processInfo.processIdentifier)",
            isDirectory: true
          )
          .appendingPathComponent("alert-suppression-rules.json")
        : HookRuntimePaths.alertSuppressionRulesURL
      alertSuppressionRuleStore = AlertSuppressionRuleStore(fileURL: suppressionRulesURL)
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
      alertSuppressionRuleStore = AlertSuppressionRuleStore()
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
    additionalHookInstallers = Dictionary(uniqueKeysWithValues: [AgentSource.claude, .pi].map {
      ($0, HookInstaller(source: $0, installedHelperURL: HookRuntimePaths.installedHookBridgeURL))
    })
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
        self?.openCodex(recordID: recordID)
      }
    }
    alertCoordinator.setVisualAlertOpenCodexActions(
      hud: { [weak self] sessionID in
        guard let self else { return }
        if let sessionID {
          let unreadRecordID = self.completionStore.unreadRecords.first {
            $0.sessionID == sessionID
          }?.id
          HUDAlertClickAction.perform(
            sessionID: sessionID,
            unreadRecordID: unreadRecordID,
            acknowledgeRecord: { self.completionStore.acknowledge(recordID: $0) },
            returnToCodex: { self.returnToCodex(sessionID: $0) }
          )
        } else {
          self.openCodex()
        }
      },
      notch: { [weak self] requestedSessionID, acknowledgesAll in
        guard let self else { return }
        let latestUnreadSessionID = self.completionStore.unreadRecords.first?.sessionID
        let returnSessionID = requestedSessionID ?? latestUnreadSessionID
        NotchAlertClickAction.perform(
          requestedSessionID: requestedSessionID,
          latestUnreadSessionID: latestUnreadSessionID,
          acknowledgesAll: acknowledgesAll,
          opensCodex: self.canOpenCodex(sessionID: returnSessionID),
          acknowledgeAll: { self.completionStore.acknowledgeAll() },
          returnToCodex: { self.returnToCodex(sessionID: $0) }
        )
      },
      canOpenCodex: { [weak self] sessionID in
        self?.canOpenCodex(sessionID: sessionID) ?? false
      }
    )
  }

  var menuBarTitle: String { completionStore.menuBarTitle }
  var canOpenLatestCodex: Bool { canOpenCodex(sessionID: nil) }
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
    hookInspection.isInstalled
      && !hookInspection.helperRequiresUpdate
      && hookStatusInspection.allRequiredHooksAreReady
  }

  var hookConnectionStatusTitle: String {
    guard hookInspection.isInstalled else { return L10n.text("未安装") }
    if hookInspection.helperRequiresUpdate { return L10n.text("需要更新 Hooks") }
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
    if hookInspection.helperRequiresUpdate { return .outdated }
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
        let simulateHooksOutdated = ProcessInfo.processInfo.arguments.contains(
          "--ui-test-hooks-outdated"
        )
        let hooksAreInstalled =
          simulateHooksOutdated || (!showInitializationGuide && !simulateHooksUninstalled)
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
          helperRequiresUpdate: simulateHooksOutdated,
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
    for (source, installer) in additionalHookInstallers {
      additionalHookInspections[source] = await installer.inspect()
    }
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

  func updateHooks(for source: AgentSource, install: Bool) async {
    guard let installer = additionalHookInstallers[source], !isHookOperationInProgress else { return }
    isHookOperationInProgress = true
    defer { isHookOperationInProgress = false }
    do {
      additionalHookInspections[source] = try await (install ? installer.install() : installer.uninstall())
      hookOperationMessage = install
        ? (source == .pi ? L10n.text("已安装，在 Pi 中运行 /reload 生效") : L10n.text("已安装，重新启动会话后生效"))
        : L10n.text("CodexDone Hooks 已移除。")
    } catch {
      hookOperationMessage = error.localizedDescription
    }
  }

  func canOpenRecord(_ record: ConversationCompletionRecord) -> Bool {
    canOpenCodex(sessionID: record.sessionID)
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

  func openCodex(recordID: String? = nil) {
    let sessionID: String?
    if let recordID {
      sessionID = completionStore.records.first(where: { $0.id == recordID })?.sessionID
    } else {
      sessionID = completionStore.unreadRecords.first?.sessionID
    }
    guard canOpenCodex(sessionID: sessionID) else { return }
    returnToCodex(sessionID: sessionID)
  }

  func blockSimilarSubmittedMessages(for record: ConversationCompletionRecord) {
    guard var keyword = record.conversationTitle else { return }
    if keyword.hasSuffix("…") {
      keyword.removeLast()
    }
    guard alertSuppressionRuleStore.addSubmittedMessageKeyword(keyword) else { return }
    completionStore.acknowledge(recordID: record.id)
  }

  func blockProject(for record: ConversationCompletionRecord) {
    guard alertSuppressionRuleStore.addProjectName(record.projectDisplayName) else { return }
    completionStore.acknowledge(recordID: record.id)
  }

  private func returnToCodex(sessionID: String?) {
    if let sessionID, let terminalID = terminalSessionID(for: sessionID) {
      Task { await systemIntegrationService.openTerminalSession(terminalID) }
      return
    }
    if let sessionID, AgentSource.forSession(sessionID) != .codex { return }
    let target = sessionID.flatMap { codexReturnTargets[$0] }
    guard SystemIntegrationService.canReturnToCodex(target) else { return }
    _ = systemIntegrationService.returnToCodex(target)
  }

  private func canOpenCodex(sessionID: String?) -> Bool {
    let resolvedSessionID = sessionID ?? completionStore.unreadRecords.first?.sessionID
    if let resolvedSessionID {
      if terminalSessionID(for: resolvedSessionID) != nil { return true }
      if AgentSource.forSession(resolvedSessionID) != .codex { return false }
    }
    let target = resolvedSessionID.flatMap { codexReturnTargets[$0] }
    return SystemIntegrationService.canReturnToCodex(target)
  }

  private func terminalSessionID(for sessionID: String) -> String? {
    completionStore.sessions[sessionID]?.terminalSessionID
      ?? completionStore.records.first(where: { $0.sessionID == sessionID })?.terminalSessionID
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
          let deliveryMode = HookEventDeliveryMode.startupMode(for: event)
          return await self?.consumeSpoolEvent(
            event,
            deliveryMode: deliveryMode,
            capturesReturnTarget: deliveryMode == .live
          ) ?? false
        }
        self.spoolCount = await self.spoolConsumer.pendingCount()
        try? await Task.sleep(for: .seconds(1))
      }
    }
  }

  private func consumeSpoolEvent(
    _ event: DesktopCompletionHookEvent,
    deliveryMode: HookEventDeliveryMode,
    capturesReturnTarget: Bool = false
  ) async -> Bool {
    AppLog.hooks.notice("A spooled Desktop hook event was consumed")
    let target =
      capturesReturnTarget
      ? returnTarget(for: event, maximumAge: 3)
      : nil
    let didPersist = await completionStore.handlePersisting(
      event,
      deliveryMode: deliveryMode,
      ingress: .spool
    )
    pendingCodexReturnTargetEventIDs.remove(event.eventID)
    if didPersist, let target {
      remember(target, for: event)
    }
    return didPersist
  }

  private func consumeSocketEvent(_ event: DesktopCompletionHookEvent) async -> Bool {
    AppLog.hooks.notice("A live Desktop hook event was received")
    let target = returnTarget(for: event)
    let didPersist = await completionStore.handlePersisting(
      event,
      deliveryMode: .live,
      ingress: .socket
    )
    pendingCodexReturnTargetEventIDs.remove(event.eventID)
    if didPersist, let target {
      remember(target, for: event)
    }
    return didPersist
  }

  private func returnTarget(
    for event: DesktopCompletionHookEvent,
    maximumAge: TimeInterval? = nil
  ) -> CodexReturnTarget? {
    if let maximumAge {
      let age = max(0, Date.now.timeIntervalSince(event.receivedAt))
      guard age <= maximumAge else { return nil }
    }
    guard
      event.source == .codex,
      event.terminalSessionID == nil,
      event.eventName == .userPromptSubmit,
      !completionStore.hasProcessedEventID(event.eventID),
      !pendingCodexReturnTargetEventIDs.contains(event.eventID),
      let target = systemIntegrationService.captureCodexReturnTarget()
    else {
      return nil
    }
    pendingCodexReturnTargetEventIDs.insert(event.eventID)
    return target
  }

  private func remember(_ target: CodexReturnTarget, for event: DesktopCompletionHookEvent) {
    guard
      let session = completionStore.sessions[event.sessionID],
      session.phase == .running,
      session.turnID == event.turnID,
      session.lastEventAt == event.receivedAt
    else {
      return
    }
    codexReturnTargets[event.sessionID] = target
    codexReturnTargetSessionOrder.removeAll(where: { $0 == event.sessionID })
    codexReturnTargetSessionOrder.append(event.sessionID)
    while codexReturnTargetSessionOrder.count > CompletionPersistence.maximumSessions {
      let expiredSessionID = codexReturnTargetSessionOrder.removeFirst()
      codexReturnTargets.removeValue(forKey: expiredSessionID)
    }
  }
}
