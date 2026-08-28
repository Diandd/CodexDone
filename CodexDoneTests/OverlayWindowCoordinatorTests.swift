import AppKit
import SwiftUI
import XCTest

@testable import CodexDone

@MainActor
final class OverlayWindowCoordinatorTests: XCTestCase {
  func testPanelDirectlyReceivesMouseAndKeyboardEventsWithoutActivatingApp() {
    let panel = OverlayWindowCoordinator.makePanel(
      frame: NSRect(x: 0, y: 0, width: 320, height: 180),
      screen: nil
    )
    defer { panel.orderOut(nil) }

    XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
    XCTAssertTrue(panel.acceptsMouseMovedEvents)
    XCTAssertFalse(panel.ignoresMouseEvents)
    XCTAssertFalse(panel.hidesOnDeactivate)
    XCTAssertFalse(panel.becomesKeyOnlyIfNeeded)
    XCTAssertTrue(panel.canBecomeKey)
    XCTAssertFalse(panel.canBecomeMain)
    XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
    XCTAssertTrue(panel.collectionBehavior.contains(.fullScreenAuxiliary))
  }

  func testPanelDismissesForAnyKeyboardEvent() throws {
    let panel = OverlayWindowCoordinator.makePanel(
      frame: NSRect(x: 0, y: 0, width: 320, height: 180),
      screen: nil
    )
    defer { panel.orderOut(nil) }
    var interactionCount = 0
    panel.onKeyboardInteraction = { interactionCount += 1 }
    let keyEvent = try XCTUnwrap(
      NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: [],
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        characters: "a",
        charactersIgnoringModifiers: "a",
        isARepeat: false,
        keyCode: 0
      )
    )

    panel.keyDown(with: keyEvent)

    XCTAssertEqual(interactionCount, 1)
  }

  func testInteractionViewTracksMouseMovementEvenWhenAppIsInactive() throws {
    let view = OverlayInteractionHostingView(
      rootView: EmptyView(),
      dismissalMode: .mouseMovement
    ) {}
    view.frame = NSRect(x: 0, y: 0, width: 320, height: 180)
    view.updateTrackingAreas()

    let trackingArea = try XCTUnwrap(
      view.trackingAreas.first {
        $0.options.contains(.mouseMoved) && $0.options.contains(.activeAlways)
      }
    )

    XCTAssertTrue(trackingArea.options.contains(.inVisibleRect))
    XCTAssertTrue(view.acceptsFirstMouse(for: nil))
  }

  func testMouseMovementModeDismissesForMovementClicksAndScrolling() throws {
    var interactionCount = 0
    let view = OverlayInteractionHostingView(
      rootView: EmptyView(),
      dismissalMode: .mouseMovement
    ) {
      interactionCount += 1
    }
    let event = try XCTUnwrap(
      NSEvent.mouseEvent(
        with: .leftMouseDown,
        location: .zero,
        modifierFlags: [],
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        eventNumber: 0,
        clickCount: 1,
        pressure: 0
      )
    )

    view.mouseMoved(with: event)
    XCTAssertEqual(interactionCount, 1)
    view.mouseDown(with: event)
    XCTAssertEqual(interactionCount, 2)
    view.rightMouseDown(with: event)
    XCTAssertEqual(interactionCount, 3)
    view.otherMouseDown(with: event)
    XCTAssertEqual(interactionCount, 4)
    view.scrollWheel(with: event)
    XCTAssertEqual(interactionCount, 5)
  }

  func testClickModeIgnoresMovementButDismissesForClicksAndScrolling() throws {
    var interactionCount = 0
    let view = OverlayInteractionHostingView(
      rootView: EmptyView(),
      dismissalMode: .click
    ) {
      interactionCount += 1
    }
    view.frame = NSRect(x: 0, y: 0, width: 320, height: 180)
    view.updateTrackingAreas()
    let event = try XCTUnwrap(
      NSEvent.mouseEvent(
        with: .leftMouseDown,
        location: .zero,
        modifierFlags: [],
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        eventNumber: 0,
        clickCount: 1,
        pressure: 0
      )
    )

    XCTAssertFalse(view.trackingAreas.contains { $0.options.contains(.mouseMoved) })
    view.mouseMoved(with: event)
    XCTAssertEqual(interactionCount, 0)
    view.mouseDown(with: event)
    XCTAssertEqual(interactionCount, 1)
    view.rightMouseDown(with: event)
    XCTAssertEqual(interactionCount, 2)
    view.otherMouseDown(with: event)
    XCTAssertEqual(interactionCount, 3)
    view.scrollWheel(with: event)
    XCTAssertEqual(interactionCount, 4)
  }

  func testOverlayUsesNonzeroFadeDurationsAndSafeStoredDefaults() {
    XCTAssertGreaterThan(OverlayWindowCoordinator.fadeInDuration, 0)
    XCTAssertGreaterThan(OverlayWindowCoordinator.fadeOutDuration, 0)
    XCTAssertEqual(OverlayDismissalMode.defaultMode, .click)
    XCTAssertEqual(OverlayDismissalMode(storedValue: nil), .click)
    XCTAssertEqual(OverlayDismissalMode(storedValue: "unsupported"), .click)
    XCTAssertEqual(OverlayDismissalMode(storedValue: "click"), .click)
    XCTAssertEqual(OverlayAutoDismissDuration(storedValue: nil), .never)
    XCTAssertEqual(OverlayAutoDismissDuration(storedValue: "unsupported"), .never)
    XCTAssertNil(OverlayAutoDismissDuration.never.duration)
    XCTAssertNotNil(OverlayAutoDismissDuration.fiveSeconds.duration)
    XCTAssertEqual(AlertVisualMode.defaultMode, .smart)
    XCTAssertEqual(AlertVisualMode(storedValue: nil), .smart)
    XCTAssertEqual(AlertVisualMode(storedValue: "unsupported"), .smart)
    XCTAssertEqual(AlertVisualMode(storedValue: "none"), .none)
    XCTAssertEqual(AlertVisualMode(storedValue: "notch"), .notch)
    XCTAssertEqual(AlertVisualMode(storedValue: "fullscreen"), .fullscreen)
    XCTAssertEqual(AlertDisplayStrategy.defaultStrategy, .focused)
    XCTAssertEqual(AlertDisplayStrategy(storedValue: nil), .focused)
    XCTAssertEqual(AlertDisplayStrategy(storedValue: "unsupported"), .focused)
    XCTAssertEqual(AlertDisplayStrategy(storedValue: "all"), .all)
    XCTAssertEqual(OverlayBackgroundStyle(storedValue: nil), .gradient)
    XCTAssertEqual(OverlayBackgroundStyle(storedValue: "unsupported"), .gradient)
    XCTAssertEqual(OverlayBackgroundStyle(storedValue: "solid"), .solid)
    XCTAssertEqual(OverlayBackgroundStyle(storedValue: "blurOnly"), .blurOnly)
    XCTAssertEqual(OverlayBackgroundStyle.allCases.count, 4)
    XCTAssertEqual(
      OverlayAppearanceConfiguration.defaultConfiguration.opacity,
      CompletionOverlayView.backdropOpacity
    )
  }

  func testDisplayStrategySelectsAllPrimaryOrFocusedScreen() {
    XCTAssertEqual(
      AlertScreenSelection.selectedIndices(
        for: .all,
        screenCount: 3,
        focusedIndex: 2
      ),
      [0, 1, 2]
    )
    XCTAssertEqual(
      AlertScreenSelection.selectedIndices(
        for: .primary,
        screenCount: 3,
        focusedIndex: 2
      ),
      [0]
    )
    XCTAssertEqual(
      AlertScreenSelection.selectedIndices(
        for: .focused,
        screenCount: 3,
        focusedIndex: 2
      ),
      [2]
    )
    XCTAssertEqual(
      AlertScreenSelection.selectedIndices(
        for: .focused,
        screenCount: 3,
        focusedIndex: nil
      ),
      [0]
    )
    XCTAssertEqual(
      AlertScreenSelection.selectedIndices(
        for: .all,
        screenCount: 0,
        focusedIndex: nil
      ),
      []
    )
  }

  func testNotchLayoutAttachesToCameraHousingAndFallsBackToFloatingCapsule() {
    let screenFrame = NSRect(x: 0, y: 0, width: 1_512, height: 982)
    let visibleFrame = NSRect(x: 0, y: 0, width: 1_512, height: 944)
    let attached = NotchAlertLayout.make(
      screenFrame: screenFrame,
      visibleFrame: visibleFrame,
      safeAreaTop: 38,
      auxiliaryTopLeftArea: NSRect(x: 0, y: 944, width: 650, height: 38),
      auxiliaryTopRightArea: NSRect(x: 862, y: 944, width: 650, height: 38)
    )
    let floating = NotchAlertLayout.make(
      screenFrame: screenFrame,
      visibleFrame: visibleFrame,
      safeAreaTop: 0,
      auxiliaryTopLeftArea: nil,
      auxiliaryTopRightArea: nil
    )

    XCTAssertTrue(attached.isAttachedToCameraHousing)
    XCTAssertEqual(attached.panelFrame.maxY, screenFrame.maxY)
    XCTAssertEqual(attached.cameraHousingWidth, 212)
    XCTAssertEqual(attached.compactWingWidth, 32)
    XCTAssertEqual(attached.compactWidth, 276)
    XCTAssertEqual(attached.compactHeight, 38)
    XCTAssertGreaterThanOrEqual(
      (attached.panelFrame.width - attached.expandedWidth) / 2,
      NotchAlertLayout.horizontalShadowInset
    )
    XCTAssertGreaterThanOrEqual(
      attached.panelFrame.height - NotchAlertLayout.expandedHeight,
      NotchAlertLayout.bottomShadowInset
    )
    XCTAssertFalse(floating.isAttachedToCameraHousing)
    XCTAssertEqual(floating.panelFrame.maxY, visibleFrame.maxY)
    XCTAssertEqual(floating.compactWidth, 112)
    XCTAssertGreaterThan(NotchWindowCoordinator.fadeInDuration, 0)
    XCTAssertGreaterThan(NotchWindowCoordinator.collapseDuration, 0)
    XCTAssertLessThan(NotchAlertMotion.springDuration, 0.5)
    XCTAssertGreaterThanOrEqual(NotchAlertMotion.springBounce, 0.45)
    XCTAssertEqual(
      NotchAlertShapeMetrics.bottomCornerRadius(
        isAttachedToCameraHousing: true,
        isExpanded: false
      ),
      18
    )
    XCTAssertLessThan(
      NotchAlertShapeMetrics.bottomCornerRadius(
        isAttachedToCameraHousing: true,
        isExpanded: false
      ),
      NotchAlertShapeMetrics.bottomCornerRadius(
        isAttachedToCameraHousing: true,
        isExpanded: true
      )
    )
    XCTAssertEqual(
      NotchAlertShapeMetrics.bottomCornerRadius(
        isAttachedToCameraHousing: false,
        isExpanded: false
      ),
      20
    )

    let panel = NotchWindowCoordinator.makePanel(frame: attached.panelFrame, screen: nil)
    defer { panel.orderOut(nil) }
    XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
    XCTAssertTrue(panel.ignoresMouseEvents)
    XCTAssertFalse(panel.hidesOnDeactivate)
    XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
    XCTAssertTrue(panel.collectionBehavior.contains(.fullScreenAuxiliary))
  }

  func testNotchUnreadIndicatorTracksOnlyRetainedSessionsUntilAcknowledged() {
    let coordinator = NotchWindowCoordinator(screensProvider: { [] })

    coordinator.show(
      Self.alert(sessionID: "session-a"),
      headline: "Codex 本轮已停止",
      displayStrategy: .focused,
      unreadCount: 1
    )
    coordinator.show(
      Self.alert(sessionID: "session-b"),
      headline: "Codex 本轮已停止",
      displayStrategy: .focused,
      unreadCount: 2
    )
    coordinator.show(
      Self.alert(sessionID: "test-session"),
      headline: "Codex 本轮已停止",
      displayStrategy: .focused,
      unreadCount: nil
    )

    XCTAssertEqual(coordinator.retainedUnreadCount, 2)
    coordinator.dismiss(
      sessionID: "session-a",
      remainingUnreadCount: 1,
      retainsUnreadIndicator: true
    )
    XCTAssertEqual(coordinator.retainedUnreadCount, 1)
    coordinator.dismiss(
      sessionID: "session-b",
      remainingUnreadCount: 0,
      retainsUnreadIndicator: true
    )
    XCTAssertEqual(coordinator.retainedUnreadCount, 0)
  }

  func testNotchUnreadIndicatorIsIndependentFromVisualAlertMode() async {
    let suiteName = "NotchUnreadIndicatorTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set(false, forKey: "alerts.completion.soundEnabled")
    defaults.set(false, forKey: "alerts.systemNotificationEnabled")
    defaults.set(AlertVisualMode.none.rawValue, forKey: "alerts.visualMode")
    let notchCoordinator = NotchWindowCoordinator(screensProvider: { [] })
    let coordinator = CompletionAlertCoordinator(
      notchCoordinator: notchCoordinator,
      defaults: defaults
    )

    XCTAssertTrue(NotchUnreadIndicatorPreference.isEnabled(in: defaults))
    await coordinator.deliver(Self.alert(sessionID: "session-independent"), unreadCount: 1)
    XCTAssertEqual(notchCoordinator.retainedUnreadCount, 1)

    defaults.set(false, forKey: NotchUnreadIndicatorPreference.storageKey)
    coordinator.synchronizeNotchUnreadIndicator(unreadCount: 1)
    XCTAssertEqual(notchCoordinator.retainedUnreadCount, 0)
  }

  func testSettingsDetailKeepsExplicitHorizontalContentMargin() {
    XCTAssertGreaterThanOrEqual(SettingsDetailLayout.horizontalContentMargin, 20)
  }

  func testBlurOnlyUsesSystemAdaptiveForegroundWithoutChangingPrivacyFixtures() {
    XCTAssertEqual(
      OverlayForegroundTone(backgroundStyle: .blurOnly, usesPrivacyShield: false),
      .systemAdaptive
    )
    XCTAssertEqual(
      OverlayForegroundTone(backgroundStyle: .blurOnly, usesPrivacyShield: true),
      .fixedLight
    )
    for style in [
      OverlayBackgroundStyle.solid,
      .gradient,
      .image,
    ] {
      XCTAssertEqual(
        OverlayForegroundTone(backgroundStyle: style, usesPrivacyShield: false),
        .fixedLight
      )
    }
  }

  func testCustomHeadlineIsNormalizedBoundedAndFallsBackWhenBlank() {
    let suiteName = "AlertHeadlineTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    defaults.set("  自定义\n提醒标题  ", forKey: AlertHeadlineChannel.fullscreen.storageKey)
    XCTAssertEqual(
      AlertHeadlineChannel.fullscreen.customTitle(defaults: defaults),
      "自定义 提醒标题"
    )
    defaults.set(String(repeating: "长", count: 50), forKey: AlertHeadlineChannel.hud.storageKey)
    XCTAssertEqual(
      AlertHeadlineChannel.hud.customTitle(defaults: defaults)?.count,
      AlertHeadlineChannel.maximumLength
    )
    defaults.set("   ", forKey: AlertHeadlineChannel.notification.storageKey)
    XCTAssertEqual(
      AlertHeadlineChannel.notification.resolvedTitle(
        for: .completion,
        defaults: defaults
      ),
      AlertSituation.completion.alertTitle
    )
  }

  func testOverlayAppearanceNormalizesColorsAndClampsNumericSettings() {
    let configuration = OverlayAppearanceConfiguration(
      backgroundStyle: .gradient,
      solidHex: "#00aa55",
      gradientStartHex: "#12abEF",
      gradientEndHex: "invalid",
      opacity: 2,
      blurRadius: -5,
      blurOnlyIntensity: 2,
      imageBlurRadius: 80,
      imageURL: nil
    )

    XCTAssertEqual(configuration.solidHex, "#00AA55")
    XCTAssertEqual(configuration.gradientStartHex, "#12ABEF")
    XCTAssertEqual(
      configuration.gradientEndHex,
      OverlayAppearanceConfiguration.defaultGradientEndHex
    )
    XCTAssertEqual(configuration.opacity, 1)
    XCTAssertEqual(configuration.blurRadius, 0)
    XCTAssertEqual(configuration.blurOnlyIntensity, 1)
    XCTAssertEqual(configuration.backdropBlurIntensity, 0)
    XCTAssertEqual(configuration.imageBlurRadius, 40)
    let components = OverlayColorCodec.components(
      for: "#FF8000",
      fallback: OverlayAppearanceConfiguration.defaultGradientStartHex
    )
    XCTAssertEqual(components.red, 1, accuracy: 0.001)
    XCTAssertEqual(components.green, 128.0 / 255, accuracy: 0.001)
    XCTAssertEqual(components.blue, 0, accuracy: 0.001)
  }

  func testOverlayBackgroundStyleExposesOnlyTheSelectedSource() {
    let imageURL = URL(fileURLWithPath: "/tmp/managed-overlay.image")
    let gradient = OverlayAppearanceConfiguration(
      backgroundStyle: .gradient,
      solidHex: OverlayAppearanceConfiguration.defaultSolidHex,
      gradientStartHex: OverlayAppearanceConfiguration.defaultGradientStartHex,
      gradientEndHex: OverlayAppearanceConfiguration.defaultGradientEndHex,
      opacity: OverlayAppearanceConfiguration.defaultOpacity,
      blurRadius: OverlayAppearanceConfiguration.defaultBlurRadius,
      imageBlurRadius: OverlayAppearanceConfiguration.defaultImageBlurRadius,
      imageURL: imageURL
    )
    let image = OverlayAppearanceConfiguration(
      backgroundStyle: .image,
      solidHex: OverlayAppearanceConfiguration.defaultSolidHex,
      gradientStartHex: OverlayAppearanceConfiguration.defaultGradientStartHex,
      gradientEndHex: OverlayAppearanceConfiguration.defaultGradientEndHex,
      opacity: OverlayAppearanceConfiguration.defaultOpacity,
      blurRadius: OverlayAppearanceConfiguration.defaultBlurRadius,
      imageBlurRadius: 18,
      imageURL: imageURL
    )
    let blurOnly = OverlayAppearanceConfiguration(
      backgroundStyle: .blurOnly,
      solidHex: OverlayAppearanceConfiguration.defaultSolidHex,
      gradientStartHex: OverlayAppearanceConfiguration.defaultGradientStartHex,
      gradientEndHex: OverlayAppearanceConfiguration.defaultGradientEndHex,
      opacity: OverlayAppearanceConfiguration.defaultOpacity,
      blurRadius: OverlayAppearanceConfiguration.defaultBlurRadius,
      imageBlurRadius: OverlayAppearanceConfiguration.defaultImageBlurRadius,
      imageURL: imageURL
    )

    XCTAssertNil(gradient.imageURL)
    XCTAssertNil(blurOnly.imageURL)
    XCTAssertEqual(image.imageURL, imageURL)
    XCTAssertEqual(image.imageBlurRadius, 18)
    XCTAssertTrue(gradient.usesBackdropBlur)
    XCTAssertTrue(blurOnly.usesBackdropBlur)
    XCTAssertFalse(image.usesBackdropBlur)
    XCTAssertEqual(gradient.backdropBlurIntensity, 0)
    XCTAssertEqual(
      blurOnly.backdropBlurIntensity,
      OverlayAppearanceConfiguration.defaultBlurOnlyIntensity
    )
    XCTAssertGreaterThanOrEqual(
      OverlayAppearanceConfiguration.defaultBlurOnlyIntensity,
      0.8
    )

    let fullBackdropBlur = OverlayAppearanceConfiguration(
      backgroundStyle: .solid,
      solidHex: OverlayAppearanceConfiguration.defaultSolidHex,
      gradientStartHex: OverlayAppearanceConfiguration.defaultGradientStartHex,
      gradientEndHex: OverlayAppearanceConfiguration.defaultGradientEndHex,
      opacity: OverlayAppearanceConfiguration.defaultOpacity,
      blurRadius: OverlayAppearanceConfiguration.blurRange.upperBound,
      imageBlurRadius: OverlayAppearanceConfiguration.defaultImageBlurRadius,
      imageURL: nil
    )
    XCTAssertEqual(fullBackdropBlur.backdropBlurIntensity, 1)
  }

  func testCustomImageLayoutAspectFillsAndStaysCentered() {
    let container = CGSize(width: 300, height: 300)
    let landscape = OverlayImageFillLayout.centeredFrame(
      imageSize: CGSize(width: 400, height: 200),
      containerSize: container
    )
    let portrait = OverlayImageFillLayout.centeredFrame(
      imageSize: CGSize(width: 200, height: 400),
      containerSize: container
    )

    XCTAssertEqual(landscape, CGRect(x: -150, y: 0, width: 600, height: 300))
    XCTAssertEqual(portrait, CGRect(x: 0, y: -150, width: 300, height: 600))
    XCTAssertEqual(landscape.midX, container.width / 2)
    XCTAssertEqual(landscape.midY, container.height / 2)
    XCTAssertEqual(portrait.midX, container.width / 2)
    XCTAssertEqual(portrait.midY, container.height / 2)
    XCTAssertEqual(
      OverlayImageFillLayout.blurScale(radius: 0, containerSize: container),
      1
    )
    XCTAssertGreaterThan(
      OverlayImageFillLayout.blurScale(radius: 20, containerSize: container),
      1
    )
  }

  func testCustomBackgroundImageIsCopiedPrivatelyAndRemoved() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("OverlayAppearanceTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let sourceURL = root.appendingPathComponent("sample.png")
    let destinationURL =
      root
      .appendingPathComponent("managed", isDirectory: true)
      .appendingPathComponent("overlay-background.image")
    let bitmap = try XCTUnwrap(
      NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: 4,
        pixelsHigh: 4,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
      )
    )
    let imageData = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    try imageData.write(to: sourceURL)
    let suiteName = "OverlayAppearanceServiceTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let service = OverlayAppearanceService(
      defaults: defaults,
      customImageURL: destinationURL
    )

    try service.importImage(from: sourceURL)
    try service.importImage(from: sourceURL)

    XCTAssertTrue(service.hasCustomImage)
    XCTAssertEqual(service.customImageDisplayName, "sample.png")
    XCTAssertEqual(service.configuration().backgroundStyle, .image)
    XCTAssertEqual(service.configuration().imageURL, destinationURL)
    let permissions =
      try FileManager.default.attributesOfItem(atPath: destinationURL.path)[
        .posixPermissions
      ] as? NSNumber
    XCTAssertEqual(permissions?.intValue, 0o600)

    try service.removeCustomImage()

    XCTAssertFalse(service.hasCustomImage)
    XCTAssertNil(service.customImageDisplayName)
    XCTAssertEqual(service.configuration().backgroundStyle, .gradient)
  }

  func testOverlayAppearanceCanRestoreDefaultsWithoutDeletingImportedImage() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "OverlayAppearanceRestoreTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let managedImageURL = root.appendingPathComponent("overlay-background.image")
    try Data([0]).write(to: managedImageURL)
    let suiteName = "OverlayAppearanceRestoreDefaultsTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set(
      OverlayBackgroundStyle.solid.rawValue, forKey: OverlayAppearanceKeys.backgroundStyle)
    defaults.set("#FFFFFF", forKey: OverlayAppearanceKeys.solidColor)
    defaults.set("#000000", forKey: OverlayAppearanceKeys.gradientStartColor)
    defaults.set("#111111", forKey: OverlayAppearanceKeys.gradientEndColor)
    defaults.set(0.15, forKey: OverlayAppearanceKeys.backgroundOpacity)
    defaults.set(27.0, forKey: OverlayAppearanceKeys.backgroundBlur)
    defaults.set(0.1, forKey: OverlayAppearanceKeys.blurOnlyIntensity)
    defaults.set(23.0, forKey: OverlayAppearanceKeys.imageBlur)
    let service = OverlayAppearanceService(
      defaults: defaults,
      customImageURL: managedImageURL
    )

    service.restoreDefaults()

    let configuration = service.configuration()
    XCTAssertEqual(configuration, .defaultConfiguration)
    XCTAssertTrue(service.hasCustomImage)
  }

  func testMissingManagedImageFallsBackToGradientMode() throws {
    let suiteName = "OverlayAppearanceMissingImageTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set(
      OverlayBackgroundStyle.image.rawValue, forKey: OverlayAppearanceKeys.backgroundStyle)
    let missingImageURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathComponent("overlay-background.image")

    let service = OverlayAppearanceService(
      defaults: defaults,
      customImageURL: missingImageURL
    )

    XCTAssertFalse(service.hasCustomImage)
    XCTAssertEqual(service.configuration().backgroundStyle, .gradient)
  }

  func testStaleInteractionCannotDismissReplacementOverlay() throws {
    let coordinator = OverlayWindowCoordinator(screensProvider: { [] })
    let staleHandlerSpy = OverlayInteractionHandlerSpy()

    coordinator.show(Self.alert(sessionID: "session-a"))
    staleHandlerSpy.retain(
      try XCTUnwrap(coordinator.currentInteractionHandler)
    )
    coordinator.show(
      Self.alert(sessionID: "session-b"),
      dismissalMode: .mouseMovement
    )
    let currentHandler = try XCTUnwrap(coordinator.currentInteractionHandler)

    staleHandlerSpy.simulateInteraction()
    XCTAssertTrue(coordinator.isPresenting)
    XCTAssertEqual(coordinator.currentSituation, .completion)

    currentHandler()
    XCTAssertFalse(coordinator.isPresenting)
  }

  func testMultipleCompletionsAggregateAndDismissIndependently() {
    let coordinator = OverlayWindowCoordinator(screensProvider: { [] })

    coordinator.show(
      Self.alert(sessionID: "session-a"),
      autoDismiss: .fiveSeconds
    )
    let firstTimeoutGeneration = coordinator.currentAutoDismissGeneration
    coordinator.show(
      Self.alert(sessionID: "session-b"),
      autoDismiss: .fiveSeconds
    )

    XCTAssertTrue(coordinator.isPresenting)
    XCTAssertEqual(coordinator.currentSituation, .completion)
    XCTAssertEqual(coordinator.presentedAlertCount, 2)
    XCTAssertTrue(coordinator.hasScheduledAutoDismiss)
    XCTAssertNotEqual(coordinator.currentAutoDismissGeneration, firstTimeoutGeneration)

    coordinator.dismiss(sessionID: "session-a")
    XCTAssertTrue(coordinator.isPresenting)
    XCTAssertEqual(coordinator.presentedAlertCount, 1)

    coordinator.dismiss(sessionID: "session-b")
    XCTAssertFalse(coordinator.isPresenting)
  }

  func testNeverAutoDismissDoesNotScheduleTimeout() {
    let coordinator = OverlayWindowCoordinator(screensProvider: { [] })

    coordinator.show(Self.alert(sessionID: "session-a"), autoDismiss: .never)

    XCTAssertTrue(coordinator.isPresenting)
    XCTAssertFalse(coordinator.hasScheduledAutoDismiss)
    coordinator.dismissAll()
  }

  func testSameSessionReplacementSurvivesCancelledOldTimeout() async {
    let coordinator = OverlayWindowCoordinator(screensProvider: { [] })

    coordinator.show(
      Self.alert(sessionID: "session-a"),
      autoDismiss: .fiveSeconds
    )
    coordinator.show(
      Self.alert(sessionID: "session-a", title: "更新后的标题"),
      autoDismiss: .fiveSeconds
    )
    await Task.yield()

    XCTAssertTrue(coordinator.isPresenting)
    XCTAssertEqual(coordinator.presentedAlertCount, 1)
    XCTAssertTrue(coordinator.hasScheduledAutoDismiss)
    coordinator.dismissAll()
  }

  private static func alert(
    sessionID: String,
    title: String = "检查全屏叠加"
  ) -> AlertPresentation {
    AlertPresentation(
      id: "alert-\(sessionID)",
      situation: .completion,
      sessionID: sessionID,
      conversationTitle: title,
      projectDisplayName: "CodexDone"
    )
  }
}

@MainActor
private final class OverlayInteractionHandlerSpy {
  private var retainedHandler: (@MainActor () -> Void)?

  func retain(_ handler: @escaping @MainActor () -> Void) {
    retainedHandler = handler
  }

  func simulateInteraction() {
    retainedHandler?()
  }
}
