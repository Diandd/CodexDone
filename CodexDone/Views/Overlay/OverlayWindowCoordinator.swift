import AppKit
import SwiftUI

enum OverlayDismissalMode: String, CaseIterable, Identifiable, Sendable {
  case mouseMovement
  case click

  static let defaultMode = Self.click

  var id: String { rawValue }

  var title: String {
    switch self {
    case .mouseMovement: L10n.text("移动鼠标")
    case .click: L10n.text("点击一次")
    }
  }

  var instruction: String {
    switch self {
    case .mouseMovement: L10n.text("移动鼠标、按任意键、点击或滚动即可关闭")
    case .click: L10n.text("按任意键、点击或滚动即可关闭")
    }
  }

  init(storedValue: String?) {
    self = Self(rawValue: storedValue ?? "") ?? Self.defaultMode
  }
}

enum OverlayAutoDismissDuration: String, CaseIterable, Identifiable, Sendable {
  case never
  case fiveSeconds = "5"
  case tenSeconds = "10"
  case thirtySeconds = "30"
  case sixtySeconds = "60"

  var id: String { rawValue }

  var title: String {
    switch self {
    case .never: L10n.text("永不自动关闭")
    case .fiveSeconds: L10n.text("5 秒")
    case .tenSeconds: L10n.text("10 秒")
    case .thirtySeconds: L10n.text("30 秒")
    case .sixtySeconds: L10n.text("1 分钟")
    }
  }

  var duration: Duration? {
    switch self {
    case .never: nil
    case .fiveSeconds: .seconds(5)
    case .tenSeconds: .seconds(10)
    case .thirtySeconds: .seconds(30)
    case .sixtySeconds: .seconds(60)
    }
  }

  init(storedValue: String?) {
    self = Self(rawValue: storedValue ?? "") ?? .never
  }
}

@MainActor
final class OverlayInteractionPanel: NSPanel {
  var onKeyboardInteraction: (@MainActor () -> Void)?

  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }

  override func keyDown(with event: NSEvent) {
    onKeyboardInteraction?()
  }

  override func flagsChanged(with event: NSEvent) {
    onKeyboardInteraction?()
  }
}

@MainActor
final class OverlayInteractionHostingView<Content: View>: NSHostingView<Content> {
  private let dismissalMode: OverlayDismissalMode
  private let onInteraction: @MainActor () -> Void
  private var interactionTrackingArea: NSTrackingArea?

  init(
    rootView: Content,
    dismissalMode: OverlayDismissalMode = .defaultMode,
    onInteraction: @escaping @MainActor () -> Void
  ) {
    self.dismissalMode = dismissalMode
    self.onInteraction = onInteraction
    super.init(rootView: rootView)
  }

  @available(*, unavailable, message: "Use init(rootView:dismissalMode:onInteraction:)")
  required init(rootView: Content) {
    fatalError("init(rootView:) has not been implemented")
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let interactionTrackingArea {
      removeTrackingArea(interactionTrackingArea)
    }
    interactionTrackingArea = nil
    guard dismissalMode == .mouseMovement else { return }
    let trackingArea = NSTrackingArea(
      rect: .zero,
      options: [.mouseMoved, .activeAlways, .inVisibleRect],
      owner: self,
      userInfo: nil
    )
    addTrackingArea(trackingArea)
    interactionTrackingArea = trackingArea
  }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
    true
  }

  override func mouseMoved(with event: NSEvent) {
    if dismissalMode == .mouseMovement {
      onInteraction()
    }
  }

  override func mouseDown(with event: NSEvent) {
    onInteraction()
  }

  override func rightMouseDown(with event: NSEvent) {
    onInteraction()
  }

  override func otherMouseDown(with event: NSEvent) {
    onInteraction()
  }

  override func scrollWheel(with event: NSEvent) {
    onInteraction()
  }
}

@MainActor
final class OverlayWindowCoordinator {
  static let fadeInDuration: TimeInterval = 0.24
  static let fadeOutDuration: TimeInterval = 0.20

  private var panels: [OverlayInteractionPanel] = []
  private var hostingViews:
    [OverlayInteractionHostingView<ApplicationLocalizedView<CompletionOverlayView>>] = []
  private var fadingPanelGroups: [UUID: [OverlayInteractionPanel]] = [:]
  private var fadeOutTasks: [UUID: Task<Void, Never>] = [:]
  private var alertsBySession: [String: AlertPresentation] = [:]
  private var alertSessionOrder: [String] = []
  private(set) var currentSituation: AlertSituation?
  private var currentDismissalMode = OverlayDismissalMode.defaultMode
  private var currentDisplayStrategy = AlertDisplayStrategy.defaultStrategy
  private var currentHeadlineOverride: String?
  private var currentAppearance = OverlayAppearanceConfiguration.defaultConfiguration
  private var presentationGeneration: UUID?
  private var autoDismissTask: Task<Void, Never>?
  private let localization: ApplicationLocalization
  private let screensProvider: @MainActor () -> [NSScreen]
  private let focusedScreenProvider: @MainActor () -> NSScreen?
  #if DEBUG
    private(set) var currentInteractionHandler: (@MainActor () -> Void)?
    private(set) var currentAutoDismissGeneration: UUID?
  #endif

  var isPresenting: Bool { presentationGeneration != nil }
  var presentedAlertCount: Int { alertsBySession.count }
  var hasScheduledAutoDismiss: Bool { autoDismissTask != nil }

  init(
    localization: ApplicationLocalization = .shared,
    screensProvider: @escaping @MainActor () -> [NSScreen] = { NSScreen.screens },
    focusedScreenProvider: @escaping @MainActor () -> NSScreen? = { NSScreen.main }
  ) {
    self.localization = localization
    self.screensProvider = screensProvider
    self.focusedScreenProvider = focusedScreenProvider
  }

  func show(
    _ alert: AlertPresentation,
    dismissalMode: OverlayDismissalMode = .defaultMode,
    autoDismiss: OverlayAutoDismissDuration = .never,
    headlineOverride: String? = nil,
    appearance: OverlayAppearanceConfiguration = .defaultConfiguration,
    displayStrategy: AlertDisplayStrategy = .defaultStrategy
  ) {
    if let generation = presentationGeneration,
      currentSituation == alert.situation,
      currentDismissalMode == dismissalMode,
      currentDisplayStrategy == displayStrategy
    {
      currentHeadlineOverride = headlineOverride
      currentAppearance = appearance
      upsert(alert)
      updateHostedViews()
      resetAutoDismiss(autoDismiss, presentationGeneration: generation)
      return
    }

    removeAllPanelsImmediately()
    let generation = UUID()
    currentSituation = alert.situation
    currentDismissalMode = dismissalMode
    currentDisplayStrategy = displayStrategy
    currentHeadlineOverride = headlineOverride
    currentAppearance = appearance
    presentationGeneration = generation
    upsert(alert)
    let interactionHandler: @MainActor () -> Void = { [weak self] in
      self?.dismiss(presentationGeneration: generation)
    }
    #if DEBUG
      currentInteractionHandler = interactionHandler
    #endif
    let targetScreens = AlertScreenSelection.screens(
      for: displayStrategy,
      screens: screensProvider(),
      focusedScreen: focusedScreenProvider()
    )
    for screen in targetScreens {
      let panel = Self.makePanel(frame: screen.frame, screen: screen)
      panel.onKeyboardInteraction = interactionHandler
      let hostingView = OverlayInteractionHostingView(
        rootView: makeRootView(),
        dismissalMode: dismissalMode,
        onInteraction: interactionHandler
      )
      panel.contentView = hostingView
      panel.setFrame(screen.frame, display: true)
      panel.alphaValue = 0
      panel.orderFrontRegardless()
      panels.append(panel)
      hostingViews.append(hostingView)
    }
    panels.first?.makeKey()
    NSAnimationContext.runAnimationGroup { context in
      context.duration = Self.fadeInDuration
      for panel in panels {
        panel.animator().alphaValue = 1
      }
    }
    resetAutoDismiss(autoDismiss, presentationGeneration: generation)
  }

  func dismiss(sessionID: String) {
    guard alertsBySession.removeValue(forKey: sessionID) != nil else { return }
    alertSessionOrder.removeAll { $0 == sessionID }
    guard !alertsBySession.isEmpty else {
      dismissAll()
      return
    }
    updateHostedViews()
  }

  func dismissAll() {
    autoDismissTask?.cancel()
    autoDismissTask = nil
    #if DEBUG
      currentAutoDismissGeneration = nil
    #endif
    let panelsToDismiss = panels
    panels.removeAll()
    hostingViews.removeAll()
    alertsBySession.removeAll()
    alertSessionOrder.removeAll()
    currentSituation = nil
    currentDisplayStrategy = .defaultStrategy
    currentHeadlineOverride = nil
    currentAppearance = .defaultConfiguration
    presentationGeneration = nil
    #if DEBUG
      currentInteractionHandler = nil
    #endif
    guard !panelsToDismiss.isEmpty else { return }

    let fadeID = UUID()
    fadingPanelGroups[fadeID] = panelsToDismiss
    NSAnimationContext.runAnimationGroup { context in
      context.duration = Self.fadeOutDuration
      for panel in panelsToDismiss {
        panel.animator().alphaValue = 0
      }
    }
    fadeOutTasks[fadeID] = Task { @MainActor [weak self] in
      do {
        try await Task.sleep(for: .seconds(Self.fadeOutDuration))
      } catch {
        return
      }
      self?.finishFadeOut(fadeID: fadeID)
    }
  }

  static func makePanel(frame: NSRect, screen: NSScreen?) -> OverlayInteractionPanel {
    let panel = OverlayInteractionPanel(
      contentRect: frame,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false,
      screen: screen
    )
    panel.level = .screenSaver
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.hasShadow = false
    panel.ignoresMouseEvents = false
    panel.acceptsMouseMovedEvents = true
    panel.hidesOnDeactivate = false
    panel.becomesKeyOnlyIfNeeded = false
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    return panel
  }

  private func upsert(_ alert: AlertPresentation) {
    alertsBySession[alert.sessionID] = alert
    alertSessionOrder.removeAll { $0 == alert.sessionID }
    alertSessionOrder.append(alert.sessionID)
  }

  private var presentation: OverlayPresentation {
    OverlayPresentation(
      situation: currentSituation ?? .completion,
      alerts: alertSessionOrder.compactMap { alertsBySession[$0] },
      headlineOverride: currentHeadlineOverride
    )
  }

  private func makeRootView() -> ApplicationLocalizedView<CompletionOverlayView> {
    CompletionOverlayView(
      presentation: presentation,
      usesPrivacyShield: Self.usesUITestPrivacyShield,
      dismissalMode: currentDismissalMode,
      appearance: currentAppearance
    )
    .applicationLocalized(using: localization)
  }

  private func updateHostedViews() {
    let rootView = makeRootView()
    for hostingView in hostingViews {
      hostingView.rootView = rootView
    }
  }

  private func resetAutoDismiss(
    _ autoDismiss: OverlayAutoDismissDuration,
    presentationGeneration: UUID
  ) {
    autoDismissTask?.cancel()
    autoDismissTask = nil
    #if DEBUG
      currentAutoDismissGeneration = nil
    #endif
    guard let duration = autoDismiss.duration else { return }
    let timeoutGeneration = UUID()
    #if DEBUG
      currentAutoDismissGeneration = timeoutGeneration
    #endif
    autoDismissTask = Task { @MainActor [weak self] in
      do {
        try await Task.sleep(for: duration)
      } catch {
        return
      }
      guard !Task.isCancelled else { return }
      #if DEBUG
        guard self?.currentAutoDismissGeneration == timeoutGeneration else { return }
      #endif
      self?.dismiss(presentationGeneration: presentationGeneration)
    }
  }

  private func dismiss(presentationGeneration: UUID) {
    guard self.presentationGeneration == presentationGeneration else { return }
    dismissAll()
  }

  private func finishFadeOut(fadeID: UUID) {
    fadeOutTasks.removeValue(forKey: fadeID)
    let panelsToClose = fadingPanelGroups.removeValue(forKey: fadeID) ?? []
    for panel in panelsToClose {
      panel.orderOut(nil)
    }
  }

  private func removeAllPanelsImmediately() {
    autoDismissTask?.cancel()
    autoDismissTask = nil
    for task in fadeOutTasks.values {
      task.cancel()
    }
    fadeOutTasks.removeAll()
    for panel in panels {
      panel.orderOut(nil)
    }
    for group in fadingPanelGroups.values {
      for panel in group {
        panel.orderOut(nil)
      }
    }
    panels.removeAll()
    hostingViews.removeAll()
    fadingPanelGroups.removeAll()
    alertsBySession.removeAll()
    alertSessionOrder.removeAll()
    currentSituation = nil
    currentDisplayStrategy = .defaultStrategy
    currentHeadlineOverride = nil
    currentAppearance = .defaultConfiguration
    presentationGeneration = nil
    #if DEBUG
      currentInteractionHandler = nil
      currentAutoDismissGeneration = nil
    #endif
  }

  private static var usesUITestPrivacyShield: Bool {
    #if DEBUG
      ProcessInfo.processInfo.arguments.contains("--ui-test")
    #else
      false
    #endif
  }
}
