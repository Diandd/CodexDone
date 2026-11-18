import AppKit
import XCTest

@MainActor
final class CodexDoneUITests: XCTestCase {
  override func setUpWithError() throws {
    continueAfterFailure = false
  }

  func testMenuBarCompletionList() throws {
    let app = localizedApplication()
    app.launchArguments += [
      "--ui-test",
      "--ui-test-open-menu-popover",
      "--ui-test-hooks-uninstalled",
      "-appearance.colorScheme", "light",
      "-alerts.visualMode", "none",
    ]
    app.launch()
    addTeardownBlock { app.terminate() }

    let popover = app.descendants(matching: .any)["menu-popover-root"]
    XCTAssertTrue(popover.waitForExistence(timeout: 5))
    let visualModeMenu = app.descendants(matching: .any)["menu-visual-mode-menu"]
    XCTAssertTrue(visualModeMenu.exists)
    // Accessibility measures the content, excluding the 12 pt outer insets.
    XCTAssertEqual(popover.frame.height, 350, accuracy: 1)
    let title = app.staticTexts["1 条待查看"]
    XCTAssertTrue(title.waitForExistence(timeout: 5))
    XCTAssertGreaterThan(title.frame.width, 50)
    XCTAssertGreaterThanOrEqual(title.frame.minY, popover.frame.minY)
    XCTAssertTrue(app.descendants(matching: .any)["menu-health-warning"].exists)
    let healthWarning = app.staticTexts["Hook 尚未安装"]
    XCTAssertTrue(healthWarning.exists)
    XCTAssertGreaterThan(healthWarning.frame.minX, title.frame.maxX)
    XCTAssertEqual(healthWarning.frame.midY, title.frame.midY, accuracy: 5)
    let openCodex = app.buttons["menu-open-codex"]
    XCTAssertFalse(openCodex.exists)
    XCTAssertLessThanOrEqual(visualModeMenu.frame.maxX, popover.frame.maxX)
    let conversation = app.buttons["menu-open-session-ui-test-record-codexdone"]
    XCTAssertTrue(conversation.label.contains("优化 CodexDone 菜单信息层级"))
    XCTAssertTrue(app.staticTexts["CodexDone"].exists)
    XCTAssertTrue(
      conversation.label.contains("已调整聊天主题、项目名称与回复预览的层级，菜单内容现在更容易快速浏览。")
    )
    let attachment = XCTAttachment(screenshot: popover.screenshot())
    attachment.name = "completion-menu-popover.png"
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  func testMenuBarStatusItemKeepsWidthWhenPopoverOpens() throws {
    let app = localizedApplication()
    app.launchArguments += [
      "--ui-test",
      "--ui-test-multiple-records",
      "-menuBar.showUnreadCount", "YES",
    ]
    app.launch()
    addTeardownBlock { app.terminate() }

    let statusItem = app.descendants(matching: .any)["menu-bar-status-item"]
    XCTAssertTrue(statusItem.waitForExistence(timeout: 5))
    let closedWidth = statusItem.frame.width

    statusItem.click()

    let popover = app.descendants(matching: .any)["menu-popover-root"]
    XCTAssertTrue(popover.waitForExistence(timeout: 5))
    XCTAssertEqual(statusItem.frame.width, closedWidth, accuracy: 1)

    let acknowledgeAll = app.links["menu-acknowledge-all"]
    XCTAssertTrue(acknowledgeAll.waitForExistence(timeout: 5))
    acknowledgeAll.click()
    XCTAssertTrue(
      app.descendants(matching: .any)["menu-empty-state"].waitForExistence(timeout: 5)
    )
    XCTAssertEqual(statusItem.frame.width, closedWidth, accuracy: 1)
  }

  func testMenuBarPopoverClosesAfterClickingAnotherApplication() throws {
    let app = localizedApplication()
    app.launchArguments += ["--ui-test"]
    app.launch()
    addTeardownBlock { app.terminate() }

    let finder = XCUIApplication(bundleIdentifier: "com.apple.finder")
    finder.activate()
    let statusItem = app.descendants(matching: .any)["menu-bar-status-item"]
    XCTAssertTrue(statusItem.waitForExistence(timeout: 5))
    statusItem.click()
    let popover = app.descendants(matching: .any)["menu-popover-root"]
    XCTAssertTrue(popover.waitForExistence(timeout: 5))

    let screen = try XCTUnwrap(NSScreen.main).frame.size
    statusItem.coordinate(withNormalizedOffset: .zero)
      .withOffset(CGVector(dx: screen.width / 2 - statusItem.frame.minX,
        dy: screen.height / 2 - statusItem.frame.minY)).click()
    XCTAssertTrue(popover.waitForNonExistence(timeout: 5))
  }

  func testStatusItemContextMenuOpensSettingsAndQuits() throws {
    let app = localizedApplication()
    app.launchArguments += ["--ui-test"]
    app.launch()
    addTeardownBlock { app.terminate() }

    let statusItem = app.descendants(matching: .any)["menu-bar-status-item"]
    XCTAssertTrue(statusItem.waitForExistence(timeout: 5))
    statusItem.rightClick()
    let settings = app.menuItems["设置"]
    XCTAssertTrue(settings.waitForExistence(timeout: 5))
    XCTAssertTrue(app.menuItems["退出 CodexDone"].exists)
    XCTAssertFalse(app.descendants(matching: .any)["menu-popover-root"].exists)
    settings.click()
    XCTAssertTrue(app.descendants(matching: .any)["settings-root"].waitForExistence(timeout: 5))

    statusItem.click()
    XCTAssertTrue(app.descendants(matching: .any)["menu-popover-root"].waitForExistence(timeout: 5))
    statusItem.rightClick()
    let quit = app.menuItems["退出 CodexDone"]
    XCTAssertTrue(quit.waitForExistence(timeout: 5))
    quit.click()
    XCTAssertTrue(app.wait(for: .notRunning, timeout: 5))
  }

  func testNotchClickShowsFailureAndKeepsConversationsUnread() throws {
    let app = localizedApplication()
    app.launchArguments += ["--ui-test", "--ui-test-show-notch",
      "--ui-test-multiple-records", "--ui-test-notification-without-target",
      "--ui-test-alcove-running"]
    app.launch()
    addTeardownBlock { app.terminate() }

    let notch = app.descendants(matching: .any)["completion-notch-open-codex"]
    XCTAssertTrue(notch.waitForExistence(timeout: 5))
    notch.click()
    XCTAssertTrue(app.staticTexts["无法打开会话"].waitForExistence(timeout: 5))
    let statusItem = app.descendants(matching: .any)["menu-bar-status-item"]
    statusItem.click()
    XCTAssertTrue(app.staticTexts["2 条待查看"].waitForExistence(timeout: 5))
  }

  func testStatusItemUnreadCountCanBeHiddenFromSettings() throws {
    let app = localizedApplication()
    app.launchArguments += [
      "--ui-test",
      "--ui-test-multiple-records",
      "-menuBar.showUnreadCount", "YES",
    ]
    app.launch()
    addTeardownBlock { app.terminate() }

    let statusItem = app.descendants(matching: .any)["menu-bar-status-item"]
    XCTAssertTrue(statusItem.waitForExistence(timeout: 5))
    let widthWithCount = statusItem.frame.width

    statusItem.click()
    XCTAssertTrue(app.buttons["设置"].waitForExistence(timeout: 5))
    app.buttons["设置"].click()
    XCTAssertTrue(app.staticTexts["菜单栏"].waitForExistence(timeout: 5))
    let countToggle = app.descendants(matching: .any)["settings-status-item-count"]
    XCTAssertTrue(countToggle.waitForExistence(timeout: 5))
    countToggle.click()
    XCTAssertTrue(waitForStatusItemWidth(statusItem, lessThan: widthWithCount, timeout: 2))

    countToggle.click()
    XCTAssertTrue(waitForStatusItemWidth(statusItem, greaterThan: widthWithCount - 1, timeout: 2))
  }

  func testEnglishLocalizationShowsMenuAndSettings() throws {
    let app = localizedApplication(language: "en")
    app.launchArguments += ["--ui-test", "--ui-test-open-menu-popover"]
    app.launch()
    addTeardownBlock { app.terminate() }

    let popover = app.descendants(matching: .any)["menu-popover-root"]
    XCTAssertTrue(popover.waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["1 to review"].exists)
    XCTAssertTrue(app.buttons["Settings"].exists)
    XCTAssertFalse(app.buttons["Open conversation"].exists)
    XCTAssertFalse(app.buttons["menu-open-codex"].exists)

    app.buttons["Settings"].click()
    let settingsWindow = app.descendants(matching: .any)["settings-root"]
    XCTAssertTrue(settingsWindow.waitForExistence(timeout: 5))
    let nativeWindow = app.windows.containing(.any, identifier: "settings-root").firstMatch
    XCTAssertEqual(nativeWindow.title, "General")
    XCTAssertTrue(app.staticTexts["Connected agents"].exists)
    XCTAssertTrue(app.staticTexts["Alerts"].exists)
    XCTAssertTrue(app.staticTexts["App"].exists)
    XCTAssertTrue(app.descendants(matching: .any)["settings-language"].exists)
  }

  func testMultipleMenuRecordsCanBeAcknowledgedIndependently() throws {
    let app = localizedApplication()
    app.launchArguments += [
      "--ui-test",
      "--ui-test-multiple-records",
      "--ui-test-open-menu-popover",
    ]
    app.launch()
    addTeardownBlock { app.terminate() }

    let popover = app.descendants(matching: .any)["menu-popover-root"]
    XCTAssertTrue(popover.waitForExistence(timeout: 5))
    let stablePopoverFrame = popover.frame
    XCTAssertEqual(stablePopoverFrame.height, 350, accuracy: 1)
    XCTAssertTrue(app.staticTexts["2 条待查看"].waitForExistence(timeout: 5))
    XCTAssertTrue(
      app.buttons["menu-open-session-ui-test-record-codexdone"].label.contains("优化 CodexDone 菜单信息层级")
    )
    XCTAssertTrue(
      app.buttons["menu-open-session-ui-test-record-sprout"].label.contains("完善课程通知管理")
    )
    XCTAssertTrue(app.staticTexts["CodexDone"].exists)
    XCTAssertTrue(app.staticTexts["ProjectSprout"].exists)
    let acknowledgeButtons = app.buttons.matching(
      NSPredicate(format: "identifier BEGINSWITH %@", "menu-acknowledge-ui-test-record-")
    )
    XCTAssertEqual(acknowledgeButtons.count, 2)

    let firstAcknowledge = app.buttons["menu-acknowledge-ui-test-record-codexdone"]
    XCTAssertTrue(firstAcknowledge.waitForExistence(timeout: 5))
    firstAcknowledge.click()

    XCTAssertTrue(app.staticTexts["1 条待查看"].waitForExistence(timeout: 5))
    assertFrame(popover.frame, remainsAt: stablePopoverFrame)
    XCTAssertTrue(popover.exists)
    XCTAssertFalse(firstAcknowledge.exists)
    XCTAssertTrue(app.staticTexts["ProjectSprout"].exists)
    XCTAssertEqual(acknowledgeButtons.count, 1)

    let acknowledgeAll = app.links["menu-acknowledge-all"]
    XCTAssertTrue(acknowledgeAll.waitForExistence(timeout: 5))
    acknowledgeAll.click()
    XCTAssertTrue(
      app.descendants(matching: .any)["menu-empty-state"].waitForExistence(timeout: 5)
    )
    assertFrame(popover.frame, remainsAt: stablePopoverFrame)
    XCTAssertTrue(popover.exists)
    XCTAssertEqual(acknowledgeButtons.count, 0)
  }

  func testMenuPopoverUpdatesFromEmptyToUnreadWithoutReopening() throws {
    let app = localizedApplication()
    app.launchArguments += [
      "--ui-test",
      "--ui-test-open-menu-popover",
      "--ui-test-menu-live-transition",
    ]
    app.launch()
    addTeardownBlock { app.terminate() }

    let popover = app.descendants(matching: .any)["menu-popover-root"]
    XCTAssertTrue(popover.waitForExistence(timeout: 5))
    XCTAssertTrue(
      app.descendants(matching: .any)["menu-empty-state"].waitForExistence(timeout: 5)
    )
    let stablePopoverFrame = popover.frame

    XCTAssertTrue(
      app.buttons["menu-open-session-ui-test-record-codexdone"].waitForExistence(timeout: 5)
    )
    XCTAssertTrue(popover.exists)
    assertFrame(popover.frame, remainsAt: stablePopoverFrame)
    XCTAssertFalse(app.descendants(matching: .any)["menu-empty-state"].exists)
  }

  private func assertFrame(
    _ actual: CGRect,
    remainsAt expected: CGRect,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertEqual(actual.minX, expected.minX, accuracy: 1, file: file, line: line)
    // The SwiftUI accessibility union can move by 2 pt when the empty-state
    // element is replaced by a list even though the fixed popover stays put.
    XCTAssertEqual(actual.minY, expected.minY, accuracy: 2, file: file, line: line)
    XCTAssertEqual(actual.width, expected.width, accuracy: 1, file: file, line: line)
    XCTAssertEqual(actual.height, expected.height, accuracy: 1, file: file, line: line)
  }

  func testSettingsWindow() throws {
    let app = localizedApplication()
    app.launchArguments += ["--ui-test", "--ui-test-open-menu-popover"]
    app.launch()
    addTeardownBlock { app.terminate() }

    let settingsButton = app.buttons["设置"]
    XCTAssertTrue(settingsButton.waitForExistence(timeout: 5))
    settingsButton.click()
    let settingsWindow = app.descendants(matching: .any)["settings-root"]
    XCTAssertTrue(settingsWindow.waitForExistence(timeout: 5))
    let attachment = XCTAttachment(screenshot: settingsWindow.screenshot())
    attachment.name = "completion-settings.png"
    attachment.lifetime = .keepAlways
    add(attachment)
    let nativeWindow = app.windows.containing(.any, identifier: "settings-root").firstMatch
    XCTAssertEqual(nativeWindow.title, "常规")
    XCTAssertFalse(app.staticTexts["settings-toolbar-title"].exists)
    let closeButton = nativeWindow.buttons[XCUIIdentifierCloseWindow]
    let minimizeButton = nativeWindow.buttons[XCUIIdentifierMinimizeWindow]
    let zoomButton = nativeWindow.buttons[XCUIIdentifierZoomWindow]
    XCTAssertTrue(closeButton.exists)
    XCTAssertTrue(minimizeButton.exists)
    XCTAssertTrue(zoomButton.exists)
    let sidebar = app.descendants(matching: .any)["settings-sidebar"]
    XCTAssertTrue(sidebar.exists)
    XCTAssertTrue(app.descendants(matching: .any)["settings-section-general"].exists)
    XCTAssertTrue(app.descendants(matching: .any)["settings-section-alerts"].exists)
    XCTAssertTrue(app.descendants(matching: .any)["settings-section-diagnostics"].exists)
    XCTAssertTrue(app.descendants(matching: .any)["settings-section-about"].exists)
    XCTAssertFalse(app.descendants(matching: .any)["settings-section-hooks"].exists)
    XCTAssertFalse(app.descendants(matching: .any)["settings-section-appearance"].exists)
    XCTAssertFalse(app.descendants(matching: .any)["settings-section-privacy"].exists)
    XCTAssertTrue(app.buttons["settings-install-hooks"].exists)
    XCTAssertTrue(app.buttons["settings-hook-enablement-guide"].exists)
    XCTAssertFalse(app.descendants(matching: .any)["settings-completion-alert-enabled"].exists)
    XCTAssertTrue(app.descendants(matching: .any)["settings-system-notification-enabled"].exists)
    XCTAssertTrue(app.descendants(matching: .any)["settings-status-item-count"].exists)
    XCTAssertTrue(app.descendants(matching: .any)["settings-notch-unread-indicator"].exists)
    XCTAssertTrue(app.descendants(matching: .any)["settings-visual-mode"].exists)
    XCTAssertTrue(app.descendants(matching: .any)["settings-visual-alert-enabled"].exists)
    let visualModeLabel = app.staticTexts["settings-visual-mode-label"]
    let smartOption = app.buttons["settings-visual-option-smart"]
    let fullscreenOption = app.buttons["settings-visual-option-fullscreen"]
    let hudOption = app.buttons["settings-visual-option-hud"]
    let notchOption = app.buttons["settings-visual-option-notch"]
    XCTAssertTrue(visualModeLabel.exists)
    XCTAssertTrue(smartOption.exists)
    XCTAssertTrue(fullscreenOption.exists)
    XCTAssertTrue(hudOption.exists)
    XCTAssertTrue(notchOption.exists)
    XCTAssertLessThanOrEqual(visualModeLabel.frame.maxY, smartOption.frame.minY)
    XCTAssertGreaterThanOrEqual(smartOption.frame.minX, visualModeLabel.frame.minX - 1)
    XCTAssertLessThan(smartOption.frame.minX, fullscreenOption.frame.minX)
    XCTAssertLessThan(fullscreenOption.frame.minX, hudOption.frame.minX)
    XCTAssertLessThan(hudOption.frame.minX, notchOption.frame.minX)
    XCTAssertTrue(app.descendants(matching: .any)["settings-display-strategy"].exists)
    XCTAssertTrue(app.descendants(matching: .any)["settings-appearance-system"].exists)
    let toolbarTitle = try XCTUnwrap(
      settingsWindowTitle(in: nativeWindow, titled: "常规", sidebar: sidebar)
    )
    let sidebarToggle = nativeWindow.buttons["隐藏边栏"]
    XCTAssertTrue(sidebarToggle.isHittable)
    XCTAssertLessThanOrEqual(sidebarToggle.frame.width, 44)
    assertSettingsToolbarGeometry(
      zoomButton: zoomButton,
      sidebarToggle: sidebarToggle,
      sidebar: sidebar,
      toolbarTitle: toolbarTitle
    )
    let firstSectionTitle = app.staticTexts["settings-general-section-title"]
    XCTAssertTrue(firstSectionTitle.exists)
    XCTAssertLessThanOrEqual(firstSectionTitle.frame.minY - toolbarTitle.frame.maxY, 56)
    XCTAssertLessThanOrEqual(firstSectionTitle.frame.minY - nativeWindow.frame.minY, 96)

    sidebarToggle.click()
    XCTAssertTrue(waitForExistence(sidebar, expected: false, timeout: 2))
    let showSidebarToggle = nativeWindow.buttons["显示边栏"]
    XCTAssertTrue(showSidebarToggle.waitForExistence(timeout: 2))
    XCTAssertTrue(showSidebarToggle.isHittable)
    XCTAssertLessThanOrEqual(abs(showSidebarToggle.frame.midY - zoomButton.frame.midY), 12)
    showSidebarToggle.click()
    let restoredSidebar = app.descendants(matching: .any)["settings-sidebar"]
    XCTAssertTrue(restoredSidebar.waitForExistence(timeout: 2))
    XCTAssertTrue(app.staticTexts["settings-general-section-title"].exists)
    let restoredToolbarTitle = try XCTUnwrap(
      settingsWindowTitle(in: nativeWindow, titled: "常规", sidebar: restoredSidebar)
    )
    assertSettingsToolbarGeometry(
      zoomButton: zoomButton,
      sidebarToggle: nativeWindow.buttons["隐藏边栏"],
      sidebar: restoredSidebar,
      toolbarTitle: restoredToolbarTitle
    )

    let diagnosticsSection = app.descendants(matching: .any)["settings-section-diagnostics"]
    diagnosticsSection.click()
    let diagnosticsRoot = app.descendants(matching: .any)["settings-diagnostics-root"]
    XCTAssertTrue(diagnosticsRoot.waitForExistence(timeout: 2))
    XCTAssertEqual(nativeWindow.title, "隐私与诊断")
    XCTAssertTrue(app.buttons["刷新"].exists)
    XCTAssertTrue(app.buttons["移除 Hooks"].exists)
    XCTAssertTrue(app.buttons["打开诊断日志"].exists)
    let initializationGuideButton = app.buttons["settings-open-initialization-guide"]
    XCTAssertTrue(initializationGuideButton.exists)
    XCTAssertTrue(
      app.descendants(matching: .any)["settings-hook-diagnostic-list"].exists
    )
    let diagnosticRow = app.descendants(matching: .any)[
      "settings-hook-diagnostic-00000000-0000-0000-0000-000000000103"
    ]
    if !diagnosticRow.exists {
      diagnosticsRoot.scroll(byDeltaX: 0, deltaY: -500)
    }
    XCTAssertTrue(diagnosticRow.waitForExistence(timeout: 2))
    let diagnosticDetails = app.descendants(matching: .any)[
      "settings-hook-diagnostic-00000000-0000-0000-0000-000000000103-details"
    ]
    XCTAssertFalse(diagnosticDetails.exists)
    diagnosticRow.click()
    XCTAssertTrue(diagnosticDetails.waitForExistence(timeout: 2))
    XCTAssertTrue(diagnosticDetails.staticTexts["接收方式"].exists)
    XCTAssertTrue(diagnosticDetails.staticTexts["内容形态"].exists)
    XCTAssertTrue(diagnosticDetails.staticTexts["处理结果"].exists)
    XCTAssertTrue(
      app.descendants(matching: .any)["settings-clear-hook-diagnostics"].exists
    )
    XCTAssertFalse(app.staticTexts["本地数据"].exists)
    if !initializationGuideButton.isHittable {
      diagnosticsRoot.scroll(byDeltaX: 0, deltaY: -1_000)
    }
    XCTAssertTrue(initializationGuideButton.isHittable)
    initializationGuideButton.click()
    let initializationGuideWindow = app.windows.containing(
      .any,
      identifier: "initialization-guide-window"
    ).firstMatch
    XCTAssertTrue(initializationGuideWindow.waitForExistence(timeout: 2))
    XCTAssertTrue(
      initializationGuideWindow.descendants(matching: .any)["initialization-guide"].exists
    )
    initializationGuideWindow.buttons[XCUIIdentifierCloseWindow].click()
    XCTAssertTrue(initializationGuideWindow.waitForNonExistence(timeout: 2))
    let diagnosticsAttachment = XCTAttachment(screenshot: diagnosticsRoot.screenshot())
    diagnosticsAttachment.name = "completion-settings-diagnostics.png"
    diagnosticsAttachment.lifetime = .keepAlways
    add(diagnosticsAttachment)

    let aboutSection = app.descendants(matching: .any)["settings-section-about"]
    XCTAssertTrue(aboutSection.exists)
    aboutSection.click()
    let aboutRoot = app.descendants(matching: .any)["settings-about-root"]
    XCTAssertTrue(aboutRoot.waitForExistence(timeout: 2))
    XCTAssertEqual(nativeWindow.title, "关于")
    XCTAssertTrue(app.descendants(matching: .any)["settings-about-app-icon"].exists)
    XCTAssertFalse(app.staticTexts["Copyright © 2026 Diandd"].exists)
    XCTAssertTrue(app.staticTexts["MIT License"].exists)
    XCTAssertTrue(app.descendants(matching: .any)["settings-about-github-link"].exists)
    XCTAssertFalse(app.descendants(matching: .any)["settings-about-github-unconfigured"].exists)
    let checkUpdates = app.buttons["settings-about-check-updates"]
    XCTAssertTrue(checkUpdates.exists)
    XCTAssertTrue(checkUpdates.isEnabled)
    let aboutAttachment = XCTAttachment(screenshot: aboutRoot.screenshot())
    aboutAttachment.name = "completion-settings-about.png"
    aboutAttachment.lifetime = .keepAlways
    add(aboutAttachment)
  }

  func testAppearanceReturnsToSystemAfterLightOverride() throws {
    let app = localizedApplication()
    app.launchArguments += ["--ui-test", "--ui-test-open-menu-popover"]
    app.launch()
    addTeardownBlock { app.terminate() }

    XCTAssertTrue(app.buttons["设置"].waitForExistence(timeout: 5))
    app.buttons["设置"].click()

    let appearanceRoot = app.descendants(matching: .any)["settings-general-root"]
    let lightOption = app.descendants(matching: .any)["settings-appearance-light"]
    let systemOption = app.descendants(matching: .any)["settings-appearance-system"]
    XCTAssertTrue(appearanceRoot.waitForExistence(timeout: 5))
    XCTAssertTrue(lightOption.exists)
    XCTAssertTrue(systemOption.exists)

    lightOption.click()
    XCTAssertTrue(waitForValue(appearanceRoot, expected: "light", timeout: 2))

    let expectedSystemValue =
      NSApplication.shared.effectiveAppearance.bestMatch(
        from: [.aqua, .darkAqua]
      ) == .darkAqua ? "dark" : "light"
    systemOption.click()
    XCTAssertTrue(waitForValue(appearanceRoot, expected: expectedSystemValue, timeout: 2))
  }

  func testHookEnablementGuideShowsDesktopAndCLIInstructions() throws {
    let app = localizedApplication()
    app.launchArguments += ["--ui-test", "--ui-test-open-menu-popover"]
    app.launch()
    addTeardownBlock { app.terminate() }

    XCTAssertTrue(app.buttons["设置"].waitForExistence(timeout: 5))
    app.buttons["设置"].click()

    let guideButton = app.buttons["settings-hook-enablement-guide"]
    XCTAssertTrue(guideButton.waitForExistence(timeout: 5))
    guideButton.click()

    let guide = app.sheets.firstMatch
    XCTAssertTrue(guide.waitForExistence(timeout: 5))
    XCTAssertTrue(guide.staticTexts["启用 Hook"].exists)
    XCTAssertTrue(guide.staticTexts["在 Codex 中信任并启用两条 Hook"].exists)
    XCTAssertFalse(guide.staticTexts["在 Codex 中信任并启用两条 Hook。"].exists)
    XCTAssertTrue(guide.staticTexts["打开 ChatGPT 设置 → 钩子 → 用户配置"].exists)
    XCTAssertTrue(guide.staticTexts["信任并开启未就绪项"].exists)
    XCTAssertTrue(guide.buttons["hook-guide-install-hooks"].exists)
    XCTAssertTrue(guide.buttons["hook-guide-refresh-status"].exists)
    XCTAssertFalse(
      guide.descendants(matching: .any)["hook-guide-user-configuration-illustration"].exists
    )
    XCTAssertFalse(guide.descendants(matching: .any)["hook-guide-sandbox-warning"].exists)

    let promptStatus = guide.descendants(matching: .any)[
      "hook-guide-status-UserPromptSubmit"
    ]
    let stopStatus = guide.descendants(matching: .any)["hook-guide-status-Stop"]
    XCTAssertTrue(promptStatus.exists)
    XCTAssertTrue(stopStatus.exists)
    XCTAssertEqual(promptStatus.label, "已启用")
    XCTAssertEqual(stopStatus.label, "已启用")
    XCTAssertLessThan(promptStatus.frame.minY, stopStatus.frame.minY)

    XCTAssertFalse(guide.descendants(matching: .any)["hook-guide-toggle-UserPromptSubmit"].exists)
    XCTAssertFalse(guide.descendants(matching: .any)["hook-guide-toggle-Stop"].exists)

    let platformPicker = guide.descendants(matching: .any)["hook-guide-platform"]
    let doneButton = guide.buttons["完成"]
    XCTAssertTrue(platformPicker.exists)
    XCTAssertTrue(doneButton.exists)
    XCTAssertFalse(guide.links["OpenAI Hooks 文档"].exists)
    XCTAssertGreaterThan(platformPicker.frame.minY, stopStatus.frame.maxY)
    XCTAssertLessThan(platformPicker.frame.maxX, doneButton.frame.minX)
    XCTAssertLessThanOrEqual(abs(platformPicker.frame.midY - doneButton.frame.midY), 4)
    let leadingInset = platformPicker.frame.minX - guide.frame.minX
    let trailingInset = guide.frame.maxX - doneButton.frame.maxX
    XCTAssertLessThanOrEqual(abs(leadingInset - trailingInset), 2)
    XCTAssertLessThanOrEqual(doneButton.frame.maxY, guide.frame.maxY + 1)

    let attachment = XCTAttachment(screenshot: guide.screenshot())
    attachment.name = "hook-enablement-guide.png"
    attachment.lifetime = .keepAlways
    add(attachment)

    let cliTab = guide.descendants(matching: .any)["hook-guide-tab-cli"]
    XCTAssertTrue(cliTab.waitForExistence(timeout: 5))
    cliTab.click()
    XCTAssertTrue(guide.staticTexts["在 Codex CLI 中输入"].waitForExistence(timeout: 5))
    XCTAssertTrue(guide.staticTexts["然后信任并开启未就绪项"].exists)

    let primaryCommand = guide.descendants(matching: .any)["hook-guide-cli-command-primary"]
    XCTAssertTrue(primaryCommand.exists)
    XCTAssertFalse(guide.descendants(matching: .any)["hook-guide-cli-command-events"].exists)

    let cliAttachment = XCTAttachment(screenshot: guide.screenshot())
    cliAttachment.name = "hook-enablement-guide-cli.png"
    cliAttachment.lifetime = .keepAlways
    add(cliAttachment)
  }

  func testInitializationGuideOffersHooksAndNotificationSetup() throws {
    let app = localizedApplication()
    app.launchArguments += [
      "--ui-test",
      "--ui-test-show-initialization-guide",
      "-alerts.visualMode", "smart",
      "-alerts.systemNotificationEnabled", "true",
      "-alerts.completion.soundEnabled", "true",
      "-alerts.completion.builtInSound", "Glass",
    ]
    app.launch()
    addTeardownBlock { app.terminate() }

    let guide = app.descendants(matching: .any)["initialization-guide"]
    XCTAssertTrue(guide.waitForExistence(timeout: 5))
    XCTAssertTrue(guide.staticTexts["欢迎使用 CodexDone"].exists)
    XCTAssertTrue(guide.images["initialization-app-icon"].exists)
    XCTAssertFalse(guide.images["checkmark.circle.fill"].exists)
    XCTAssertTrue(guide.staticTexts["无需一直盯着 Codex"].exists)
    XCTAssertTrue(guide.staticTexts["从菜单栏回来查看"].exists)
    XCTAssertTrue(
      guide.descendants(matching: .any)["initialization-page-indicator"].exists
    )

    let guideWindow = app.windows.containing(.any, identifier: "initialization-guide")
      .firstMatch
    XCTAssertTrue(guideWindow.exists)
    let welcomeFeatures = guide.descendants(matching: .any)[
      "initialization-welcome-features"
    ]
    let pageIndicator = guide.descendants(matching: .any)[
      "initialization-page-indicator"
    ]
    XCTAssertTrue(welcomeFeatures.exists)
    XCTAssertLessThanOrEqual(abs(welcomeFeatures.frame.midX - guide.frame.midX), 2)
    XCTAssertLessThanOrEqual(abs(pageIndicator.frame.midX - guide.frame.midX), 2)
    let firstFeatureIcon = guide.images["bell.badge.fill"]
    let secondFeatureIcon = guide.images["menubar.rectangle"]
    let firstFeatureTitle = guide.staticTexts["无需一直盯着 Codex"]
    let secondFeatureTitle = guide.staticTexts["从菜单栏回来查看"]
    XCTAssertEqual(firstFeatureIcon.frame.minX, secondFeatureIcon.frame.minX, accuracy: 1)
    XCTAssertEqual(firstFeatureTitle.frame.minX, secondFeatureTitle.frame.minX, accuracy: 1)
    let welcomeAttachment = XCTAttachment(screenshot: guideWindow.screenshot())
    welcomeAttachment.name = "initialization-guide-welcome.png"
    welcomeAttachment.lifetime = .keepAlways
    add(welcomeAttachment)

    guide.buttons["initialization-next"].click()
    XCTAssertTrue(guide.staticTexts["完成必要设置"].waitForExistence(timeout: 2))
    XCTAssertFalse(guide.images["checkmark.shield.fill"].exists)
    XCTAssertTrue(guide.staticTexts["尚未安装"].exists)
    XCTAssertTrue(guide.staticTexts["尚未请求"].exists)
    let platformPicker = guide.descendants(matching: .any)[
      "initialization-hook-platform"
    ]
    let desktopInstruction = guide.descendants(matching: .any)[
      "initialization-desktop-instruction"
    ]
    XCTAssertTrue(platformPicker.exists)
    XCTAssertTrue(desktopInstruction.exists)
    XCTAssertLessThanOrEqual(abs(platformPicker.frame.minX - desktopInstruction.frame.minX), 3)

    let installButton = guide.buttons["initialization-install-hooks"]
    let notificationButton = guide.buttons["initialization-notification-permission"]
    XCTAssertTrue(installButton.exists)
    XCTAssertEqual(installButton.label, "安装 Hooks")
    XCTAssertTrue(notificationButton.exists)
    XCTAssertEqual(notificationButton.label, "允许通知")

    installButton.click()
    XCTAssertTrue(guide.staticTexts["待信任"].waitForExistence(timeout: 2))
    XCTAssertEqual(guide.buttons["initialization-install-hooks"].label, "重新安装")
    XCTAssertEqual(
      guide.descendants(matching: .any)["hook-guide-status-UserPromptSubmit"].label,
      "待信任"
    )
    XCTAssertEqual(
      guide.descendants(matching: .any)["hook-guide-status-Stop"].label,
      "待信任"
    )

    notificationButton.click()
    XCTAssertTrue(guide.staticTexts["已允许"].waitForExistence(timeout: 2))
    XCTAssertFalse(guide.buttons["initialization-notification-permission"].isEnabled)

    let permissionsAttachment = XCTAttachment(screenshot: guideWindow.screenshot())
    permissionsAttachment.name = "initialization-guide-permissions.png"
    permissionsAttachment.lifetime = .keepAlways
    add(permissionsAttachment)

    guide.buttons["initialization-next"].click()
    XCTAssertTrue(guide.staticTexts["选择提示方式"].waitForExistence(timeout: 2))
    XCTAssertFalse(
      guide.images["rectangle.inset.filled.and.person.filled"].exists
    )
    XCTAssertTrue(guide.staticTexts["以后可在“设置 → 常规 → 提醒”中更改"].exists)
    let enabledToggle = guide.descendants(matching: .any)[
      "initialization-visual-alert-enabled"
    ]
    let smartOption = guide.buttons["initialization-visual-option-smart"]
    let fullscreenOption = guide.buttons["initialization-visual-option-fullscreen"]
    let hudOption = guide.buttons["initialization-visual-option-hud"]
    let notchOption = guide.buttons["initialization-visual-option-notch"]
    XCTAssertTrue(enabledToggle.exists)
    XCTAssertTrue(smartOption.exists)
    XCTAssertTrue(fullscreenOption.exists)
    XCTAssertTrue(hudOption.exists)
    XCTAssertTrue(notchOption.exists)
    XCTAssertTrue(fullscreenOption.isEnabled)
    XCTAssertTrue(hudOption.isEnabled)
    XCTAssertEqual(smartOption.value as? String, "已选择")
    XCTAssertEqual(fullscreenOption.value as? String, "未选择")
    XCTAssertEqual(hudOption.value as? String, "未选择")
    XCTAssertLessThan(fullscreenOption.frame.minX, hudOption.frame.minX)
    XCTAssertLessThan(hudOption.frame.minX, notchOption.frame.minX)
    XCTAssertTrue(
      guide.descendants(matching: .any)["initialization-system-notification-enabled"].exists
    )
    XCTAssertTrue(
      guide.descendants(matching: .any)["initialization-launch-at-login"].exists
    )
    let soundToggle = guide.descendants(matching: .any)["initialization-sound-enabled"]
    XCTAssertTrue(soundToggle.exists)
    let builtInSound = guide.popUpButtons["initialization-built-in-sound"]
    let soundPreview = guide.buttons["initialization-preview-system-sound"]
    XCTAssertTrue(builtInSound.exists)
    XCTAssertTrue(soundPreview.exists)
    XCTAssertTrue(builtInSound.isEnabled)
    XCTAssertGreaterThan(builtInSound.frame.midY - soundToggle.frame.midY, 20)
    XCTAssertEqual(soundPreview.frame.maxX, soundToggle.frame.maxX, accuracy: 2)
    XCTAssertTrue(
      guide.descendants(matching: .any)["initialization-page-indicator"].exists
    )

    let styleAttachment = XCTAttachment(screenshot: guideWindow.screenshot())
    styleAttachment.name = "initialization-guide-alert-style.png"
    styleAttachment.lifetime = .keepAlways
    add(styleAttachment)

    XCTAssertTrue(
      guide.popUpButtons["initialization-smart-active-destination"].waitForExistence(timeout: 2)
    )
    XCTAssertTrue(guide.popUpButtons["initialization-smart-away-destination"].exists)
    XCTAssertTrue(guide.popUpButtons["initialization-smart-inactivity-duration"].exists)
    let finishButton = guide.buttons["initialization-finish"]
    XCTAssertTrue(finishButton.exists)
    XCTAssertTrue(finishButton.isHittable)
    XCTAssertLessThanOrEqual(finishButton.frame.maxY, guide.frame.maxY + 1)

    finishButton.click()
    XCTAssertTrue(waitForExistence(guide, expected: false, timeout: 2))
  }

  func testEnglishLocalizationShowsInitializationGuide() throws {
    let app = localizedApplication(language: "en")
    app.launchArguments += ["--ui-test", "--ui-test-show-initialization-guide"]
    app.launch()
    addTeardownBlock { app.terminate() }

    let guide = app.descendants(matching: .any)["initialization-guide"]
    XCTAssertTrue(guide.waitForExistence(timeout: 5))
    XCTAssertTrue(guide.staticTexts["Welcome to CodexDone"].exists)
    XCTAssertTrue(guide.staticTexts["No need to keep watching Codex"].exists)

    guide.buttons["initialization-next"].click()
    XCTAssertTrue(guide.staticTexts["Finish Setup"].waitForExistence(timeout: 2))
    XCTAssertTrue(
      guide.staticTexts["Open ChatGPT Settings → Hooks → User Configuration"].exists
    )
    XCTAssertTrue(guide.staticTexts["Trust and enable any item that is not ready"].exists)
    XCTAssertEqual(guide.buttons["initialization-install-hooks"].label, "Install Hooks")
    XCTAssertEqual(
      guide.buttons["initialization-notification-permission"].label,
      "Allow"
    )

    guide.buttons["initialization-next"].click()
    XCTAssertTrue(guide.staticTexts["Choose an Alert Style"].waitForExistence(timeout: 2))
    XCTAssertTrue(guide.staticTexts["Alert Style"].exists)
    XCTAssertTrue(guide.buttons["Smart Alerts"].exists)
    XCTAssertTrue(guide.buttons["Full-Screen Alert"].exists)
    XCTAssertTrue(guide.buttons["Top Alert"].exists)
    XCTAssertTrue(guide.buttons["Notch Alert"].exists)
    XCTAssertTrue(guide.staticTexts["Launch at Login"].exists)
  }

  private func localizedApplication(language: String = "zh-Hans") -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = [
      "-localization.language", language,
    ]
    return app
  }

  private func assertSettingsToolbarGeometry(
    zoomButton: XCUIElement,
    sidebarToggle: XCUIElement,
    sidebar: XCUIElement,
    toolbarTitle: XCUIElement
  ) {
    XCTAssertLessThanOrEqual(zoomButton.frame.maxX, sidebarToggle.frame.minX)
    XCTAssertLessThanOrEqual(sidebarToggle.frame.maxX, sidebar.frame.maxX)
    XCTAssertLessThanOrEqual(abs(sidebarToggle.frame.midY - zoomButton.frame.midY), 12)
    XCTAssertGreaterThan(toolbarTitle.frame.minX, sidebar.frame.maxX)
    XCTAssertLessThanOrEqual(abs(toolbarTitle.frame.midY - zoomButton.frame.midY), 12)
  }

  private func settingsWindowTitle(
    in window: XCUIElement,
    titled title: String,
    sidebar: XCUIElement
  ) -> XCUIElement? {
    window.staticTexts
      .matching(NSPredicate(format: "value == %@", title))
      .allElementsBoundByIndex
      .first {
        $0.frame.minY < sidebar.frame.minY && $0.frame.minX > sidebar.frame.maxX
      }
  }

  private func waitForExistence(
    _ element: XCUIElement,
    expected: Bool,
    timeout: TimeInterval
  ) -> Bool {
    let predicate = NSPredicate(format: "exists == %@", NSNumber(value: expected))
    let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
    return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
  }

  private func waitForValue(
    _ element: XCUIElement,
    expected: String,
    timeout: TimeInterval
  ) -> Bool {
    let predicate = NSPredicate(format: "value == %@", expected)
    let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
    return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
  }

  private func waitForStatusItemWidth(
    _ statusItem: XCUIElement,
    lessThan maximum: CGFloat? = nil,
    greaterThan minimum: CGFloat? = nil,
    timeout: TimeInterval
  ) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
      let width = statusItem.frame.width
      let isBelowMaximum = maximum.map { width < $0 } ?? true
      let isAboveMinimum = minimum.map { width > $0 } ?? true
      if isBelowMaximum, isAboveMinimum { return true }
      RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    } while Date() < deadline
    return false
  }

  func testDefaultSoundTestAlert() throws {
    let app = localizedApplication()
    app.launchArguments += [
      "--ui-test",
      "--ui-test-open-menu-popover",
      "--ui-test-default-sound",
      "-alerts.completion.soundEnabled", "YES",
      "-alerts.completion.useCustomSound", "NO",
      "-alerts.completion.builtInSound", "Glass",
      "-alerts.systemNotificationEnabled", "NO",
      "-alerts.visualMode", "none",
    ]
    app.launch()
    addTeardownBlock { app.terminate() }

    XCTAssertTrue(app.buttons["设置"].waitForExistence(timeout: 5))
    app.buttons["设置"].click()
    let alertsSection = app.descendants(matching: .any)["settings-section-alerts"]
    if alertsSection.waitForExistence(timeout: 5) {
      alertsSection.click()
    } else {
      let alertsLabel = app.staticTexts["提醒"].firstMatch
      XCTAssertTrue(alertsLabel.waitForExistence(timeout: 5))
      alertsLabel.click()
    }
    let alertSettings = app.descendants(matching: .any)["settings-alerts-root"]
    XCTAssertTrue(alertSettings.waitForExistence(timeout: 5))
    XCTAssertTrue(
      app.descendants(matching: .any)["alert-settings-visual-mode"].exists
    )
    let dismissalMode = app.descendants(matching: .any)["settings-overlay-dismissal-mode"]
    let autoDismiss = app.descendants(matching: .any)["settings-overlay-auto-dismiss"]
    let importAudio = app.buttons["settings-import-custom-audio"]
    let customAudio = app.descendants(matching: .any)["settings-use-custom-audio"]
    XCTAssertTrue(dismissalMode.exists)
    XCTAssertTrue(dismissalMode.isEnabled)
    XCTAssertTrue(autoDismiss.exists)
    XCTAssertTrue(autoDismiss.isEnabled)
    XCTAssertTrue(importAudio.exists)
    XCTAssertTrue(customAudio.exists)
    XCTAssertFalse(customAudio.isEnabled)
    XCTAssertLessThan(importAudio.frame.minY, customAudio.frame.minY)
    XCTAssertTrue(app.buttons["settings-preview-system-sound"].exists)
    let headlineFields = [
      app.textFields["settings-headline-fullscreen"],
      app.textFields["settings-headline-hud"],
      app.textFields["settings-headline-notification"],
    ]
    for field in headlineFields {
      XCTAssertTrue(field.exists)
      XCTAssertEqual(field.placeholderValue, "留空使用默认")
    }
    let backgroundStyle = app.descendants(matching: .any)["settings-overlay-background-style"]
    XCTAssertTrue(backgroundStyle.exists)
    XCTAssertTrue(app.descendants(matching: .any)["settings-overlay-gradient-start"].exists)
    XCTAssertFalse(app.buttons["settings-import-overlay-background"].exists)
    XCTAssertFalse(app.descendants(matching: .any)["settings-overlay-image-blur"].exists)
    let restoreAppearance = app.buttons["settings-restore-overlay-appearance"]
    XCTAssertTrue(restoreAppearance.exists)
    XCTAssertTrue(
      app.descendants(matching: .any)["settings-overlay-background-opacity"].exists
    )
    XCTAssertTrue(
      app.descendants(matching: .any)["settings-overlay-background-blur"].exists
    )

    alertSettings.scroll(byDeltaX: 0, deltaY: -650)
    backgroundStyle.click()
    app.menuItems["纯色"].click()
    XCTAssertTrue(app.descendants(matching: .any)["settings-overlay-solid-color"].exists)
    XCTAssertFalse(app.descendants(matching: .any)["settings-overlay-gradient-start"].exists)
    XCTAssertFalse(app.buttons["settings-import-overlay-background"].exists)

    backgroundStyle.click()
    app.menuItems["自定义图片"].click()
    XCTAssertTrue(app.buttons["settings-import-overlay-background"].exists)
    XCTAssertFalse(app.descendants(matching: .any)["settings-overlay-solid-color"].exists)
    XCTAssertFalse(app.descendants(matching: .any)["settings-overlay-gradient-start"].exists)
    XCTAssertTrue(app.descendants(matching: .any)["settings-overlay-image-blur"].exists)
    XCTAssertFalse(app.descendants(matching: .any)["settings-overlay-background-blur"].exists)

    restoreAppearance.click()
    XCTAssertTrue(app.descendants(matching: .any)["settings-overlay-gradient-start"].exists)
    XCTAssertFalse(app.buttons["settings-import-overlay-background"].exists)
    XCTAssertTrue(app.descendants(matching: .any)["settings-overlay-background-blur"].exists)
    XCTAssertFalse(app.descendants(matching: .any)["settings-overlay-image-blur"].exists)

    alertSettings.scroll(byDeltaX: 0, deltaY: -900)
    let fullscreenTest = app.buttons["settings-test-fullscreen-alert"]
    let hudTest = app.buttons["settings-test-hud-alert"]
    let notchTest = app.buttons["settings-test-notch-alert"]
    XCTAssertTrue(fullscreenTest.waitForExistence(timeout: 2))
    XCTAssertTrue(hudTest.exists)
    XCTAssertTrue(notchTest.exists)
    fullscreenTest.click()
    let overlay = app.descendants(matching: .any)["completion-overlay"]
    XCTAssertTrue(overlay.waitForExistence(timeout: 5))
    overlay.click()
    XCTAssertTrue(overlay.waitForNonExistence(timeout: 2))
    hudTest.click()
    let hud = app.descendants(matching: .any)["completion-hud"]
    XCTAssertTrue(hud.waitForExistence(timeout: 5))
    XCTAssertTrue(hud.waitForNonExistence(timeout: 8))
    XCTAssertTrue(alertSettings.staticTexts["系统声音已播放"].waitForExistence(timeout: 5))

    alertSettings.scroll(byDeltaX: 0, deltaY: 2_000)
    let attachment = XCTAttachment(screenshot: alertSettings.screenshot())
    attachment.name = "completion-alert-settings.png"
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  func testOverlayAndHUDSurfaces() throws {
    try assertAlertSurface(
      launchArgument: "--ui-test-show-overlay",
      identifier: "completion-overlay",
      attachmentName: "completion-overlay.png",
      expectedTitle: "本轮已结束"
    )
    try assertAlertSurface(
      launchArgument: "--ui-test-show-hud",
      identifier: "completion-hud",
      attachmentName: "completion-hud.png",
      expectedTitle: "本轮已结束"
    )
    try assertAlertSurface(
      launchArgument: "--ui-test-show-notch",
      identifier: "completion-notch-alert",
      attachmentName: "completion-notch-alert.png",
      expectedTitle: "本轮已结束"
    )
  }

  func testCustomAlertHeadlinesAndOverlayAppearance() throws {
    try assertAlertSurface(
      launchArgument: "--ui-test-show-overlay",
      identifier: "completion-overlay",
      attachmentName: "completion-overlay-customized.png",
      expectedTitle: "回来看看新结果",
      additionalArguments: [
        "-alerts.overlay.customHeadline", "回来看看新结果",
        "-alerts.overlay.backgroundStyle", "gradient",
        "-alerts.overlay.gradientStartColor", "#155EEF",
        "-alerts.overlay.gradientEndColor", "#081A46",
        "-alerts.overlay.backgroundOpacity", "0.58",
        "-alerts.overlay.backgroundBlur", "12",
      ]
    )
    try assertAlertSurface(
      launchArgument: "--ui-test-show-hud",
      identifier: "completion-hud",
      attachmentName: "completion-hud-customized.png",
      expectedTitle: "HUD 已准备好",
      additionalArguments: [
        "-alerts.hud.customHeadline", "HUD 已准备好",
      ]
    )
  }

  func testOverlayClickModeIgnoresHoverAndDismissesAfterOneClick() throws {
    let app = localizedApplication()
    app.launchArguments += [
      "--ui-test",
      "--ui-test-show-overlay",
      "-alerts.completion.soundEnabled", "NO",
      "-alerts.systemNotificationEnabled", "NO",
      "-alerts.visualMode", "fullscreen",
      "-alerts.overlayDismissalMode", "click",
      "-alerts.overlayAutoDismiss", "never",
    ]
    app.launch()
    addTeardownBlock { app.terminate() }

    let surface = app.descendants(matching: .any)["completion-overlay"]
    XCTAssertTrue(surface.waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["按任意键、点击或滚动即可关闭"].exists)
    surface.hover()
    Thread.sleep(forTimeInterval: 0.35)
    XCTAssertTrue(surface.exists)
    surface.click()
    XCTAssertTrue(surface.waitForNonExistence(timeout: 2))
  }

  func testOverlayAggregatesMultipleCompletions() throws {
    let app = localizedApplication()
    app.launchArguments += [
      "--ui-test",
      "--ui-test-show-multiple-overlay",
      "-alerts.completion.soundEnabled", "NO",
      "-alerts.systemNotificationEnabled", "NO",
      "-alerts.visualMode", "fullscreen",
      "-alerts.overlayAutoDismiss", "never",
    ]
    app.launch()
    addTeardownBlock { app.terminate() }

    let surface = app.descendants(matching: .any)["completion-overlay"]
    XCTAssertTrue(surface.waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["2 个对话待查看"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["验证多对话叠加"].exists)
    XCTAssertTrue(app.staticTexts["ProjectSprout"].exists)
    XCTAssertTrue(app.staticTexts["另有 1 个对话"].exists)
  }

  private func assertAlertSurface(
    launchArgument: String,
    identifier: String,
    attachmentName: String,
    expectedTitle: String,
    additionalArguments: [String] = []
  ) throws {
    let app = localizedApplication()
    let isOverlay = launchArgument == "--ui-test-show-overlay"
    let isHUD = launchArgument == "--ui-test-show-hud"
    let visualMode = isOverlay ? "fullscreen" : (isHUD ? "hud" : "notch")
    app.launchArguments += [
      "--ui-test",
      launchArgument,
      "-alerts.completion.soundEnabled", "NO",
      "-alerts.systemNotificationEnabled", "NO",
      "-alerts.visualMode", visualMode,
      "-alerts.overlayAutoDismiss", "never",
      "-alerts.overlay.customHeadline", " ",
      "-alerts.hud.customHeadline", " ",
      "-alerts.overlay.backgroundStyle", "solid",
      "-alerts.overlay.solidColor", "#064E3B",
      "-alerts.overlay.backgroundOpacity", "0.72",
      "-alerts.overlay.backgroundBlur", "0",
    ]
    app.launchArguments += additionalArguments
    app.launch()
    addTeardownBlock { app.terminate() }

    let surface = app.descendants(matching: .any)[identifier]
    XCTAssertTrue(surface.waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts[expectedTitle].exists)
    if isOverlay {
      XCTAssertTrue(
        app.descendants(matching: .any)["completion-overlay-privacy-shield"]
          .waitForExistence(timeout: 5)
      )
      XCTAssertTrue(app.staticTexts["检查 CodexDone 提醒样式"].exists)
      XCTAssertTrue(app.staticTexts["CodexDone"].exists)
      XCTAssertTrue(
        app.descendants(matching: .any)["completion-overlay-background-solid"].exists
      )
    } else if isHUD {
      XCTAssertEqual(surface.frame.width, 410, accuracy: 2)
      XCTAssertEqual(surface.frame.height, 82, accuracy: 2)
      XCTAssertTrue(
        app.descendants(matching: .any)["completion-hud-conversation-title"].exists
      )
      XCTAssertTrue(app.staticTexts["检查 CodexDone 提醒样式"].exists)
      XCTAssertTrue(app.descendants(matching: .any)["completion-hud-project"].exists)
      XCTAssertTrue(app.staticTexts["CodexDone"].exists)
    } else {
      let openCodex = app.descendants(matching: .any)["completion-notch-open-codex"]
      XCTAssertFalse(openCodex.exists)
      XCTAssertTrue(
        app.descendants(matching: .any)["completion-notch-conversation-title"].exists
      )
      XCTAssertTrue(app.staticTexts["检查 CodexDone 提醒样式"].exists)
      XCTAssertTrue(app.descendants(matching: .any)["completion-notch-project"].exists)
      XCTAssertTrue(app.staticTexts["CodexDone"].exists)
    }
    let attachment = XCTAttachment(screenshot: surface.screenshot())
    attachment.name = attachmentName
    attachment.lifetime = .keepAlways
    add(attachment)

    if isOverlay {
      surface.click()
      XCTAssertTrue(surface.waitForNonExistence(timeout: 2))
    }
  }
}
