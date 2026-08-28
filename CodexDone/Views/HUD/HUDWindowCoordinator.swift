import AppKit
import SwiftUI

@MainActor
final class HUDWindowCoordinator {
  private let localization: ApplicationLocalization
  private let screensProvider: @MainActor () -> [NSScreen]
  private let focusedScreenProvider: @MainActor () -> NSScreen?
  private var panels: [NSPanel] = []
  private var presentedSessionID: String?
  private var dismissalTask: Task<Void, Never>?

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
      panel.ignoresMouseEvents = true
      panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
      panel.contentView = NSHostingView(
        rootView: CompletionHUDView(alert: alert, headline: headline)
          .applicationLocalized(using: localization)
      )
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
