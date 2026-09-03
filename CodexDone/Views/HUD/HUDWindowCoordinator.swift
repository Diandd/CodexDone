import AppKit
import SwiftUI

@MainActor
final class HUDInteractionView: NSView {
  let sessionID: String
  var isOpenEnabled: Bool {
    didSet { updateAccessibility() }
  }
  private let onOpenCodex: @MainActor (String) -> Void

  init(
    frame: NSRect = .zero,
    sessionID: String,
    isOpenEnabled: Bool = true,
    onOpenCodex: @escaping @MainActor (String) -> Void
  ) {
    self.sessionID = sessionID
    self.isOpenEnabled = isOpenEnabled
    self.onOpenCodex = onOpenCodex
    super.init(frame: frame)
    updateAccessibility()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
    isOpenEnabled
  }

  override func mouseDown(with event: NSEvent) {}

  override func mouseUp(with event: NSEvent) {
    guard isOpenEnabled else { return }
    let location = convert(event.locationInWindow, from: nil)
    guard bounds.contains(location) else { return }
    onOpenCodex(sessionID)
  }

  override func accessibilityPerformPress() -> Bool {
    guard isOpenEnabled else { return false }
    onOpenCodex(sessionID)
    return true
  }

  private func updateAccessibility() {
    setAccessibilityElement(isOpenEnabled)
    setAccessibilityRole(.button)
    setAccessibilityIdentifier("completion-hud-open-codex")
    setAccessibilityLabel(L10n.text("打开 Codex"))
  }
}

@MainActor
final class HUDWindowCoordinator {
  private let localization: ApplicationLocalization
  private let screensProvider: @MainActor () -> [NSScreen]
  private let focusedScreenProvider: @MainActor () -> NSScreen?
  private var panels: [NSPanel] = []
  private var presentedSessionID: String?
  private var dismissalTask: Task<Void, Never>?
  private var onOpenCodex: @MainActor (String) -> Void = { _ in }
  private var canOpenCodex: @MainActor (String) -> Bool = { _ in true }

  init(
    localization: ApplicationLocalization = .shared,
    screensProvider: @escaping @MainActor () -> [NSScreen] = { NSScreen.screens },
    focusedScreenProvider: @escaping @MainActor () -> NSScreen? = { NSScreen.main }
  ) {
    self.localization = localization
    self.screensProvider = screensProvider
    self.focusedScreenProvider = focusedScreenProvider
  }

  func setOpenCodexAction(
    _ action: @escaping @MainActor (String) -> Void
  ) {
    onOpenCodex = action
  }

  func setOpenCodexAvailability(
    _ availability: @escaping @MainActor (String) -> Bool
  ) {
    canOpenCodex = availability
  }

  func requestOpenCodex(sessionID: String) {
    onOpenCodex(sessionID)
    dismiss(sessionID: sessionID)
  }

  func show(
    _ alert: AlertPresentation,
    headline: String,
    displayStrategy: AlertDisplayStrategy = .defaultStrategy
  ) {
    dismissAll()
    let screens = AlertScreenSelection.screens(
      for: displayStrategy,
      screens: screensProvider(),
      focusedScreen: focusedScreenProvider()
    )
    guard !screens.isEmpty else { return }
    let size = CompletionHUDView.preferredSize
    for screen in screens {
      let frame = NSRect(
        x: screen.visibleFrame.midX - size.width / 2,
        y: screen.visibleFrame.maxY - size.height - 24,
        width: size.width,
        height: size.height
      )
      let panel = NSPanel(
        contentRect: frame,
        styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered,
        defer: false,
        screen: screen
      )
      panel.level = .floating
      panel.backgroundColor = .clear
      panel.isOpaque = false
      panel.hasShadow = true
      let allowsOpenCodex = canOpenCodex(alert.sessionID)
      panel.ignoresMouseEvents = !allowsOpenCodex
      panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
      let containerView = NSView(
        frame: NSRect(origin: .zero, size: size)
      )
      let hostingView = NSHostingView(
        rootView: CompletionHUDView(alert: alert, headline: headline)
          .applicationLocalized(using: localization)
      )
      hostingView.frame = containerView.bounds
      hostingView.autoresizingMask = [.width, .height]
      let interactionView = HUDInteractionView(
        frame: containerView.bounds,
        sessionID: alert.sessionID,
        isOpenEnabled: allowsOpenCodex
      ) { [weak self] sessionID in
        self?.requestOpenCodex(sessionID: sessionID)
      }
      interactionView.autoresizingMask = [.width, .height]
      containerView.addSubview(hostingView)
      containerView.addSubview(interactionView)
      panel.contentView = containerView
      panel.orderFrontRegardless()
      panels.append(panel)
    }
    presentedSessionID = alert.sessionID
    dismissalTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .seconds(6))
      self?.dismiss(sessionID: alert.sessionID)
    }
  }

  func dismiss(sessionID: String) {
    guard presentedSessionID == sessionID else { return }
    dismissAll()
  }

  func dismissAll() {
    dismissalTask?.cancel()
    dismissalTask = nil
    for panel in panels {
      panel.orderOut(nil)
    }
    panels.removeAll()
    presentedSessionID = nil
  }
}
