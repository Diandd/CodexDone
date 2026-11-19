import AppKit
import Observation
import SwiftUI

enum NotchAlertMotion {
  static let springDuration: TimeInterval = 0.34
  static let springBounce = 0.52
  static let hoverScale: CGFloat = 1.018

  static var spring: Animation {
    .spring(duration: springDuration, bounce: springBounce)
  }
}

enum NotchAlertShapeMetrics {
  static let expandedAttachedBottomCornerRadius: CGFloat = 24
  static let compactAttachedBottomCornerRadius: CGFloat = 18
  static let floatingCornerRadius: CGFloat = 20

  static func bottomCornerRadius(
    isAttachedToCameraHousing: Bool,
    isExpanded: Bool
  ) -> CGFloat {
    guard isAttachedToCameraHousing else { return floatingCornerRadius }
    return isExpanded
      ? expandedAttachedBottomCornerRadius
      : compactAttachedBottomCornerRadius
  }
}

struct NotchAlertLayout: Equatable, Sendable {
  static let maximumExpandedWidth: CGFloat = 360
  static let minimumExpandedWidth: CGFloat = 286
  static let horizontalShadowInset: CGFloat = 24
  static let bottomShadowInset: CGFloat = 34
  static let floatingTopInset: CGFloat = 10
  static let panelHeight: CGFloat = expandedHeight + bottomShadowInset + floatingTopInset
  static let expandedHeight: CGFloat = 116
  static let preferredCompactWingWidth: CGFloat = 32
  static let floatingCompactWidth: CGFloat = 112
  static let floatingCompactHeight: CGFloat = 32

  let panelFrame: NSRect
  let expandedWidth: CGFloat
  let compactWidth: CGFloat
  let compactHeight: CGFloat
  let compactWingWidth: CGFloat
  let cameraHousingWidth: CGFloat
  let contentTopInset: CGFloat
  let isAttachedToCameraHousing: Bool

  private init(
    panelFrame: NSRect,
    expandedWidth: CGFloat,
    compactWidth: CGFloat,
    compactHeight: CGFloat,
    compactWingWidth: CGFloat,
    cameraHousingWidth: CGFloat,
    contentTopInset: CGFloat,
    isAttachedToCameraHousing: Bool
  ) {
    self.panelFrame = panelFrame
    self.expandedWidth = expandedWidth
    self.compactWidth = compactWidth
    self.compactHeight = compactHeight
    self.compactWingWidth = compactWingWidth
    self.cameraHousingWidth = cameraHousingWidth
    self.contentTopInset = contentTopInset
    self.isAttachedToCameraHousing = isAttachedToCameraHousing
  }

  static func make(
    screenFrame: NSRect,
    visibleFrame: NSRect,
    safeAreaTop: CGFloat,
    auxiliaryTopLeftArea: NSRect?,
    auxiliaryTopRightArea: NSRect?,
    coexistsWithAlcove: Bool = false
  ) -> Self {
    let isAttached = safeAreaTop > 0 && !coexistsWithAlcove
    let availableWidth = max(
      220,
      min(screenFrame.width, visibleFrame.width) - horizontalShadowInset * 2 - 24
    )
    let expandedWidth = min(
      maximumExpandedWidth,
      max(minimumExpandedWidth, availableWidth)
    )
    let measuredCameraHousingWidth: CGFloat = {
      guard
        isAttached,
        let leftArea = auxiliaryTopLeftArea,
        let rightArea = auxiliaryTopRightArea,
        rightArea.minX > leftArea.maxX
      else {
        return isAttached ? 172 : 0
      }
      return rightArea.minX - leftArea.maxX
    }()
    let compactWidth = isAttached
      ? min(
        expandedWidth,
        measuredCameraHousingWidth + preferredCompactWingWidth * 2
      )
      : floatingCompactWidth
    let compactWingWidth = isAttached
      ? max(0, (compactWidth - measuredCameraHousingWidth) / 2)
      : 0
    let compactHeight = isAttached
      ? min(44, max(28, safeAreaTop))
      : floatingCompactHeight
    let contentTopInset = isAttached ? 0 : floatingTopInset
    let panelWidth = expandedWidth + horizontalShadowInset * 2
    // shortcut: reserve space for Alcove's compact alerts; its expanded panels are not tracked.
    let topEdge = coexistsWithAlcove
      ? min(visibleFrame.maxY, screenFrame.maxY - max(safeAreaTop, floatingCompactHeight))
      : (isAttached ? screenFrame.maxY : visibleFrame.maxY)
    let panelFrame = NSRect(
      x: screenFrame.midX - panelWidth / 2,
      y: topEdge - panelHeight,
      width: panelWidth,
      height: panelHeight
    )
    return Self(
      panelFrame: panelFrame,
      expandedWidth: expandedWidth,
      compactWidth: compactWidth,
      compactHeight: compactHeight,
      compactWingWidth: compactWingWidth,
      cameraHousingWidth: measuredCameraHousingWidth,
      contentTopInset: contentTopInset,
      isAttachedToCameraHousing: isAttached
    )
  }

  @MainActor
  init(screen: NSScreen) {
    var coexistsWithAlcove = !NSRunningApplication.runningApplications(
      withBundleIdentifier: "com.henrikruscon.Alcove"
    ).isEmpty
    #if DEBUG
      if ProcessInfo.processInfo.arguments.contains("--ui-test-alcove-running") {
        coexistsWithAlcove = true
      }
    #endif
    self = Self.make(
      screenFrame: screen.frame,
      visibleFrame: screen.visibleFrame,
      safeAreaTop: screen.safeAreaInsets.top,
      auxiliaryTopLeftArea: screen.auxiliaryTopLeftArea,
      auxiliaryTopRightArea: screen.auxiliaryTopRightArea,
      coexistsWithAlcove: coexistsWithAlcove
    )
  }

  func interactionFrame(isExpanded: Bool) -> NSRect {
    let width = isExpanded ? expandedWidth : compactWidth
    let height = isExpanded ? Self.expandedHeight : compactHeight
    return NSRect(
      x: panelFrame.midX - width / 2,
      y: panelFrame.maxY - contentTopInset - height,
      width: width,
      height: height
    )
  }
}

@MainActor
@Observable
final class NotchAlertAnimationState {
  let alert: AlertPresentation?
  let headline: String
  let layout: NotchAlertLayout
  var isExpanded = false
  var isHovered = false
  var openFailureMessage: String?
  var unreadCount: Int

  init(
    alert: AlertPresentation? = nil,
    headline: String = "",
    layout: NotchAlertLayout,
    unreadCount: Int
  ) {
    self.alert = alert
    self.headline = headline
    self.layout = layout
    self.unreadCount = max(1, unreadCount)
  }
}

@MainActor
final class NotchInteractionView: NSView {
  var sessionID: String?
  var opensCodex: Bool {
    didSet { updateInteractionAvailability() }
  }
  var hasUnreadRecords: Bool {
    didSet { updateInteractionAvailability() }
  }
  var isInteractionEnabled: Bool { opensCodex || hasUnreadRecords }
  private let onOpenCodex: @MainActor (String?, Bool) -> Void
  private let onHoverChanged: @MainActor (Bool) -> Void
  private var hoverTrackingArea: NSTrackingArea?
  private(set) var isPointerInside = false

  init(
    sessionID: String?,
    opensCodex: Bool = true,
    hasUnreadRecords: Bool,
    onHoverChanged: @escaping @MainActor (Bool) -> Void = { _ in },
    onOpenCodex: @escaping @MainActor (String?, Bool) -> Void
  ) {
    self.sessionID = sessionID
    self.opensCodex = opensCodex
    self.hasUnreadRecords = hasUnreadRecords
    self.onHoverChanged = onHoverChanged
    self.onOpenCodex = onOpenCodex
    super.init(frame: .zero)
    setAccessibilityRole(.button)
    setAccessibilityIdentifier("completion-notch-open-codex")
    updateInteractionAvailability()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
    isInteractionEnabled
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let hoverTrackingArea {
      removeTrackingArea(hoverTrackingArea)
    }
    let trackingArea = NSTrackingArea(
      rect: .zero,
      options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
      owner: self,
      userInfo: nil
    )
    addTrackingArea(trackingArea)
    hoverTrackingArea = trackingArea
  }

  override func mouseEntered(with event: NSEvent) {
    guard isInteractionEnabled else { return }
    setPointerInside(true)
  }

  override func mouseExited(with event: NSEvent) {
    guard isInteractionEnabled else { return }
    setPointerInside(false)
  }

  override func mouseDown(with event: NSEvent) {}

  override func mouseUp(with event: NSEvent) {
    guard isInteractionEnabled else { return }
    let location = convert(event.locationInWindow, from: nil)
    guard bounds.contains(location) else { return }
    onOpenCodex(sessionID, hasUnreadRecords)
  }

  override func accessibilityPerformPress() -> Bool {
    guard isInteractionEnabled else { return false }
    onOpenCodex(sessionID, hasUnreadRecords)
    return true
  }

  private func setPointerInside(_ isInside: Bool) {
    guard isPointerInside != isInside else { return }
    isPointerInside = isInside
    onHoverChanged(isInside)
  }

  func cancelPointerInteraction() {
    setPointerInside(false)
  }

  private func updateInteractionAvailability() {
    if !isInteractionEnabled {
      cancelPointerInteraction()
    }
    setAccessibilityElement(isInteractionEnabled)
    setAccessibilityLabel(L10n.text("打开会话"))
  }
}

struct NotchAlertView: View {
  @Bindable var animationState: NotchAlertAnimationState

  var body: some View {
    let layout = animationState.layout
    let isExpanded = animationState.isExpanded
    let width = isExpanded ? layout.expandedWidth : layout.compactWidth
    let height = isExpanded ? NotchAlertLayout.expandedHeight : layout.compactHeight

    ZStack(alignment: .top) {
      containerShape
        .fill(.black.opacity(0.97))
        .overlay {
          containerShape
            .stroke(.white.opacity(isExpanded ? 0.12 : 0.07), lineWidth: 1)
        }
        .frame(width: width, height: height)
        .shadow(
          color: .black.opacity(isExpanded ? 0.34 : 0.22),
          radius: isExpanded ? 14 : 6,
          y: isExpanded ? 7 : 2
        )
        .offset(y: layout.contentTopInset)

      if isExpanded {
        expandedContent
          .padding(.top, layout.isAttachedToCameraHousing ? layout.compactHeight - 2 : 4)
          .frame(
            width: layout.expandedWidth,
            height: NotchAlertLayout.expandedHeight,
            alignment: .top
          )
          .offset(y: layout.contentTopInset)
          .transition(.opacity.combined(with: .offset(y: -6)))
      } else {
        compactUnreadIndicator
          .frame(width: layout.compactWidth, height: layout.compactHeight)
          .offset(y: layout.contentTopInset)
          .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .top)))
      }
    }
    .frame(
      width: layout.panelFrame.width,
      height: layout.panelFrame.height,
      alignment: .top
    )
    .scaleEffect(
      animationState.isHovered ? NotchAlertMotion.hoverScale : 1,
      anchor: .top
    )
    .animation(NotchAlertMotion.spring, value: isExpanded)
    .animation(NotchAlertMotion.spring, value: animationState.isHovered)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("completion-notch-alert")
  }

  private var containerShape: UnevenRoundedRectangle {
    let attached = animationState.layout.isAttachedToCameraHousing
    let bottomCornerRadius = NotchAlertShapeMetrics.bottomCornerRadius(
      isAttachedToCameraHousing: attached,
      isExpanded: animationState.isExpanded
    )
    return UnevenRoundedRectangle(
      topLeadingRadius: attached ? 0 : 20,
      bottomLeadingRadius: bottomCornerRadius,
      bottomTrailingRadius: bottomCornerRadius,
      topTrailingRadius: attached ? 0 : 20,
      style: .continuous
    )
  }

  @ViewBuilder
  private var compactUnreadIndicator: some View {
    let layout = animationState.layout
    if layout.isAttachedToCameraHousing {
      HStack(spacing: 0) {
        NotchUnreadStatusIcon()
          .frame(width: layout.compactWingWidth)

        Color.clear
          .frame(width: layout.cameraHousingWidth)

        unreadCountText
          .frame(width: layout.compactWingWidth)
      }
      .frame(maxHeight: .infinity)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(unreadAccessibilityLabel)
    } else {
      HStack(spacing: 10) {
        NotchUnreadStatusIcon()
        unreadCountText
      }
      .padding(.horizontal, 14)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(unreadAccessibilityLabel)
    }
  }

  private var unreadCountText: some View {
    Text("\(animationState.unreadCount)")
      .font(.system(size: 13, weight: .bold, design: .rounded))
      .monospacedDigit()
      .foregroundStyle(.white)
      .lineLimit(1)
      .accessibilityIdentifier("completion-notch-unread-count")
  }

  private var unreadAccessibilityLabel: String {
    L10n.format("%lld 条对话可查看", Int64(animationState.unreadCount))
  }

  @ViewBuilder
  private var expandedContent: some View {
    if let message = animationState.openFailureMessage {
      VStack(alignment: .leading, spacing: 4) {
        Label("无法打开会话", systemImage: "exclamationmark.triangle")
          .font(.headline)
          .foregroundStyle(.orange)
        Text(message)
          .font(.caption)
          .foregroundStyle(.white)
          .lineLimit(3)
      }
      .padding(.horizontal, 22)
      .padding(.vertical, 11)
      .frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityIdentifier("completion-notch-open-error")
    } else if let alert = animationState.alert {
      HStack(alignment: .top, spacing: 12) {
        Image(systemName: alert.situation.systemImage)
          .font(.title3.weight(.semibold))
          .foregroundStyle(.green)
          .symbolRenderingMode(.hierarchical)
          .padding(.top, 2)

        VStack(alignment: .leading, spacing: 3) {
          Text(animationState.headline)
            .font(.headline)
            .foregroundStyle(.white)
            .lineLimit(1)

          Text(alert.conversationTitle ?? L10n.text("Agent 对话"))
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.white.opacity(0.92))
            .lineLimit(1)
            .privacySensitive()
            .accessibilityIdentifier("completion-notch-conversation-title")

          Label(alert.projectDisplayName, systemImage: "folder")
            .font(.caption)
            .foregroundStyle(.white.opacity(0.68))
            .lineLimit(1)
            .privacySensitive()
            .accessibilityIdentifier("completion-notch-project")
        }
      }
      .padding(.horizontal, 22)
      .padding(.vertical, 11)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

private struct NotchUnreadStatusIcon: View {
  var body: some View {
    ZStack {
      Image(StatusItemIconRenderer.outlineAssetName)
        .resizable()
        .renderingMode(.template)
        .foregroundStyle(.white)
      Image(StatusItemIconRenderer.checkAssetName)
        .resizable()
        .renderingMode(.template)
        .foregroundStyle(.green)
    }
    .frame(width: 18, height: 18)
    .accessibilityHidden(true)
  }
}

@MainActor
final class NotchWindowCoordinator {
  static let fadeInDuration: TimeInterval = 0.07
  static let collapseDuration: TimeInterval = 0.18
  static let displayDuration: Duration = .seconds(6)

  private let localization: ApplicationLocalization
  private let expandedDuration: Duration
  private let compactDuration: Duration
  private let screensProvider: @MainActor () -> [NSScreen]
  private let focusedScreenProvider: @MainActor () -> NSScreen?
  private var panels: [NSPanel] = []
  private var animationStates: [NotchAlertAnimationState] = []
  private var interactionPanels: [NSPanel] = []
  private var interactionViews: [NotchInteractionView] = []
  private var fadingPanelGroups: [UUID: [NSPanel]] = [:]
  private var fadeOutTasks: [UUID: Task<Void, Never>] = [:]
  private var expansionTask: Task<Void, Never>?
  private var autoCollapseTask: Task<Void, Never>?
  private var postCollapseTask: Task<Void, Never>?
  private var presentationGeneration: UUID?
  private var presentedSessionID: String?
  private var currentUnreadCount = 0
  private var currentDisplayStrategy: AlertDisplayStrategy?
  private var retainsUnreadIndicator = false
  private var onOpenCodex: @MainActor (String?, Bool) -> Void = { _, _ in }
  private var canOpenCodex: @MainActor (String?) -> Bool = { _ in true }

  var isPresenting: Bool { !panels.isEmpty }
  var presentedPanelCount: Int { panels.count }
  var retainedUnreadCount: Int { currentUnreadCount }

  static func dismissalFadeDelay(hasExpandedState: Bool) -> TimeInterval {
    hasExpandedState ? NotchAlertMotion.springDuration : 0
  }

  init(
    localization: ApplicationLocalization = .shared,
    screensProvider: @escaping @MainActor () -> [NSScreen] = { NSScreen.screens },
    focusedScreenProvider: @escaping @MainActor () -> NSScreen? = { NSScreen.main },
    expandedDuration: Duration = NotchWindowCoordinator.displayDuration,
    compactDuration: Duration = .seconds(2)
  ) {
    self.expandedDuration = expandedDuration
    self.compactDuration = compactDuration
    self.localization = localization
    self.screensProvider = screensProvider
    self.focusedScreenProvider = focusedScreenProvider
  }

  func setOpenCodexAction(
    _ action: @escaping @MainActor (String?, Bool) -> Void
  ) {
    onOpenCodex = action
  }

  func setOpenCodexAvailability(
    _ availability: @escaping @MainActor (String?) -> Bool
  ) {
    canOpenCodex = availability
  }

  func requestOpenCodex(sessionID: String?, hasUnreadRecords: Bool = true) {
    onOpenCodex(sessionID, hasUnreadRecords)
  }

  func show(
    _ alert: AlertPresentation,
    headline: String,
    displayStrategy: AlertDisplayStrategy,
    unreadCount: Int? = nil,
    retainsUnreadIndicator: Bool = true
  ) {
    self.retainsUnreadIndicator = retainsUnreadIndicator
    if let unreadCount {
      currentUnreadCount = retainsUnreadIndicator ? max(0, unreadCount) : 0
    }
    removeCurrentPanelsImmediately()
    let screens = AlertScreenSelection.screens(
      for: displayStrategy,
      screens: screensProvider(),
      focusedScreen: focusedScreenProvider()
    )
    guard !screens.isEmpty else { return }

    let generation = UUID()
    presentationGeneration = generation
    presentedSessionID = alert.sessionID
    currentDisplayStrategy = displayStrategy
    let displayedUnreadCount = max(1, retainedUnreadCount)
    for screen in screens {
      let layout = NotchAlertLayout(screen: screen)
      let animationState = NotchAlertAnimationState(
        alert: alert,
        headline: headline,
        layout: layout,
        unreadCount: displayedUnreadCount
      )
      let panel = Self.makePanel(frame: layout.panelFrame, screen: screen)
      panel.contentView = NSHostingView(
        rootView: NotchAlertView(animationState: animationState)
          .applicationLocalized(using: localization)
      )
      let interactionView = NotchInteractionView(
        sessionID: alert.sessionID,
        opensCodex: canOpenCodex(alert.sessionID),
        hasUnreadRecords: unreadCount != nil,
        onHoverChanged: { [weak animationState] isHovered in
          animationState?.isHovered = isHovered
        }
      ) {
        [weak self] sessionID, hasUnreadRecords in
        self?.requestOpenCodex(
          sessionID: sessionID,
          hasUnreadRecords: hasUnreadRecords
        )
      }
      let interactionPanel = Self.makeInteractionPanel(
        frame: layout.interactionFrame(isExpanded: false),
        screen: screen
      )
      interactionPanel.ignoresMouseEvents = !interactionView.isInteractionEnabled
      interactionPanel.contentView = interactionView
      panel.alphaValue = 0
      panel.orderFrontRegardless()
      interactionPanel.orderFrontRegardless()
      panels.append(panel)
      animationStates.append(animationState)
      interactionPanels.append(interactionPanel)
      interactionViews.append(interactionView)
    }

    NSAnimationContext.runAnimationGroup { context in
      context.duration = Self.fadeInDuration
      for panel in panels {
        panel.animator().alphaValue = 1
      }
    }
    expansionTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .milliseconds(10))
      guard self?.presentationGeneration == generation else { return }
      for state in self?.animationStates ?? [] {
        state.isExpanded = true
      }
      self?.updateInteractionSurfaces(
        isExpanded: true,
        sessionID: alert.sessionID,
        hasUnreadRecords: unreadCount != nil
      )
    }
    scheduleCollapse(generation: generation)
  }

  private func scheduleCollapse(generation: UUID) {
    let expandedDuration = self.expandedDuration
    autoCollapseTask = Task { @MainActor [weak self] in
      do {
        try await Task.sleep(for: expandedDuration)
      } catch {
        return
      }
      guard self?.presentationGeneration == generation else { return }
      self?.collapseAfterDisplay(generation: generation)
    }
  }

  func showOpenFailure(sessionID: String?, message: String) {
    guard let generation = presentationGeneration,
      presentedSessionID == nil || presentedSessionID == sessionID else { return }
    expansionTask?.cancel()
    autoCollapseTask?.cancel()
    postCollapseTask?.cancel()
    for state in animationStates {
      state.openFailureMessage = message
      state.isExpanded = true
    }
    updateInteractionSurfaces(isExpanded: true, sessionID: sessionID,
      hasUnreadRecords: retainedUnreadCount > 0)
    scheduleCollapse(generation: generation)
  }

  func dismiss(
    sessionID: String,
    remainingUnreadCount: Int,
    retainsUnreadIndicator: Bool
  ) {
    self.retainsUnreadIndicator = retainsUnreadIndicator
    currentUnreadCount = retainsUnreadIndicator ? max(0, remainingUnreadCount) : 0
    guard retainedUnreadCount > 0 else {
      dismissAll()
      return
    }
    for state in animationStates {
      state.unreadCount = retainedUnreadCount
    }
    if presentedSessionID == sessionID {
      presentedSessionID = nil
      expansionTask?.cancel()
      if let generation = presentationGeneration {
        scheduleCompactDismissal(generation: generation)
      }
      autoCollapseTask?.cancel()
      autoCollapseTask = nil
      for state in animationStates {
        state.isExpanded = false
      }
      updateInteractionSurfaces(
        isExpanded: false,
        sessionID: nil,
        hasUnreadRecords: retainedUnreadCount > 0
      )
    }
  }

  func synchronizeUnreadIndicator(
    unreadCount: Int,
    isEnabled: Bool,
    displayStrategy: AlertDisplayStrategy
  ) {
    let previousUnreadCount = currentUnreadCount
    retainsUnreadIndicator = isEnabled
    currentUnreadCount = isEnabled ? max(0, unreadCount) : 0
    for state in animationStates where retainedUnreadCount > 0 {
      state.unreadCount = retainedUnreadCount
    }

    guard retainedUnreadCount > 0 else {
      guard presentedSessionID == nil else { return }
      dismissAll()
      return
    }

    if !panels.isEmpty {
      guard presentedSessionID == nil else { return }
      if currentDisplayStrategy == displayStrategy {
        updateInteractionSurfaces(
          isExpanded: false,
          sessionID: nil,
          hasUnreadRecords: true
        )
        return
      }
    }
    guard !panels.isEmpty || retainedUnreadCount > previousUnreadCount else { return }
    presentCompactIndicator(displayStrategy: displayStrategy)
  }

  func dismissAll() {
    currentUnreadCount = 0
    expansionTask?.cancel()
    expansionTask = nil
    autoCollapseTask?.cancel()
    autoCollapseTask = nil
    postCollapseTask?.cancel()
    postCollapseTask = nil
    let panelsToDismiss = panels
    let statesToCollapse = animationStates
    let hasExpandedState = statesToCollapse.contains { $0.isExpanded }
    removeInteractionPanelsImmediately()
    panels.removeAll()
    animationStates.removeAll()
    presentationGeneration = nil
    presentedSessionID = nil
    currentDisplayStrategy = nil
    guard !panelsToDismiss.isEmpty else { return }

    for state in statesToCollapse {
      state.isExpanded = false
    }
    fadeOut(
      panelsToDismiss,
      after: Self.dismissalFadeDelay(hasExpandedState: hasExpandedState)
    )
  }

  static func makePanel(frame: NSRect, screen: NSScreen?) -> NSPanel {
    let panel = NSPanel(
      contentRect: frame,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false,
      screen: screen
    )
    panel.level = .statusBar
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.hasShadow = false
    panel.ignoresMouseEvents = true
    panel.hidesOnDeactivate = false
    panel.animationBehavior = .none
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    return panel
  }

  static func makeInteractionPanel(frame: NSRect, screen: NSScreen?) -> NSPanel {
    let panel = NSPanel(
      contentRect: frame,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false,
      screen: screen
    )
    panel.level = .statusBar
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.hasShadow = false
    panel.ignoresMouseEvents = false
    panel.hidesOnDeactivate = false
    panel.becomesKeyOnlyIfNeeded = true
    panel.animationBehavior = .none
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    return panel
  }

  private func collapseAfterDisplay(generation: UUID) {
    for state in animationStates {
      state.unreadCount = max(1, retainedUnreadCount)
      state.isExpanded = false
    }
    updateInteractionSurfaces(
      isExpanded: false,
      sessionID: presentedSessionID,
      hasUnreadRecords: retainedUnreadCount > 0
    )
    scheduleCompactDismissal(generation: generation)
  }

  private func scheduleCompactDismissal(generation: UUID) {
    let delay = compactDuration + .seconds(NotchAlertMotion.springDuration)
    postCollapseTask?.cancel()
    postCollapseTask = Task { @MainActor [weak self] in
      do {
        try await Task.sleep(for: delay)
      } catch {
        return
      }
      guard self?.presentationGeneration == generation else { return }
      self?.fadeOutCurrentPanels()
    }
  }

  private func fadeOutCurrentPanels() {
    let panelsToDismiss = panels
    removeInteractionPanelsImmediately()
    panels.removeAll()
    animationStates.removeAll()
    presentationGeneration = nil
    presentedSessionID = nil
    currentDisplayStrategy = nil
    guard !panelsToDismiss.isEmpty else { return }
    fadeOut(panelsToDismiss)
  }

  private func fadeOut(
    _ panelsToDismiss: [NSPanel],
    after delay: TimeInterval = 0
  ) {
    let fadeID = UUID()
    fadingPanelGroups[fadeID] = panelsToDismiss
    fadeOutTasks[fadeID] = Task { @MainActor [weak self] in
      if delay > 0 {
        do {
          try await Task.sleep(for: .seconds(delay))
        } catch {
          return
        }
      }

      guard let panels = self?.fadingPanelGroups[fadeID] else { return }
      NSAnimationContext.runAnimationGroup(
        { context in
          context.duration = Self.collapseDuration
          for panel in panels {
            panel.animator().alphaValue = 0
          }
        },
        completionHandler: nil
      )

      do {
        try await Task.sleep(for: .seconds(Self.collapseDuration))
      } catch {
        return
      }
      self?.finishFadeOut(fadeID: fadeID)
    }
  }

  private func finishFadeOut(fadeID: UUID) {
    fadeOutTasks.removeValue(forKey: fadeID)
    for panel in fadingPanelGroups.removeValue(forKey: fadeID) ?? [] {
      panel.orderOut(nil)
    }
  }

  private func removeCurrentPanelsImmediately() {
    expansionTask?.cancel()
    expansionTask = nil
    autoCollapseTask?.cancel()
    autoCollapseTask = nil
    postCollapseTask?.cancel()
    postCollapseTask = nil
    for task in fadeOutTasks.values {
      task.cancel()
    }
    fadeOutTasks.removeAll()
    for panel in panels {
      panel.orderOut(nil)
    }
    removeInteractionPanelsImmediately()
    for group in fadingPanelGroups.values {
      for panel in group {
        panel.orderOut(nil)
      }
    }
    panels.removeAll()
    animationStates.removeAll()
    fadingPanelGroups.removeAll()
    presentationGeneration = nil
    presentedSessionID = nil
    currentDisplayStrategy = nil
  }

  private func removeInteractionPanelsImmediately() {
    for interactionView in interactionViews {
      interactionView.cancelPointerInteraction()
    }
    for panel in interactionPanels {
      panel.orderOut(nil)
    }
    interactionPanels.removeAll()
    interactionViews.removeAll()
  }

  private func updateInteractionSurfaces(
    isExpanded: Bool,
    sessionID: String?,
    hasUnreadRecords: Bool
  ) {
    for index in interactionPanels.indices {
      guard animationStates.indices.contains(index) else { continue }
      interactionViews[index].sessionID = sessionID
      interactionViews[index].opensCodex = canOpenCodex(sessionID)
      interactionViews[index].hasUnreadRecords = hasUnreadRecords
      interactionPanels[index].ignoresMouseEvents =
        !interactionViews[index].isInteractionEnabled
      interactionPanels[index].setFrame(
        animationStates[index].layout.interactionFrame(isExpanded: isExpanded),
        display: false
      )
    }
  }

  private func presentCompactIndicator(displayStrategy: AlertDisplayStrategy) {
    removeCurrentPanelsImmediately()
    let screens = AlertScreenSelection.screens(
      for: displayStrategy,
      screens: screensProvider(),
      focusedScreen: focusedScreenProvider()
    )
    guard !screens.isEmpty else { return }

    let generation = UUID()
    presentationGeneration = generation
    scheduleCompactDismissal(generation: generation)
    currentDisplayStrategy = displayStrategy
    for screen in screens {
      let layout = NotchAlertLayout(screen: screen)
      let animationState = NotchAlertAnimationState(
        layout: layout,
        unreadCount: retainedUnreadCount
      )
      let panel = Self.makePanel(frame: layout.panelFrame, screen: screen)
      panel.contentView = NSHostingView(
        rootView: NotchAlertView(animationState: animationState)
          .applicationLocalized(using: localization)
      )
      let interactionView = NotchInteractionView(
        sessionID: nil,
        opensCodex: canOpenCodex(nil),
        hasUnreadRecords: true,
        onHoverChanged: { [weak animationState] isHovered in
          animationState?.isHovered = isHovered
        }
      ) {
        [weak self] sessionID, hasUnreadRecords in
        self?.requestOpenCodex(
          sessionID: sessionID,
          hasUnreadRecords: hasUnreadRecords
        )
      }
      let interactionPanel = Self.makeInteractionPanel(
        frame: layout.interactionFrame(isExpanded: false),
        screen: screen
      )
      interactionPanel.ignoresMouseEvents = !interactionView.isInteractionEnabled
      interactionPanel.contentView = interactionView
      panel.alphaValue = 0
      panel.orderFrontRegardless()
      interactionPanel.orderFrontRegardless()
      panels.append(panel)
      animationStates.append(animationState)
      interactionPanels.append(interactionPanel)
      interactionViews.append(interactionView)
    }

    NSAnimationContext.runAnimationGroup { context in
      context.duration = Self.fadeInDuration
      for panel in panels {
        panel.animator().alphaValue = 1
      }
    }
  }
}
