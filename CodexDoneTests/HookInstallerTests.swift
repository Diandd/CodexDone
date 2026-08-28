import AppKit
import Foundation
import Testing

@testable import CodexDone

struct HookInstallerTests {
  @Test("只有不早于当前配置修改时间的 Hook 事件才能确认当前配置")
  func currentConfigurationRequiresCurrentGenerationEvent() {
    let configurationModifiedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let inspection = HookInstallationInspection(
      isInstalled: true,
      helperIsExecutable: true,
      configurationPath: "/tmp/hooks.json",
      configurationModifiedAt: configurationModifiedAt,
      detail: "test"
    )

    #expect(!inspection.isConfirmedByHookEvent(receivedAt: nil))
    #expect(
      !inspection.isConfirmedByHookEvent(
        receivedAt: configurationModifiedAt.addingTimeInterval(-0.001)
      )
    )
    #expect(inspection.isConfirmedByHookEvent(receivedAt: configurationModifiedAt))
    #expect(
      inspection.isConfirmedByHookEvent(
        receivedAt: configurationModifiedAt.addingTimeInterval(0.001)
      )
    )

    let notInstalled = HookInstallationInspection(
      isInstalled: false,
      helperIsExecutable: true,
      configurationPath: "/tmp/hooks.json",
      configurationModifiedAt: configurationModifiedAt,
      detail: "test"
    )
    #expect(!notInstalled.isConfirmedByHookEvent(receivedAt: configurationModifiedAt))
  }

  @Test("Hook 检查返回 hooks.json 的修改时间")
  func inspectionIncludesConfigurationModificationDate() async throws {
    let root = try makeRoot()
    let codexDirectory = root.appendingPathComponent(".codex")
    try FileManager.default.createDirectory(at: codexDirectory, withIntermediateDirectories: true)
    let hooksURL = codexDirectory.appendingPathComponent("hooks.json")
    let helperURL = try makeHealthyHelper(in: root)
    let command = "'\(helperURL.path)'"
    let configuration: [String: Any] = [
      "hooks": [
        "UserPromptSubmit": [["hooks": [["type": "command", "command": command]]]],
        "Stop": [["hooks": [["type": "command", "command": command]]]],
      ]
    ]
    try JSONSerialization.data(withJSONObject: configuration).write(to: hooksURL)
    let expectedModificationDate = Date(timeIntervalSince1970: 1_800_000_123)
    try FileManager.default.setAttributes(
      [.modificationDate: expectedModificationDate],
      ofItemAtPath: hooksURL.path
    )
    let installer = HookInstaller(
      hooksURL: hooksURL,
      configURL: codexDirectory.appendingPathComponent("config.toml"),
      helperURL: helperURL,
      receiptURL: root.appendingPathComponent("receipt.json")
    )

    let inspection = await installer.inspect()

    #expect(inspection.isInstalled)
    let actualModificationDate = try #require(inspection.configurationModifiedAt)
    #expect(abs(actualModificationDate.timeIntervalSince(expectedModificationDate)) < 0.001)
  }

  @Test("安装非破坏合并，卸载只移除自己的命令")
  func mergesAndUninstallsOwnedHooks() async throws {
    let root = try makeRoot()
    let codexDirectory = root.appendingPathComponent(".codex")
    try FileManager.default.createDirectory(at: codexDirectory, withIntermediateDirectories: true)
    let hooksURL = codexDirectory.appendingPathComponent("hooks.json")
    let configURL = codexDirectory.appendingPathComponent("config.toml")
    let helperURL = try makeHealthyHelper(in: root)
    let receiptURL = root.appendingPathComponent("receipt.json")
    let existing: [String: Any] = [
      "description": "keep me",
      "hooks": [
        "Stop": [["hooks": [["type": "command", "command": "'/tmp/existing-hook'"]]]]
      ],
    ]
    try JSONSerialization.data(withJSONObject: existing).write(to: hooksURL)
    let installer = HookInstaller(
      hooksURL: hooksURL,
      configURL: configURL,
      helperURL: helperURL,
      receiptURL: receiptURL
    )

    let installed = try await installer.install()
    #expect(installed.isInstalled)
    let rootAfterInstall = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: hooksURL)) as? [String: Any]
    )
    #expect(rootAfterInstall["description"] as? String == "keep me")
    let hooks = try #require(rootAfterInstall["hooks"] as? [String: Any])
    #expect((hooks["UserPromptSubmit"] as? [[String: Any]])?.count == 1)
    #expect(hooks["PermissionRequest"] == nil)
    #expect((hooks["Stop"] as? [[String: Any]])?.count == 2)
    let backups = try FileManager.default.contentsOfDirectory(
      at: codexDirectory,
      includingPropertiesForKeys: nil
    ).filter { $0.lastPathComponent.hasPrefix("hooks.json.codexdone-backup-") }
    #expect(backups.count == 1)
    let backupMode = try FileManager.default.attributesOfItem(atPath: backups[0].path)[
      .posixPermissions
    ] as? NSNumber
    #expect(backupMode?.intValue == 0o600)

    let uninstalled = try await installer.uninstall()
    #expect(!uninstalled.isInstalled)
    let rootAfterUninstall = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: hooksURL)) as? [String: Any]
    )
    let remainingHooks = try #require(rootAfterUninstall["hooks"] as? [String: Any])
    #expect(remainingHooks["UserPromptSubmit"] == nil)
    #expect(remainingHooks["PermissionRequest"] == nil)
    #expect((remainingHooks["Stop"] as? [[String: Any]])?.count == 1)
  }

  @Test("官方 inline Hooks 表存在时不制造同层双配置")
  func refusesInlineHooksConflict() async throws {
    let root = try makeRoot()
    let codexDirectory = root.appendingPathComponent(".codex")
    try FileManager.default.createDirectory(at: codexDirectory, withIntermediateDirectories: true)
    let configURL = codexDirectory.appendingPathComponent("config.toml")
    try "[[hooks.Stop]]\n".write(to: configURL, atomically: true, encoding: .utf8)
    let installer = HookInstaller(
      hooksURL: codexDirectory.appendingPathComponent("hooks.json"),
      configURL: configURL,
      helperURL: try makeHealthyHelper(in: root),
      receiptURL: root.appendingPathComponent("receipt.json")
    )

    await #expect(throws: HookInstallerError.self) {
      try await installer.install()
    }
  }

  @Test("Codex 的 hooks.state 信任记录不应阻止创建 hooks.json")
  func trustStateDoesNotBlockUserHooksInstallation() async throws {
    let root = try makeRoot()
    let codexDirectory = root.appendingPathComponent(".codex")
    try FileManager.default.createDirectory(at: codexDirectory, withIntermediateDirectories: true)
    let hooksURL = codexDirectory.appendingPathComponent("hooks.json")
    let configURL = codexDirectory.appendingPathComponent("config.toml")
    try """
    [hooks.state]

    [hooks.state."/Users/tester/.codex/hooks.json:stop:0:0"]
    enabled = true
    """.write(to: configURL, atomically: true, encoding: .utf8)
    let installer = HookInstaller(
      hooksURL: hooksURL,
      configURL: configURL,
      helperURL: try makeHealthyHelper(in: root),
      receiptURL: root.appendingPathComponent("receipt.json")
    )

    let inspection = try await installer.install()

    #expect(inspection.isInstalled)
    #expect(FileManager.default.fileExists(atPath: hooksURL.path))
  }

  @Test("重新安装会移除收据记录的旧 Bridge 路径")
  func repairsMovedBridgeWithoutDuplicateOwnedHooks() async throws {
    let root = try makeRoot()
    let codexDirectory = root.appendingPathComponent(".codex")
    try FileManager.default.createDirectory(at: codexDirectory, withIntermediateDirectories: true)
    let hooksURL = codexDirectory.appendingPathComponent("hooks.json")
    let receiptURL = root.appendingPathComponent("receipt.json")
    let oldCommand = "'/Applications/Old/CodexDoneHookBridge'"
    let existing: [String: Any] = [
      "hooks": [
        "UserPromptSubmit": [["hooks": [["type": "command", "command": oldCommand]]]],
        "PermissionRequest": [["hooks": [["type": "command", "command": oldCommand]]]],
        "Stop": [["hooks": [["type": "command", "command": oldCommand]]]],
      ]
    ]
    try JSONSerialization.data(withJSONObject: existing).write(to: hooksURL)
    try JSONEncoder().encode(["commands": [oldCommand]]).write(to: receiptURL)
    let helperURL = try makeHealthyHelper(in: root)
    let installer = HookInstaller(
      hooksURL: hooksURL,
      configURL: codexDirectory.appendingPathComponent("config.toml"),
      helperURL: helperURL,
      receiptURL: receiptURL
    )

    let beforeRepair = await installer.inspect()
    #expect(!beforeRepair.isInstalled)

    _ = try await installer.install()
    let text = try String(contentsOf: hooksURL, encoding: .utf8)
    #expect(!text.contains(oldCommand))
    #expect(text.components(separatedBy: "CodexDoneHookBridge").count - 1 == 2)
    let rootAfterRepair = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: hooksURL)) as? [String: Any]
    )
    let hooksAfterRepair = try #require(rootAfterRepair["hooks"] as? [String: Any])
    #expect(hooksAfterRepair["PermissionRequest"] == nil)
  }

  @Test("仍可执行的自有 Bridge 路径切换后不误报 Hook 未安装")
  func recognizesExecutableOwnedBridgeFromPreviousAppLocation() async throws {
    let root = try makeRoot()
    let codexDirectory = root.appendingPathComponent(".codex")
    let previousAppDirectory = root.appendingPathComponent("PreviousApp")
    let currentAppDirectory = root.appendingPathComponent("CurrentApp")
    try FileManager.default.createDirectory(
      at: codexDirectory,
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: previousAppDirectory,
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: currentAppDirectory,
      withIntermediateDirectories: true
    )
    let hooksURL = codexDirectory.appendingPathComponent("hooks.json")
    let receiptURL = root.appendingPathComponent("receipt.json")
    let previousHelperURL = try makeHealthyHelper(in: previousAppDirectory)
    let currentHelperURL = try makeHealthyHelper(in: currentAppDirectory)
    let previousCommand = "'\(previousHelperURL.path)'"
    let configuration: [String: Any] = [
      "hooks": [
        "UserPromptSubmit": [
          ["hooks": [["type": "command", "command": previousCommand]]]
        ],
        "Stop": [
          ["hooks": [["type": "command", "command": previousCommand]]]
        ],
      ]
    ]
    try JSONSerialization.data(withJSONObject: configuration).write(to: hooksURL)
    try JSONEncoder().encode(["commands": [previousCommand]]).write(to: receiptURL)
    let installer = HookInstaller(
      hooksURL: hooksURL,
      configURL: codexDirectory.appendingPathComponent("config.toml"),
      helperURL: currentHelperURL,
      receiptURL: receiptURL
    )

    let inspection = await installer.inspect()

    #expect(inspection.isInstalled)
    #expect(inspection.helperIsExecutable)
    #expect(inspection.handlerCommand == previousCommand)
  }

  @Test("安装时复制 Bridge 到稳定路径并只写入稳定命令")
  func installsBridgeAtStableApplicationSupportPath() async throws {
    let root = try makeRoot()
    let codexDirectory = root.appendingPathComponent(".codex")
    let bundleDirectory = root.appendingPathComponent("Bundle")
    let supportDirectory = root.appendingPathComponent("ApplicationSupport")
    try FileManager.default.createDirectory(
      at: codexDirectory,
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: bundleDirectory,
      withIntermediateDirectories: true
    )
    let bundledHelperURL = try makeHealthyHelper(in: bundleDirectory)
    let installedHelperURL = supportDirectory.appendingPathComponent("CodexDoneHookBridge")
    let hooksURL = codexDirectory.appendingPathComponent("hooks.json")
    let installer = HookInstaller(
      hooksURL: hooksURL,
      configURL: codexDirectory.appendingPathComponent("config.toml"),
      helperURL: bundledHelperURL,
      installedHelperURL: installedHelperURL,
      receiptURL: root.appendingPathComponent("receipt.json")
    )

    let inspection = try await installer.install()

    #expect(inspection.isInstalled)
    #expect(inspection.handlerCommand == "'\(installedHelperURL.path)'")
    #expect(FileManager.default.isExecutableFile(atPath: installedHelperURL.path))
    let installedMode =
      try FileManager.default.attributesOfItem(
        atPath: installedHelperURL.path
      )[.posixPermissions] as? NSNumber
    #expect(installedMode?.intValue == 0o700)
    let text = try String(contentsOf: hooksURL, encoding: .utf8)
    #expect(text.contains(installedHelperURL.path))
    #expect(!text.contains(bundledHelperURL.path))
  }

  @Test("修复和卸载会清除旧版 CodexDone 的非 MVP Hook")
  func removesHistoricalOwnedHandlersFromEveryEvent() async throws {
    let root = try makeRoot()
    let codexDirectory = root.appendingPathComponent(".codex")
    try FileManager.default.createDirectory(at: codexDirectory, withIntermediateDirectories: true)
    let hooksURL = codexDirectory.appendingPathComponent("hooks.json")
    let receiptURL = root.appendingPathComponent("receipt.json")
    let oldCommand = "'/Applications/Old/CodexDoneHookBridge'"
    let thirdPartyCommand = "'/tmp/keep-subagent-hook'"
    let existing: [String: Any] = [
      "hooks": [
        "SubagentStop": [[
          "hooks": [
            ["type": "command", "command": oldCommand],
            ["type": "command", "command": thirdPartyCommand],
          ]
        ]]
      ]
    ]
    try JSONSerialization.data(withJSONObject: existing).write(to: hooksURL)
    try JSONEncoder().encode(["commands": [oldCommand]]).write(to: receiptURL)
    let installer = HookInstaller(
      hooksURL: hooksURL,
      configURL: codexDirectory.appendingPathComponent("config.toml"),
      helperURL: try makeHealthyHelper(in: root),
      receiptURL: receiptURL
    )

    let installed = try await installer.install()
    #expect(installed.isInstalled)
    var rootObject = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: hooksURL)) as? [String: Any]
    )
    var hooks = try #require(rootObject["hooks"] as? [String: Any])
    let subagentGroups = try #require(hooks["SubagentStop"] as? [[String: Any]])
    let subagentHandlers = try #require(subagentGroups.first?["hooks"] as? [[String: Any]])
    #expect(subagentHandlers.map { $0["command"] as? String } == [thirdPartyCommand])

    _ = try await installer.uninstall()
    rootObject = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: hooksURL)) as? [String: Any]
    )
    hooks = try #require(rootObject["hooks"] as? [String: Any])
    #expect(hooks["UserPromptSubmit"] == nil)
    #expect(hooks["PermissionRequest"] == nil)
    #expect(hooks["Stop"] == nil)
    #expect(hooks["SubagentStop"] != nil)
    let text = try String(contentsOf: hooksURL, encoding: .utf8)
    #expect(!text.contains(oldCommand))
    #expect(text.contains(thirdPartyCommand))
  }

  private func makeRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  private func makeHealthyHelper(in root: URL) throws -> URL {
    let url = root.appendingPathComponent("CodexDoneHookBridge")
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
  }
}

struct SystemIntegrationServiceTests {
  @Test @MainActor
  func codexResolutionUsesRegisteredBundleThenCodexOnlyPaths() {
    let registeredURL = URL(fileURLWithPath: "/Volumes/Apps/Codex.app")
    let homeURL = URL(fileURLWithPath: "/Users/tester", isDirectory: true)
    let registeredResult = SystemIntegrationService.resolveCodexApplicationURL(
      registeredApplicationURL: registeredURL,
      homeDirectoryURL: homeURL,
      fileExists: { $0 == registeredURL.path }
    )
    #expect(SystemIntegrationService.codexBundleIdentifier == "com.openai.codex")
    #expect(registeredResult == registeredURL)

    let userCodexURL = homeURL
      .appendingPathComponent("Applications", isDirectory: true)
      .appendingPathComponent("Codex.app", isDirectory: true)
    let fallbackResult = SystemIntegrationService.resolveCodexApplicationURL(
      registeredApplicationURL: nil,
      homeDirectoryURL: homeURL,
      fileExists: { $0 == userCodexURL.path }
    )
    #expect(fallbackResult == userCodexURL)

    var inspectedFallbackPaths: [String] = []
    let missingResult = SystemIntegrationService.resolveCodexApplicationURL(
      registeredApplicationURL: nil,
      homeDirectoryURL: homeURL,
      fileExists: {
        inspectedFallbackPaths.append($0)
        return false
      }
    )
    #expect(missingResult == nil)
    #expect(
      inspectedFallbackPaths == [
        "/Applications/Codex.app",
        "/Users/tester/Applications/Codex.app",
      ]
    )
  }

  @Test @MainActor
  func appServerResolutionSupportsRegisteredAndCurrentDesktopBundleNames() {
    let registeredApplication = URL(fileURLWithPath: "/Volumes/Apps/ChatGPT.app")
    let registeredExecutable = registeredApplication
      .appendingPathComponent("Contents/Resources/codex")
    let homeURL = URL(fileURLWithPath: "/Users/tester", isDirectory: true)

    let registeredResult = SystemIntegrationService.resolveCodexAppServerExecutableURL(
      registeredApplicationURL: registeredApplication,
      homeDirectoryURL: homeURL,
      isExecutable: { $0 == registeredExecutable.path }
    )
    #expect(registeredResult == registeredExecutable)

    let fallbackExecutable = URL(fileURLWithPath: "/Applications/ChatGPT.app")
      .appendingPathComponent("Contents/Resources/codex")
    let fallbackResult = SystemIntegrationService.resolveCodexAppServerExecutableURL(
      registeredApplicationURL: nil,
      homeDirectoryURL: homeURL,
      isExecutable: { $0 == fallbackExecutable.path }
    )
    #expect(fallbackResult == fallbackExecutable)
  }
}

struct ApplicationInstanceLockTests {
  @Test("同一锁路径一次只允许一个应用实例")
  func lockIsExclusiveUntilReleased() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("CodexDoneInstanceLockTests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let lockURL = root.appendingPathComponent("instance.lock")
    let first = ApplicationInstanceLock(lockURL: lockURL)
    let second = ApplicationInstanceLock(lockURL: lockURL)

    #expect(first.acquire())
    #expect(!second.acquire())
    first.release()
    #expect(second.acquire())

    let attributes = try FileManager.default.attributesOfItem(atPath: lockURL.path)
    let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
    #expect(permissions.intValue & 0o777 == 0o600)
  }
}

struct StatusItemPopoverLayoutTests {
  @Test("Popover 展开时只冻结标题，图标始终跟随当前未读状态")
  func expandedPopoverFreezesOnlyTitle() {
    #expect(StatusItemPopoverLayout.statusItemLength == NSStatusItem.variableLength)
    #expect(
      StatusItemPopoverLayout.statusItemTitle(
        unreadCount: 2,
        showsUnreadCount: true
      ) == " 2"
    )
    #expect(
      StatusItemPopoverLayout.statusItemTitle(
        unreadCount: 2,
        showsUnreadCount: false
      ) == ""
    )
    #expect(
      StatusItemPopoverLayout.statusItemTitle(
        unreadCount: 0,
        showsUnreadCount: true
      ) == ""
    )
    #expect(
      StatusItemPopoverLayout.displayedStatusItemTitle(
        current: "",
        expandedTitle: " 2"
      ) == " 2"
    )
    #expect(
      StatusItemPopoverLayout.displayedStatusItemTitle(
        current: " 1",
        expandedTitle: nil
      ) == " 1"
    )
    #expect(StatusItemPopoverLayout.displayedHasUnread(current: true))
    #expect(!StatusItemPopoverLayout.displayedHasUnread(current: false))
  }

  @Test("状态栏待查看图标只把中央对号改为绿色")
  @MainActor
  func unreadStatusItemUsesIndependentGreenCheckLayer() throws {
    #expect(NSImage(named: StatusItemIconRenderer.outlineAssetName) != nil)
    #expect(NSImage(named: StatusItemIconRenderer.checkAssetName) != nil)
    #expect(
      NSImage(
        systemSymbolName: StatusItemIconRenderer.awaySystemSymbolName,
        accessibilityDescription: nil
      ) != nil
    )

    let idle = StatusItemIconRenderer.image(
      hasUnread: false,
      isHighlighted: false,
      accessibilityDescription: "idle"
    )
    let unread = StatusItemIconRenderer.image(
      hasUnread: true,
      isHighlighted: false,
      accessibilityDescription: "unread"
    )

    #expect(idle.size == StatusItemIconRenderer.size)
    #expect(unread.size == StatusItemIconRenderer.size)
    #expect(!idle.isTemplate)
    #expect(!unread.isTemplate)
    #expect(try greenPixelCount(in: idle) == 0)
    #expect(try greenPixelCount(in: unread) > 0)
  }

  @Test("智能提醒跨过离开阈值后把状态栏中央对号切换为小人")
  @MainActor
  func smartAwayStateUsesWalkingFigureInStatusItem() throws {
    let configuration = SmartAlertConfiguration.defaultConfiguration
    #expect(
      StatusItemCenterSymbol.resolved(
        configuredMode: .smart,
        smartConfiguration: configuration,
        idleSeconds: 59.9
      ) == .checkmark
    )
    #expect(
      StatusItemCenterSymbol.resolved(
        configuredMode: .smart,
        smartConfiguration: configuration,
        idleSeconds: 60
      ) == .away
    )
    #expect(
      StatusItemCenterSymbol.resolved(
        configuredMode: .fullscreen,
        smartConfiguration: configuration,
        idleSeconds: 600
      ) == .checkmark
    )

    let active = StatusItemIconRenderer.image(
      hasUnread: false,
      centerSymbol: .checkmark,
      isHighlighted: false,
      accessibilityDescription: "active"
    )
    let away = StatusItemIconRenderer.image(
      hasUnread: false,
      centerSymbol: .away,
      isHighlighted: false,
      accessibilityDescription: "away"
    )
    let unreadAway = StatusItemIconRenderer.image(
      hasUnread: true,
      centerSymbol: .away,
      isHighlighted: false,
      accessibilityDescription: "away unread"
    )

    let activeData = try #require(active.tiffRepresentation)
    let awayData = try #require(away.tiffRepresentation)
    #expect(activeData != awayData)
    #expect(try greenPixelCount(in: away) == 0)
    #expect(try greenPixelCount(in: unreadAway) > 0)

    let checkDestination = StatusItemIconRenderer.centerDestinationRect(
      .checkmark,
      sourceSize: StatusItemIconRenderer.size,
      canvas: NSRect(origin: .zero, size: StatusItemIconRenderer.size)
    )
    #expect(
      checkDestination.midX
        == StatusItemIconRenderer.size.width / 2
          + StatusItemIconRenderer.checkmarkOpticalOffset.x
    )
    #expect(checkDestination.midY == StatusItemIconRenderer.size.height / 2)

    let destination = StatusItemIconRenderer.centerDestinationRect(
      .away,
      sourceSize: NSSize(width: 10, height: 14),
      canvas: NSRect(origin: .zero, size: StatusItemIconRenderer.size)
    )
    #expect(
      destination.midX
        == StatusItemIconRenderer.size.width / 2
          + StatusItemIconRenderer.awaySymbolOpticalOffset.x
    )
    #expect(destination.midY == StatusItemIconRenderer.size.height / 2)
    #expect(StatusItemIconRenderer.awaySymbolOpticalOffset.x == 0.25)
    #expect(destination.width <= StatusItemIconRenderer.awaySymbolMaximumSize.width)
    #expect(destination.height <= StatusItemIconRenderer.awaySymbolMaximumSize.height)
  }

  private func greenPixelCount(in image: NSImage) throws -> Int {
    let data = try #require(image.tiffRepresentation)
    let bitmap = try #require(NSBitmapImageRep(data: data))
    var count = 0
    for y in 0..<bitmap.pixelsHigh {
      for x in 0..<bitmap.pixelsWide {
        guard
          let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
          color.alphaComponent > 0.1
        else { continue }
        if color.greenComponent > 0.35,
          color.greenComponent > color.redComponent * 1.2,
          color.greenComponent > color.blueComponent * 1.2
        {
          count += 1
        }
      }
    }
    return count
  }

}
