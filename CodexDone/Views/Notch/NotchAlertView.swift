import AppKit
import Observation
import SwiftUI

enum NotchAlertMotion {
  static let springDuration: TimeInterval = 0.34
  static let springBounce = 0.52

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
    auxiliaryTopRightArea: NSRect?
  ) -> Self {
    let isAttached = safeAreaTop > 0
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
    let topEdge = isAttached ? screenFrame.maxY : visibleFrame.maxY
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
    self = Self.make(
      screenFrame: screen.frame,
      visibleFrame: screen.visibleFrame,
      safeAreaTop: screen.safeAreaInsets.top,
      auxiliaryTopLeftArea: screen.auxiliaryTopLeftArea,
      auxiliaryTopRightArea: screen.auxiliaryTopRightArea
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
    .animation(NotchAlertMotion.spring, value: isExpanded)
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
    if let alert = animationState.alert {
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

          Text(alert.conversationTitle ?? L10n.text("Codex 对话"))
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
  private let screensProvider: @MainActor () -> [NSScreen]
  private let focusedScreenProvider: @MainActor () -> NSScreen?
  private var panels: [NSPanel] = []
  private var animationStates: [NotchAlertAnimationState] = []
  private var fadingPanelGroups: [UUID: [NSPanel]] = [:]
  private var fadeOutTasks: [UUID: Task<Void, Never>] = [:]
  private var expansionTask: Task<Void, Never>?
  private var autoCollapseTask: Task<Void, Never>?
  private var postCollapseTask: Task<Void, Never>?
  private var presentationGeneration: UUID?
  private var expandedSessionID: String?
  private var currentUnreadCount = 0
  private var currentDisplayStrategy: AlertDisplayStrategy?
  private var retainsUnreadIndicator = false

  var isPresenting: Bool { !panels.isEmpty }
  var presentedPanelCount: Int { panels.count }
  var retainedUnreadCount: Int { currentUnreadCount }

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
    expandedSessionID = alert.sessionID
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
      panel.alphaValue = 0
      panel.orderFrontRegardless()
      panels.append(panel)
      animationStates.append(animationState)
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
    }
    autoCollapseTask = Task { @MainActor [weak self] in
      do {
        try await Task.sleep(for: Self.displayDuration)
      } catch {
        return
      }
      guard self?.presentationGeneration == generation else { return }
      self?.collapseAfterDisplay(generation: generation)
    }
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
    if expandedSessionID == sessionID {
      expandedSessionID = nil
      autoCollapseTask?.cancel()
      autoCollapseTask = nil
      for state in animationStates {
        state.isExpanded = false
      }
    }
  }

  func synchronizeUnreadIndicator(
    unreadCount: Int,
    isEnabled: Bool,
    displayStrategy: AlertDisplayStrategy
  ) {
    retainsUnreadIndicator = isEnabled
    currentUnreadCount = isEnabled ? max(0, unreadCount) : 0
    for state in animationStates where retainedUnreadCount > 0 {
      state.unreadCount = retainedUnreadCount
    }

    guard retainedUnreadCount > 0 else {
      guard expandedSessionID == nil else { return }
      dismissAll()
      return
    }

    if !panels.isEmpty {
      guard expandedSessionID == nil, currentDisplayStrategy != displayStrategy else { return }
    }
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
    panels.removeAll()
    animationStates.removeAll()
    presentationGeneration = nil
    expandedSessionID = nil
    currentDisplayStrategy = nil
    guard !panelsToDismiss.isEmpty else { return }

    for state in statesToCollapse {
      state.isExpanded = false
    }
    fadeOut(panelsToDismiss)
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

  private func collapseAfterDisplay(generation: UUID) {
    expandedSessionID = nil
    for state in animationStates {
      state.unreadCount = max(1, retainedUnreadCount)
      state.isExpanded = false
    }
    guard !retainsUnreadIndicator || retainedUnreadCount == 0 else { return }

    postCollapseTask?.cancel()
    postCollapseTask = Task { @MainActor [weak self] in
      do {
        try await Task.sleep(for: .seconds(NotchAlertMotion.springDuration))
      } catch {
        return
      }
      guard self?.presentationGeneration == generation else { return }
      self?.fadeOutCurrentPanels()
    }
  }

  private func fadeOutCurrentPanels() {
    let panelsToDismiss = panels
    panels.removeAll()
    animationStates.removeAll()
    presentationGeneration = nil
    expandedSessionID = nil
    currentDisplayStrategy = nil
    guard !panelsToDismiss.isEmpty else { return }
    fadeOut(panelsToDismiss)
  }

  private func fadeOut(_ panelsToDismiss: [NSPanel]) {
    let fadeID = UUID()
    fadingPanelGroups[fadeID] = panelsToDismiss
    NSAnimationContext.runAnimationGroup { context in
      context.duration = Self.collapseDuration
      for panel in panelsToDismiss {
        panel.animator().alphaValue = 0
      }
    }
    fadeOutTasks[fadeID] = Task { @MainActor [weak self] in
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
    for group in fadingPanelGroups.values {
      for panel in group {
        panel.orderOut(nil)
      }
    }
    panels.removeAll()
    animationStates.removeAll()
    fadingPanelGroups.removeAll()
    presentationGeneration = nil
    expandedSessionID = nil
    currentDisplayStrategy = nil
  }

  private func presentCompactIndicator(displayStrategy: AlertDisplayStrategy) {
    removeCurrentPanelsImmediately()
    let screens = AlertScreenSelection.screens(
      for: displayStrategy,
      screens: screensProvider(),
      focusedScreen: focusedScreenProvider()
    )
    guard !screens.isEmpty else { return }

    presentationGeneration = UUID()
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
      panel.alphaValue = 0
      panel.orderFrontRegardless()
      panels.append(panel)
      animationStates.append(animationState)
    }

    NSAnimationContext.runAnimationGroup { context in
      context.duration = Self.fadeInDuration
      for panel in panels {
        panel.animator().alphaValue = 1
      }
    }
  }
}
