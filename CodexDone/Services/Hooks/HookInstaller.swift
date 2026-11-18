import Foundation

struct HookInstallationInspection: Equatable, Sendable {
  let isInstalled: Bool
  let helperIsExecutable: Bool
  let helperRequiresUpdate: Bool
  let configurationPath: String
  let configurationModifiedAt: Date?
  let handlerCommand: String?
  let detail: String

  init(
    isInstalled: Bool,
    helperIsExecutable: Bool,
    helperRequiresUpdate: Bool = false,
    configurationPath: String,
    configurationModifiedAt: Date? = nil,
    handlerCommand: String? = nil,
    detail: String
  ) {
    self.isInstalled = isInstalled
    self.helperIsExecutable = helperIsExecutable
    self.helperRequiresUpdate = helperRequiresUpdate
    self.configurationPath = configurationPath
    self.configurationModifiedAt = configurationModifiedAt
    self.handlerCommand = handlerCommand
    self.detail = detail
  }

  /// A persisted receipt from an earlier hooks.json generation is not evidence
  /// that the currently installed command has ever run.
  func isConfirmedByHookEvent(receivedAt: Date?) -> Bool {
    guard
      isInstalled,
      let configurationModifiedAt,
      let receivedAt
    else {
      return false
    }
    return receivedAt >= configurationModifiedAt
  }
}

enum HookInstallerError: LocalizedError {
  case helperMissing
  case malformedConfiguration
  case incompatibleHookShape
  case inlineHooksAlreadyConfigured
  case healthCheckFailed

  var errorDescription: String? {
    switch self {
    case .helperMissing:
      L10n.text("应用内的 Hook Bridge 不存在或不可执行。")
    case .malformedConfiguration:
      L10n.text("现有配置不是有效的 JSON 对象，无法合并。")
    case .incompatibleHookShape:
      L10n.text("现有 Hook 配置结构无法安全合并；为避免覆盖，未做任何修改。")
    case .inlineHooksAlreadyConfigured:
      L10n.text("config.toml 已包含 inline Hooks。请先迁移为 hooks.json，再由 CodexDone 合并。")
    case .healthCheckFailed:
      L10n.text("Hook Bridge 健康检查失败，未安装配置。")
    }
  }
}

actor HookInstaller {
  private struct Receipt: Codable {
    var commands: [String]
  }

  private let source: AgentSource
  private let extensionTemplateURL: URL?
  private let hooksURL: URL
  private let configURL: URL
  private let bundledHelperURL: URL
  private let installedHelperURL: URL
  private let receiptURL: URL
  private let fileManager: FileManager

  init(
    source: AgentSource = .codex,
    hooksURL: URL? = nil,
    configURL: URL = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".codex/config.toml"),
    helperURL: URL = Bundle.main.bundleURL
      .appendingPathComponent("Contents/Helpers/CodexDoneHookBridge"),
    installedHelperURL: URL? = nil,
    receiptURL: URL? = nil,
    extensionTemplateURL: URL? = Bundle.main.url(forResource: "pi-extension", withExtension: "ts"),
    fileManager: FileManager = .default
  ) {
    self.source = source
    self.extensionTemplateURL = extensionTemplateURL
    let home = fileManager.homeDirectoryForCurrentUser
    let path: String
    switch source {
    case .codex: path = ".codex/hooks.json"
    case .claude: path = ".claude/settings.json"
    case .pi: path = ".pi/agent/extensions/codexdone.ts"
    }
    self.hooksURL = hooksURL ?? home.appendingPathComponent(path)
    self.configURL = configURL
    bundledHelperURL = helperURL
    self.installedHelperURL = installedHelperURL ?? helperURL
    self.receiptURL = receiptURL ?? HookRuntimePaths.applicationSupportRoot
      .appendingPathComponent(source == .codex ? "hook-installation.json" : "\(source.rawValue)-installation.json")
    self.fileManager = fileManager
  }

  func inspect() -> HookInstallationInspection {
    if source == .pi { return inspectPi() }
    let bundledHelperIsExecutable = fileManager.isExecutableFile(
      atPath: bundledHelperURL.path
    )
    let commands = ownedCommands()
    let preferredCommand = handlerCommand(for: installedHelperURL)
    let configurationModifiedAt = hooksConfigurationModificationDate()
    guard
      let root = try? readRoot(),
      let hooks = root["hooks"] as? [String: Any]
    else {
      return HookInstallationInspection(
        isInstalled: false,
        helperIsExecutable: bundledHelperIsExecutable,
        configurationPath: hooksURL.path,
        configurationModifiedAt: configurationModifiedAt,
        handlerCommand: preferredCommand,
        detail: fileManager.fileExists(atPath: hooksURL.path)
          ? L10n.text("Hook 配置无法读取")
          : L10n.text("尚未安装")
      )
    }
    let requiredEventNames = Set(DesktopHookEventName.allCases.map(\.rawValue))
    let configuredCommand = configuredOwnedCommand(
      in: hooks,
      commands: commands,
      preferredCommand: preferredCommand
    )
    let hasUnexpectedOwnedHandler = hooks.contains { eventName, value in
      let counts = ownedCommandCounts(in: value, commands: commands)
      guard !counts.isEmpty else { return false }
      guard
        requiredEventNames.contains(eventName),
        let configuredCommand
      else {
        return true
      }
      return counts.count != 1 || counts[configuredCommand] != 1
    }
    let installed = configuredCommand != nil && !hasUnexpectedOwnedHandler
    let helperRequiresUpdate = configuredCommand.map(helperNeedsUpdate(for:)) ?? false
    return HookInstallationInspection(
      isInstalled: installed,
      helperIsExecutable: bundledHelperIsExecutable,
      helperRequiresUpdate: installed && helperRequiresUpdate,
      configurationPath: hooksURL.path,
      configurationModifiedAt: configurationModifiedAt,
      handlerCommand: configuredCommand ?? preferredCommand,
      detail: installed
        ? (helperRequiresUpdate
          ? L10n.text("检测到旧版 CodexDone Hook，需要修复")
          : (source == .codex ? L10n.text("已写入；首次运行需在 Codex 中审核信任") : L10n.text("已安装，重新启动会话后生效")))
        : (hasUnexpectedOwnedHandler
          ? L10n.text("检测到旧版 CodexDone Hook，需要修复")
          : L10n.text("尚未完整安装"))
    )
  }

  func install() throws -> HookInstallationInspection {
    guard fileManager.isExecutableFile(atPath: bundledHelperURL.path) else {
      throw HookInstallerError.helperMissing
    }
    try installBundledHelperIfNeeded()
    guard runHealthCheck(executableURL: installedHelperURL) else {
      throw HookInstallerError.healthCheckFailed
    }
    if source == .pi {
      try verifyPiExtensionOwnership()
      let contents = try piExtensionContents()
      try backupExistingConfiguration()
      try fileManager.createDirectory(at: hooksURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      try contents.write(to: hooksURL, atomically: true, encoding: .utf8)
      return inspect()
    }
    if source == .codex, hasInlineHooks(), !fileManager.fileExists(atPath: hooksURL.path) {
      throw HookInstallerError.inlineHooksAlreadyConfigured
    }

    var root = try readRoot()
    var hooks: [String: Any]
    if let existing = root["hooks"] {
      guard let dictionary = existing as? [String: Any] else {
        throw HookInstallerError.incompatibleHookShape
      }
      hooks = dictionary
    } else {
      hooks = [:]
    }

    let command = handlerCommand(for: installedHelperURL)
    let previouslyOwnedCommands = ownedCommands()
    hooks = removingOwnedCommands(fromAllEvents: hooks, commands: previouslyOwnedCommands)
    for eventName in DesktopHookEventName.allCases {
      var groups: [[String: Any]]
      if let existing = hooks[eventName.rawValue] {
        guard let array = existing as? [[String: Any]] else {
          throw HookInstallerError.incompatibleHookShape
        }
        groups = array
      } else {
        groups = []
      }
      groups.append([
        "hooks": [
          [
            "type": "command",
            "command": command,
            "timeout": 5,
          ]
        ]
      ])
      hooks[eventName.rawValue] = groups
    }
    root["hooks"] = hooks

    try backupExistingConfiguration()
    try writeJSONObject(root, to: hooksURL)
    try writeReceipt(
      Receipt(commands: Array(previouslyOwnedCommands.union([command])).sorted())
    )
    return inspect()
  }

  func uninstall() throws -> HookInstallationInspection {
    if source == .pi {
      try verifyPiExtensionOwnership()
      if fileManager.fileExists(atPath: hooksURL.path) {
        try backupExistingConfiguration()
        try fileManager.removeItem(at: hooksURL)
      }
      return inspect()
    }
    guard fileManager.fileExists(atPath: hooksURL.path) else {
      try? fileManager.removeItem(at: receiptURL)
      return inspect()
    }
    var root = try readRoot()
    guard var hooks = root["hooks"] as? [String: Any] else {
      throw HookInstallerError.incompatibleHookShape
    }
    let commands = ownedCommands()

    hooks = removingOwnedCommands(fromAllEvents: hooks, commands: commands)
    if hooks.isEmpty {
      root.removeValue(forKey: "hooks")
    } else {
      root["hooks"] = hooks
    }

    try backupExistingConfiguration()
    if root.isEmpty {
      try fileManager.removeItem(at: hooksURL)
    } else {
      try writeJSONObject(root, to: hooksURL)
    }
    try? fileManager.removeItem(at: receiptURL)
    if installedHelperURL.standardizedFileURL != bundledHelperURL.standardizedFileURL {
      try? fileManager.removeItem(at: installedHelperURL)
    }
    return inspect()
  }

  private func readRoot() throws -> [String: Any] {
    guard fileManager.fileExists(atPath: hooksURL.path) else { return [:] }
    let data = try Data(contentsOf: hooksURL)
    guard
      let object = try? JSONSerialization.jsonObject(with: data),
      let root = object as? [String: Any]
    else {
      throw HookInstallerError.malformedConfiguration
    }
    return root
  }

  private func hasInlineHooks() -> Bool {
    guard let contents = try? String(contentsOf: configURL, encoding: .utf8) else {
      return false
    }
    return contents.split(whereSeparator: \.isNewline).contains { line in
      var header = line.trimmingCharacters(in: .whitespaces)
      if let commentStart = header.firstIndex(of: "#") {
        header = String(header[..<commentStart]).trimmingCharacters(in: .whitespaces)
      }
      while header.hasPrefix("["), header.hasSuffix("]") {
        header.removeFirst()
        header.removeLast()
        header = header.trimmingCharacters(in: .whitespaces)
      }
      guard header == "hooks" || header.hasPrefix("hooks.") else { return false }

      // Codex persists review/enablement receipts under hooks.state. Those
      // records are metadata for hooks.json, not a second inline definition.
      return header != "hooks.state" && !header.hasPrefix("hooks.state.")
    }
  }

  private func hooksConfigurationModificationDate() -> Date? {
    guard
      let attributes = try? fileManager.attributesOfItem(atPath: hooksURL.path),
      let modificationDate = attributes[.modificationDate] as? Date
    else {
      return nil
    }
    return modificationDate
  }

  private func installBundledHelperIfNeeded() throws {
    guard installedHelperURL.standardizedFileURL != bundledHelperURL.standardizedFileURL
    else {
      return
    }
    let directory = installedHelperURL.deletingLastPathComponent()
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    let staging = directory.appendingPathComponent(".bridge-\(UUID().uuidString)")
    defer { try? fileManager.removeItem(at: staging) }
    try fileManager.copyItem(at: bundledHelperURL, to: staging)
    try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: staging.path)
    if fileManager.fileExists(atPath: installedHelperURL.path) {
      _ = try fileManager.replaceItemAt(installedHelperURL, withItemAt: staging)
    } else {
      try fileManager.moveItem(at: staging, to: installedHelperURL)
    }
    try fileManager.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: installedHelperURL.path
    )
  }

  private func runHealthCheck(executableURL: URL) -> Bool {
    let process = Process()
    process.executableURL = executableURL
    process.arguments = ["--health-check"]
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
      try process.run()
      process.waitUntilExit()
      return process.terminationStatus == 0
    } catch {
      return false
    }
  }

  private func backupExistingConfiguration() throws {
    guard fileManager.fileExists(atPath: hooksURL.path) else { return }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
    let backup = hooksURL.deletingLastPathComponent().appendingPathComponent(
      "\(hooksURL.lastPathComponent).codexdone-backup-\(formatter.string(from: .now))-\(UUID().uuidString.prefix(8))"
    )
    try fileManager.copyItem(at: hooksURL, to: backup)
    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
  }

  private func writeJSONObject(_ object: [String: Any], to url: URL) throws {
    let parent = url.deletingLastPathComponent()
    try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
    let data = try JSONSerialization.data(
      withJSONObject: object,
      options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    )
    try data.write(to: url, options: .atomic)
    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }

  private func writeReceipt(_ receipt: Receipt) throws {
    try fileManager.createDirectory(
      at: receiptURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try fileManager.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: receiptURL.deletingLastPathComponent().path
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    try encoder.encode(receipt).write(to: receiptURL, options: .atomic)
    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: receiptURL.path)
  }

  private func ownedCommands() -> Set<String> {
    var commands: Set<String> = [
      handlerCommand(for: bundledHelperURL),
      handlerCommand(for: installedHelperURL),
    ]
    if let data = try? Data(contentsOf: receiptURL),
      let receipt = try? JSONDecoder().decode(Receipt.self, from: data)
    {
      commands.formUnion(receipt.commands)
    }
    return commands
  }

  private func configuredOwnedCommand(
    in hooks: [String: Any],
    commands: Set<String>,
    preferredCommand: String
  ) -> String? {
    let perEventCounts = DesktopHookEventName.allCases.map { eventName in
      ownedCommandCounts(in: hooks[eventName.rawValue], commands: commands)
    }
    guard let firstCounts = perEventCounts.first else { return nil }
    var candidates = Set(
      firstCounts.compactMap { command, count in
        count == 1 ? command : nil
      })
    for counts in perEventCounts.dropFirst() {
      candidates.formIntersection(
        counts.compactMap { command, count in count == 1 ? command : nil }
      )
    }
    candidates = Set(candidates.filter(isExecutableOwnedCommand))
    if candidates.contains(preferredCommand) { return preferredCommand }
    return candidates.sorted().first
  }

  private func ownedCommandCounts(
    in value: Any?,
    commands: Set<String>
  ) -> [String: Int] {
    guard let groups = value as? [[String: Any]] else { return [:] }
    var counts: [String: Int] = [:]
    for group in groups {
      guard let handlers = group["hooks"] as? [[String: Any]] else { continue }
      for handler in handlers {
        guard
          let command = handler["command"] as? String,
          commands.contains(command)
        else {
          continue
        }
        counts[command, default: 0] += 1
      }
    }
    return counts
  }

  private func isExecutableOwnedCommand(_ command: String) -> Bool {
    guard let path = executablePath(from: command) else { return false }
    return fileManager.isExecutableFile(atPath: path)
  }

  private func helperNeedsUpdate(for command: String) -> Bool {
    guard
      let path = executablePath(from: command),
      fileManager.isExecutableFile(atPath: path),
      fileManager.isExecutableFile(atPath: bundledHelperURL.path)
    else {
      return false
    }
    if URL(fileURLWithPath: path).standardizedFileURL == bundledHelperURL.standardizedFileURL {
      return false
    }
    return !fileManager.contentsEqual(atPath: path, andPath: bundledHelperURL.path)
  }

  private func executablePath(from command: String) -> String? {
    let suffix = source == .codex ? "" : " --source \(source.rawValue)"
    let command = !suffix.isEmpty && command.hasSuffix(suffix)
      ? String(command.dropLast(suffix.count)) : command
    guard
      command.hasPrefix("'"),
      command.hasSuffix("'"),
      command.count >= 2
    else {
      return nil
    }
    let path = String(command.dropFirst().dropLast())
    return path.contains("'") ? nil : path
  }

  private func containsOwnedCommand(in value: Any?, commands: Set<String>) -> Bool {
    guard let groups = value as? [[String: Any]] else { return false }
    return containsOwnedCommand(in: groups, commands: commands)
  }

  private func commandCount(in value: Any?, command: String) -> Int {
    guard let groups = value as? [[String: Any]] else { return 0 }
    return groups.reduce(into: 0) { count, group in
      guard let handlers = group["hooks"] as? [[String: Any]] else { return }
      count += handlers.lazy.filter { $0["command"] as? String == command }.count
    }
  }

  private func containsOwnedCommand(
    in groups: [[String: Any]],
    commands: Set<String>
  ) -> Bool {
    groups.contains { group in
      guard let handlers = group["hooks"] as? [[String: Any]] else { return false }
      return handlers.contains { handler in
        guard let command = handler["command"] as? String else { return false }
        return commands.contains(command)
      }
    }
  }

  private func removingOwnedCommands(
    from groups: [[String: Any]],
    commands: Set<String>
  ) -> [[String: Any]] {
    groups.compactMap { group in
      guard var handlers = group["hooks"] as? [[String: Any]] else { return group }
      handlers.removeAll { handler in
        guard let command = handler["command"] as? String else { return false }
        return commands.contains(command)
      }
      guard !handlers.isEmpty else { return nil }
      var updated = group
      updated["hooks"] = handlers
      return updated
    }
  }

  private func removingOwnedCommands(
    fromAllEvents hooks: [String: Any],
    commands: Set<String>
  ) -> [String: Any] {
    var updatedHooks = hooks
    for (eventName, value) in hooks {
      guard let groups = value as? [[String: Any]] else { continue }
      let updatedGroups = removingOwnedCommands(from: groups, commands: commands)
      if updatedGroups.isEmpty {
        updatedHooks.removeValue(forKey: eventName)
      } else {
        updatedHooks[eventName] = updatedGroups
      }
    }
    return updatedHooks
  }

  private func handlerCommand(for url: URL) -> String {
    shellQuoted(url.path) + (source == .codex ? "" : " --source \(source.rawValue)")
  }

  private func verifyPiExtensionOwnership() throws {
    guard fileManager.fileExists(atPath: hooksURL.path) else { return }
    let contents = try String(contentsOf: hooksURL, encoding: .utf8)
    guard contents.hasPrefix("// Installed by CodexDone.") else {
      throw HookInstallerError.incompatibleHookShape
    }
  }

  private func piExtensionContents() throws -> String {
    guard let extensionTemplateURL else { throw HookInstallerError.helperMissing }
    let template = try String(contentsOf: extensionTemplateURL, encoding: .utf8)
    let path = String(data: try JSONEncoder().encode(installedHelperURL.path), encoding: .utf8)!
    return template.replacingOccurrences(of: "__CODEXDONE_HELPER__", with: path)
  }

  private func inspectPi() -> HookInstallationInspection {
    let installed = (try? String(contentsOf: hooksURL, encoding: .utf8))
    let expected = try? piExtensionContents()
    let executable = fileManager.isExecutableFile(atPath: installedHelperURL.path)
    let isInstalled = installed?.hasPrefix("// Installed by CodexDone.") == true && executable
    return HookInstallationInspection(
      isInstalled: isInstalled,
      helperIsExecutable: fileManager.isExecutableFile(atPath: bundledHelperURL.path),
      helperRequiresUpdate: installed != nil && (installed != expected ||
        !fileManager.contentsEqual(atPath: installedHelperURL.path, andPath: bundledHelperURL.path)),
      configurationPath: hooksURL.path,
      configurationModifiedAt: hooksConfigurationModificationDate(),
      detail: isInstalled ? L10n.text("已安装，在 Pi 中运行 /reload 生效") : L10n.text("尚未安装")
    )
  }

  private func shellQuoted(_ path: String) -> String {
    "'\(path.replacingOccurrences(of: "'", with: "'\\''"))'"
  }
}
