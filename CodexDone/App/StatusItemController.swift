import AppKit
import Observation
import SwiftUI

enum StatusItemPopoverLayout {
  static let size = NSSize(width: 410, height: 374)
  static let statusItemLength = NSStatusItem.variableLength

  static func statusItemTitle(unreadCount: Int, showsUnreadCount: Bool) -> String {
    guard showsUnreadCount, unreadCount > 0 else { return "" }
    return " \(unreadCount)"
  }

  static func displayedStatusItemTitle(current: String, expandedTitle: String?) -> String {
    expandedTitle ?? current
  }

  static func displayedHasUnread(current: Bool) -> Bool {
    current
  }
}

enum StatusItemCenterSymbol: Equatable, Sendable {
  case checkmark
  case away

  static func resolved(
    configuredMode: AlertVisualMode,
    smartConfiguration: SmartAlertConfiguration,
    idleSeconds: TimeInterval
  ) -> Self {
    guard configuredMode == .smart else { return .checkmark }
    return smartConfiguration.activityState(idleSeconds: idleSeconds) == .away
      ? .away
      : .checkmark
  }
}

enum StatusItemIconRenderer {
  static let size = NSSize(width: 18, height: 18)
  static let outlineAssetName = NSImage.Name("StatusItemOutline")
  static let checkAssetName = NSImage.Name("StatusItemCheck")
  static let awaySystemSymbolName = "figure.walk"
  static let awaySymbolMaximumSize = NSSize(width: 7, height: 9.5)
  static let awaySymbolOpticalOffset = NSPoint(x: 0.25, y: 0)
  static let checkmarkOpticalOffset = NSPoint(x: -0.5, y: 0)

  static func image(
    hasUnread: Bool,
    centerSymbol: StatusItemCenterSymbol = .checkmark,
    isHighlighted: Bool,
    accessibilityDescription: String
  ) -> NSImage {
    guard
      let outline = NSImage(named: outlineAssetName),
      let check = NSImage(named: checkAssetName)
    else {
      assertionFailure("Status item vector assets are missing")
      let fallback = NSImage(
        systemSymbolName: "checkmark.circle",
        accessibilityDescription: accessibilityDescription
      ) ?? NSImage(size: size)
      fallback.isTemplate = true
      return fallback
    }

    let result = NSImage(size: size, flipped: false) { rect in
      let foreground = isHighlighted
        ? NSColor.selectedMenuItemTextColor
        : NSColor.controlTextColor
      tintedLayer(source: outline, color: foreground).draw(in: rect)
      let centerColor = hasUnread ? NSColor.systemGreen : foreground
      let center = centerImage(centerSymbol, fallback: check)
      tintedLayer(
        source: center,
        color: centerColor,
        destinationRect: centerDestinationRect(
          centerSymbol,
          sourceSize: center.size,
          canvas: rect
        )
      ).draw(in: rect)
      return true
    }
    result.cacheMode = .never
    result.isTemplate = false
    result.accessibilityDescription = accessibilityDescription
    return result
  }

  private static func centerImage(
    _ symbol: StatusItemCenterSymbol,
    fallback: NSImage
  ) -> NSImage {
    guard symbol == .away else { return fallback }
    let configuration = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
    return NSImage(
      systemSymbolName: awaySystemSymbolName,
      accessibilityDescription: nil
    )?.withSymbolConfiguration(configuration) ?? fallback
  }

  static func centerDestinationRect(
    _ symbol: StatusItemCenterSymbol,
    sourceSize: NSSize,
    canvas: NSRect
  ) -> NSRect {
    guard symbol == .away else {
      return canvas.offsetBy(
        dx: checkmarkOpticalOffset.x,
        dy: checkmarkOpticalOffset.y
      )
    }
    let bounds = NSRect(
      x: canvas.midX - awaySymbolMaximumSize.width / 2 + awaySymbolOpticalOffset.x,
      y: canvas.midY - awaySymbolMaximumSize.height / 2 + awaySymbolOpticalOffset.y,
      width: awaySymbolMaximumSize.width,
      height: awaySymbolMaximumSize.height
    )
    guard sourceSize.width > 0, sourceSize.height > 0 else { return bounds }
    let scale = min(bounds.width / sourceSize.width, bounds.height / sourceSize.height)
    let fittedSize = NSSize(
      width: sourceSize.width * scale,
      height: sourceSize.height * scale
    )
    return NSRect(
      x: bounds.midX - fittedSize.width / 2,
      y: bounds.midY - fittedSize.height / 2,
      width: fittedSize.width,
      height: fittedSize.height
    )
  }

  private static func tintedLayer(
    source: NSImage,
    color: NSColor,
    destinationRect: NSRect? = nil
  ) -> NSImage {
    let layer = NSImage(size: size, flipped: false) { rect in
      let target = destinationRect ?? rect
      color.setFill()
      NSBezierPath(rect: target).fill()
      source.draw(
        in: target,
        from: NSRect(origin: .zero, size: source.size),
        operation: .destinationIn,
        fraction: 1
      )
      return true
    }
    layer.cacheMode = .never
    layer.isTemplate = false
    return layer
  }
}

private struct StatusItemPopoverRootView: View {
  let environment: AppEnvironment
  let openCodex: () -> Void

  var body: some View {
    MenuBarContentView(openCodex: openCodex)
      .environment(environment)
      .applicationLocalized(using: environment.localization)
  }
}

@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
  private let environment: AppEnvironment
  private let statusItem: NSStatusItem
  private let popover = NSPopover()
  private let defaults: UserDefaults
  private let idleTimeProvider: () -> TimeInterval
  private var expandedStatusItemTitle: String?
  private var smartActivityRefreshTask: Task<Void, Never>?
  private var renderedIconState: RenderedIconState?

  init(
    environment: AppEnvironment,
    defaults: UserDefaults = .standard,
    idleTimeProvider: @escaping () -> TimeInterval = {
      SystemUserIdleTimeProvider.secondsSinceLastInput()
    }
  ) {
    self.environment = environment
    self.defaults = defaults
    self.idleTimeProvider = idleTimeProvider
    statusItem = NSStatusBar.system.statusItem(
      withLength: StatusItemPopoverLayout.statusItemLength
    )
    super.init()
    configureStatusItem()
    configurePopover()
    observePresentation()
    startSmartActivityMonitoring()
  }

  private struct RenderedIconState: Equatable {
    let hasUnread: Bool
    let centerSymbol: StatusItemCenterSymbol
    let isHighlighted: Bool
  }

  private func configureStatusItem() {
    statusItem.isVisible = true
    guard let button = statusItem.button else { return }
    button.target = self
    button.action = #selector(togglePopover(_:))
    button.sendAction(on: [.leftMouseUp])
    button.imagePosition = .imageLeading
    button.imageScaling = .scaleProportionallyDown
    button.setAccessibilityIdentifier("menu-bar-status-item")
    refreshPresentation()
  }

  private func configurePopover() {
    popover.behavior = .transient
    popover.animates = true
    popover.contentViewController = NSHostingController(
      rootView: StatusItemPopoverRootView(
        environment: environment,
        openCodex: { [weak self] in
          self?.openCodexFromPopover()
        }
      )
    )
    refreshPopoverSize()
    applyPopoverAppearance()
    popover.delegate = self
  }

  private func applyPopoverAppearance() {
    switch UserDefaults.standard.string(forKey: "appearance.colorScheme") {
    case "light":
      popover.appearance = NSAppearance(named: .vibrantLight)
    case "dark":
      popover.appearance = NSAppearance(named: .vibrantDark)
    default:
      popover.appearance = nil
    }
  }

  private func observePresentation() {
    withObservationTracking {
      _ = environment.menuBarTitle
      _ = environment.completionStore.unreadCount
      _ = environment.statusItemShowsUnreadCount
      _ = environment.hookInspection.helperIsExecutable
      _ = environment.hookInspection.isInstalled
      _ = environment.isSocketListening
      _ = environment.localization.preference
    } onChange: { [weak self] in
      Task { @MainActor [weak self] in
        self?.refreshPresentation()
        self?.observePresentation()
      }
    }
  }

  private func refreshPresentation() {
    guard let button = statusItem.button else { return }
    let hasUnread = StatusItemPopoverLayout.displayedHasUnread(
      current: environment.completionStore.unreadCount > 0
    )
    let iconState = RenderedIconState(
      hasUnread: hasUnread,
      centerSymbol: currentCenterSymbol(),
      isHighlighted: button.state == .on
    )
    if renderedIconState != iconState {
      button.image = StatusItemIconRenderer.image(
        hasUnread: iconState.hasUnread,
        centerSymbol: iconState.centerSymbol,
        isHighlighted: iconState.isHighlighted,
        accessibilityDescription: environment.menuBarTitle
      )
      renderedIconState = iconState
    }
    button.title = StatusItemPopoverLayout.displayedStatusItemTitle(
      current: StatusItemPopoverLayout.statusItemTitle(
        unreadCount: environment.completionStore.unreadCount,
        showsUnreadCount: environment.statusItemShowsUnreadCount
      ),
      expandedTitle: expandedStatusItemTitle
    )
    button.toolTip = environment.menuBarTitle
    button.setAccessibilityLabel(environment.menuBarTitle)
  }

  private func currentCenterSymbol() -> StatusItemCenterSymbol {
    let configuredMode = AlertVisualMode(
      storedValue: defaults.string(forKey: "alerts.visualMode")
    )
    guard configuredMode == .smart else { return .checkmark }
    return StatusItemCenterSymbol.resolved(
      configuredMode: configuredMode,
      smartConfiguration: SmartAlertConfiguration(defaults: defaults),
      idleSeconds: idleTimeProvider()
    )
  }

  private func startSmartActivityMonitoring() {
    smartActivityRefreshTask?.cancel()
    smartActivityRefreshTask = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        do {
          try await Task.sleep(for: .seconds(1))
        } catch {
          return
        }
        guard let self else { return }
        guard self.renderedIconState?.centerSymbol != self.currentCenterSymbol() else {
          continue
        }
        self.refreshPresentation()
      }
    }
  }

  private func refreshPopoverSize() {
    popover.contentSize = StatusItemPopoverLayout.size
  }

  @objc private func togglePopover(_ sender: NSStatusBarButton) {
    popover.isShown ? popover.performClose(sender) : showPopover()
  }

  private func openCodexFromPopover() {
    popover.performClose(nil)
    environment.openCodex()
  }

  func showPopover() {
    statusItem.isVisible = true
    guard let button = statusItem.button else { return }
    guard !popover.isShown else { return }
    Task { @MainActor [weak self] in
      await self?.environment.refreshHealth()
    }
    expandedStatusItemTitle = button.title
    refreshPresentation()
    button.window?.contentView?.layoutSubtreeIfNeeded()
    refreshPopoverSize()
    applyPopoverAppearance()
    popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    button.state = .on
    refreshPresentation()
  }

  func popoverDidClose(_ notification: Notification) {
    statusItem.button?.state = .off
    expandedStatusItemTitle = nil
    refreshPresentation()
  }
}
