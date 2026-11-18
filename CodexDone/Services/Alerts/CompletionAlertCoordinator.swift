import CoreGraphics
import Foundation

enum AlertVisualMode: String, CaseIterable, Identifiable, Sendable {
  case none
  case smart
  case hud
  case notch
  case fullscreen

  static let defaultMode = Self.smart

  var id: String { rawValue }

  var title: String {
    switch self {
    case .none: L10n.text("alert.visualMode.none")
    case .smart: L10n.text("alert.visualMode.smart")
    case .hud: L10n.text("alert.visualMode.hud")
    case .notch: L10n.text("alert.visualMode.notch")
    case .fullscreen: L10n.text("alert.visualMode.fullscreen")
    }
  }

  init(storedValue: String?) {
    self = Self(rawValue: storedValue ?? "") ?? Self.defaultMode
  }
}

enum AlertVisualDestination: String, CaseIterable, Identifiable, Sendable {
  case none
  case hud
  case notch
  case fullscreen

  static let defaultActive = Self.notch
  static let defaultAway = Self.fullscreen

  var id: String { rawValue }

  var title: String {
    AlertVisualMode(rawValue: rawValue)?.title ?? L10n.text("alert.visualMode.none")
  }

  init(storedValue: String?, fallback: Self) {
    self = Self(rawValue: storedValue ?? "") ?? fallback
  }
}

enum SmartAlertInactivityDuration: String, CaseIterable, Identifiable, Sendable {
  case thirtySeconds = "30"
  case oneMinute = "60"
  case twoMinutes = "120"
  case fiveMinutes = "300"
  case tenMinutes = "600"

  static let defaultDuration = Self.oneMinute

  var id: String { rawValue }
  var seconds: TimeInterval { TimeInterval(rawValue) ?? 60 }

  var title: String {
    switch self {
    case .thirtySeconds: L10n.text("30 秒")
    case .oneMinute: L10n.text("1 分钟")
    case .twoMinutes: L10n.text("2 分钟")
    case .fiveMinutes: L10n.text("5 分钟")
    case .tenMinutes: L10n.text("10 分钟")
    }
  }

  init(storedValue: String?) {
    self = Self(rawValue: storedValue ?? "") ?? Self.defaultDuration
  }
}

enum SmartAlertPreferenceKeys {
  static let activeDestination = "alerts.smart.activeDestination"
  static let awayDestination = "alerts.smart.awayDestination"
  static let inactivityDuration = "alerts.smart.inactivityDuration"
}

enum NotchUnreadIndicatorPreference {
  static let storageKey = "alerts.notchUnreadIndicatorEnabled"
  static let defaultEnabled = true

  static func isEnabled(in defaults: UserDefaults) -> Bool {
    defaults.object(forKey: storageKey) as? Bool ?? defaultEnabled
  }
}

enum SmartAlertActivityState: Equatable, Sendable {
  case active
  case away
}

struct SmartAlertConfiguration: Equatable, Sendable {
  let activeDestination: AlertVisualDestination
  let awayDestination: AlertVisualDestination
  let inactivityDuration: SmartAlertInactivityDuration

  static let defaultConfiguration = Self(
    activeDestination: .defaultActive,
    awayDestination: .defaultAway,
    inactivityDuration: .defaultDuration
  )

  init(
    activeDestination: AlertVisualDestination,
    awayDestination: AlertVisualDestination,
    inactivityDuration: SmartAlertInactivityDuration
  ) {
    self.activeDestination = activeDestination
    self.awayDestination = awayDestination
    self.inactivityDuration = inactivityDuration
  }

  init(defaults: UserDefaults) {
    self.init(
      activeDestination: AlertVisualDestination(
        storedValue: defaults.string(forKey: SmartAlertPreferenceKeys.activeDestination),
        fallback: .defaultActive
      ),
      awayDestination: AlertVisualDestination(
        storedValue: defaults.string(forKey: SmartAlertPreferenceKeys.awayDestination),
        fallback: .defaultAway
      ),
      inactivityDuration: SmartAlertInactivityDuration(
        storedValue: defaults.string(forKey: SmartAlertPreferenceKeys.inactivityDuration)
      )
    )
  }

  func activityState(idleSeconds: TimeInterval) -> SmartAlertActivityState {
    idleSeconds >= inactivityDuration.seconds ? .away : .active
  }

  func destination(idleSeconds: TimeInterval) -> AlertVisualDestination {
    switch activityState(idleSeconds: idleSeconds) {
    case .active: activeDestination
    case .away: awayDestination
    }
  }
}

enum SystemUserIdleTimeProvider {
  static func secondsSinceLastInput() -> TimeInterval {
    guard let anyInputEvent = CGEventType(rawValue: UInt32.max) else { return 0 }
    let seconds = CGEventSource.secondsSinceLastEventType(
      .combinedSessionState,
      eventType: anyInputEvent
    )
    guard seconds.isFinite, seconds >= 0 else { return 0 }
    return seconds
  }
}

extension AlertSituation {
  var alertTitle: String { L10n.text("本轮已结束") }

  var alertBody: String { L10n.text("可以返回会话查看本轮结果") }

  var systemImage: String { "bell.badge.fill" }
}

@MainActor
final class CompletionAlertCoordinator {
  let soundService: CompletionSoundService
  let notificationService: SystemNotificationService
  let overlayAppearanceService: OverlayAppearanceService
  private let notificationDriver: any CompletionNotificationDriving
  private let overlayCoordinator: OverlayWindowCoordinator
  private let hudCoordinator: HUDWindowCoordinator
  private let notchCoordinator: NotchWindowCoordinator
  private let defaults: UserDefaults
  private let idleTimeProvider: () -> TimeInterval
  private var notificationGenerationBySession: [String: UUID] = [:]
  private var notificationAlertIDsBySession: [String: Set<String>] = [:]

  init(
    soundService: CompletionSoundService = CompletionSoundService(),
    notificationService: SystemNotificationService = SystemNotificationService(),
    notificationDriver: (any CompletionNotificationDriving)? = nil,
    localization: ApplicationLocalization = .shared,
    overlayCoordinator: OverlayWindowCoordinator? = nil,
    hudCoordinator: HUDWindowCoordinator? = nil,
    notchCoordinator: NotchWindowCoordinator? = nil,
    overlayAppearanceService: OverlayAppearanceService? = nil,
    defaults: UserDefaults = .standard,
    idleTimeProvider: @escaping () -> TimeInterval = {
      SystemUserIdleTimeProvider.secondsSinceLastInput()
    }
  ) {
    self.soundService = soundService
    self.notificationService = notificationService
    self.notificationDriver = notificationDriver ?? notificationService
    self.overlayCoordinator =
      overlayCoordinator
      ?? OverlayWindowCoordinator(localization: localization)
    self.hudCoordinator =
      hudCoordinator
      ?? HUDWindowCoordinator(localization: localization)
    self.notchCoordinator =
      notchCoordinator
      ?? NotchWindowCoordinator(localization: localization)
    self.overlayAppearanceService =
      overlayAppearanceService
      ?? OverlayAppearanceService(defaults: defaults)
    self.defaults = defaults
    self.idleTimeProvider = idleTimeProvider
  }

  func deliver(
    _ alert: AlertPresentation,
    visualModeOverride: AlertVisualMode? = nil,
    unreadCount: Int? = nil
  ) async {
    guard !Task.isCancelled else {
      notificationDriver.remove(alertIDs: [alert.id])
      return
    }
    let generation = UUID()
    invalidateNotificationDelivery(sessionID: alert.sessionID)
    notificationGenerationBySession[alert.sessionID] = generation

    let appSoundPlayed = soundService.play(
      sessionID: alert.sessionID,
      situation: alert.situation
    )
    let configuredVisualMode =
      visualModeOverride
      ?? AlertVisualMode(storedValue: defaults.string(forKey: "alerts.visualMode"))
    let visualDestination = resolvedVisualDestination(for: configuredVisualMode)
    let displayStrategy = AlertDisplayStrategy(
      storedValue: defaults.string(forKey: AlertDisplayStrategy.storageKey)
    )
    let projectedUnreadCount = unreadCount ?? notchCoordinator.retainedUnreadCount
    let retainsNotchUnreadIndicator = NotchUnreadIndicatorPreference.isEnabled(in: defaults)
    switch visualDestination {
    case .none:
      overlayCoordinator.dismissAll()
      hudCoordinator.dismissAll()
      notchCoordinator.dismissAll()
      break
    case .hud:
      overlayCoordinator.dismissAll()
      notchCoordinator.dismissAll()
      hudCoordinator.show(
        alert,
        headline: AlertHeadlineChannel.hud.resolvedTitle(
          for: alert.situation,
          defaults: defaults
        ),
        displayStrategy: displayStrategy
      )
    case .notch:
      overlayCoordinator.dismissAll()
      hudCoordinator.dismissAll()
      notchCoordinator.show(
        alert,
        headline: AlertHeadlineChannel.hud.resolvedTitle(
          for: alert.situation,
          defaults: defaults
        ),
        displayStrategy: displayStrategy,
        unreadCount: unreadCount,
        retainsUnreadIndicator: retainsNotchUnreadIndicator
      )
    case .fullscreen:
      hudCoordinator.dismissAll()
      notchCoordinator.dismissAll()
      overlayCoordinator.show(
        alert,
        dismissalMode: OverlayDismissalMode(
          storedValue: defaults.string(forKey: "alerts.overlayDismissalMode")
        ),
        autoDismiss: OverlayAutoDismissDuration(
          storedValue: defaults.string(forKey: "alerts.overlayAutoDismiss")
        ),
        headlineOverride: AlertHeadlineChannel.fullscreen.customTitle(defaults: defaults),
        appearance: overlayAppearanceService.configuration(),
        displayStrategy: displayStrategy
      )
    }
    notchCoordinator.synchronizeUnreadIndicator(
      unreadCount: projectedUnreadCount,
      isEnabled: retainsNotchUnreadIndicator,
      displayStrategy: displayStrategy
    )
    if defaults.object(forKey: "alerts.systemNotificationEnabled") as? Bool ?? true {
      notificationAlertIDsBySession[alert.sessionID] = [alert.id]
      await notificationDriver.deliver(
        alertID: alert.id,
        situation: alert.situation,
        title: AlertHeadlineChannel.notification.resolvedTitle(
          for: alert.situation,
          defaults: defaults
        ),
        playSound: Self.notificationShouldPlaySound(appSoundPlayed: appSoundPlayed)
      )
      let isCurrentGeneration =
        notificationGenerationBySession[alert.sessionID] == generation
      guard !Task.isCancelled, isCurrentGeneration else {
        notificationDriver.remove(alertIDs: [alert.id])
        if isCurrentGeneration {
          notificationGenerationBySession.removeValue(forKey: alert.sessionID)
          notificationAlertIDsBySession.removeValue(forKey: alert.sessionID)
        }
        return
      }
    }
    if notificationGenerationBySession[alert.sessionID] == generation {
      notificationGenerationBySession.removeValue(forKey: alert.sessionID)
    }
    AppLog.alerts.notice("An alert was delivered")
  }

  func dismiss(
    sessionID: String,
    alertIDs: Set<String> = [],
    remainingUnreadCount: Int = 0
  ) {
    invalidateNotificationDelivery(
      sessionID: sessionID,
      additionalAlertIDs: alertIDs
    )
    soundService.stop(sessionID: sessionID)
    overlayCoordinator.dismiss(sessionID: sessionID)
    hudCoordinator.dismiss(sessionID: sessionID)
    notchCoordinator.dismiss(
      sessionID: sessionID,
      remainingUnreadCount: remainingUnreadCount,
      retainsUnreadIndicator: NotchUnreadIndicatorPreference.isEnabled(in: defaults)
    )
    synchronizeNotchUnreadIndicator(unreadCount: remainingUnreadCount)
  }

  func dismissAll(alertIDs additionalAlertIDs: Set<String> = []) {
    notificationGenerationBySession.removeAll()
    let alertIDs = Set(notificationAlertIDsBySession.values.flatMap { $0 })
      .union(additionalAlertIDs)
    notificationAlertIDsBySession.removeAll()
    notificationDriver.remove(alertIDs: alertIDs)
    soundService.stopAll()
    overlayCoordinator.dismissAll()
    hudCoordinator.dismissAll()
    notchCoordinator.dismissAll()
  }

  func removeNotifications(alertIDs: Set<String>) {
    notificationDriver.remove(alertIDs: alertIDs)
  }

  func synchronizeNotchUnreadIndicator(unreadCount: Int) {
    notchCoordinator.synchronizeUnreadIndicator(
      unreadCount: unreadCount,
      isEnabled: NotchUnreadIndicatorPreference.isEnabled(in: defaults),
      displayStrategy: AlertDisplayStrategy(
        storedValue: defaults.string(forKey: AlertDisplayStrategy.storageKey)
      )
    )
  }

  func setVisualAlertOpenCodexActions(
    hud hudAction: @escaping @MainActor (String?) -> Void,
    notch notchAction: @escaping @MainActor (String?, Bool) -> Void,
    canOpenCodex: @escaping @MainActor (String?) -> Bool
  ) {
    hudCoordinator.setOpenCodexAction { sessionID in
      hudAction(sessionID)
    }
    hudCoordinator.setOpenCodexAvailability { sessionID in
      canOpenCodex(sessionID)
    }
    notchCoordinator.setOpenCodexAction(notchAction)
    notchCoordinator.setOpenCodexAvailability(canOpenCodex)
  }

  static func notificationShouldPlaySound(appSoundPlayed: Bool) -> Bool {
    !appSoundPlayed
  }

  static func resolvedVisualDestination(
    configuredMode: AlertVisualMode,
    smartConfiguration: SmartAlertConfiguration,
    idleSeconds: TimeInterval
  ) -> AlertVisualDestination {
    switch configuredMode {
    case .none: .none
    case .hud: .hud
    case .notch: .notch
    case .fullscreen: .fullscreen
    case .smart: smartConfiguration.destination(idleSeconds: idleSeconds)
    }
  }

  private func resolvedVisualDestination(
    for configuredMode: AlertVisualMode
  ) -> AlertVisualDestination {
    Self.resolvedVisualDestination(
      configuredMode: configuredMode,
      smartConfiguration: SmartAlertConfiguration(defaults: defaults),
      idleSeconds: configuredMode == .smart ? idleTimeProvider() : 0
    )
  }

  private func invalidateNotificationDelivery(
    sessionID: String,
    additionalAlertIDs: Set<String> = []
  ) {
    notificationGenerationBySession.removeValue(forKey: sessionID)
    let alertIDs = (notificationAlertIDsBySession.removeValue(forKey: sessionID) ?? [])
      .union(additionalAlertIDs)
    notificationDriver.remove(alertIDs: alertIDs)
  }
}
