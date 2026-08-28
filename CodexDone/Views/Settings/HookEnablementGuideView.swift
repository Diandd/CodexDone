import AppKit
import SwiftUI

struct HookEnablementGuideView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(AppEnvironment.self) private var environment
  @State private var platform = HookGuidePlatform.desktop

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      setupActions
      Divider()

      Group {
        switch platform {
        case .desktop:
          desktopGuide
        case .cli:
          cliGuide
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .padding(.horizontal, 20)
      .padding(.vertical, 16)

      Divider()
      footer
    }
    .frame(width: 620, height: 430)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("hook-enablement-guide")
    .task { await environment.refreshHealth() }
  }

  private var header: some View {
    HStack(spacing: 18) {
      VStack(alignment: .leading, spacing: 3) {
        Text("启用 Hook")
          .font(.title2.bold())
        Text("在 Codex 中信任并启用两条 Hook")
          .font(.callout)
          .foregroundStyle(.secondary)
      }

      Spacer()

      Button {
        dismiss()
      } label: {
        Image(systemName: "xmark")
      }
      .buttonStyle(.plain)
      .font(.system(size: 15, weight: .semibold))
      .foregroundStyle(.secondary)
      .help("关闭")
      .accessibilityLabel("关闭教程")
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 12)
  }

  private var setupActions: some View {
    hookSetupAction
      .padding(.horizontal, 20)
      .padding(.vertical, 12)
  }

  private var hookSetupAction: some View {
    setupAction(
      symbol: environment.hookConnectionSymbolName,
      symbolColor: hookStatusColor,
      title: "Hooks",
      status: environment.hookInspection.isInstalled
        ? compactHookStatus
        : L10n.text("尚未安装")
    ) {
      HStack(spacing: 8) {
        Button {
          Task { await environment.refreshHealth() }
        } label: {
          Image(systemName: "arrow.clockwise")
        }
        .help("刷新状态")
        .accessibilityLabel("刷新状态")
        .accessibilityIdentifier("hook-guide-refresh-status")
        .disabled(
          environment.isHookOperationInProgress || environment.isHookStatusRefreshing
            || !environment.hookInspection.isInstalled
        )

        Button(
          environment.hookInspection.isInstalled
            ? L10n.text("重新安装")
            : L10n.text("安装 Hooks")
        ) {
          Task { await environment.installHooks() }
        }
        .disabled(environment.isHookOperationInProgress)
        .fixedSize()
        .accessibilityIdentifier("hook-guide-install-hooks")
      }
    }
  }

  private func setupAction<Action: View>(
    symbol: String,
    symbolColor: Color,
    title: String,
    status: String,
    @ViewBuilder action: () -> Action
  ) -> some View {
    HStack(spacing: 10) {
      Image(systemName: symbol)
        .font(.title3)
        .foregroundStyle(symbolColor)
        .frame(width: 24)

      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.headline)
        Text(status)
          .font(.callout)
          .foregroundStyle(.secondary)
          .accessibilityIdentifier(
            title == "Hooks" ? "hook-guide-hook-status" : "initialization-notification-status"
          )
      }

      Spacer(minLength: 12)
      action()
    }
    .frame(maxWidth: .infinity)
  }

  private var desktopGuide: some View {
    VStack(alignment: .leading, spacing: 14) {
      Label("打开 ChatGPT 设置 → 钩子 → 用户配置", systemImage: "desktopcomputer")
        .font(.headline)

      Text("信任并开启未就绪项")
        .font(.callout)
        .foregroundStyle(.secondary)

      HookStatusList()
    }
  }

  private var cliGuide: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("在 Codex CLI 中输入")
        .font(.headline)

      Text("/hooks")
        .font(.system(size: 16, weight: .medium, design: .monospaced))
        .textSelection(.enabled)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityIdentifier("hook-guide-cli-command-primary")

      Text("然后信任并开启未就绪项")
        .font(.callout)
        .foregroundStyle(.secondary)

      Label("配置发生变化时，Codex 会要求重新审核。", systemImage: "info.circle")
        .font(.callout)
        .foregroundStyle(.secondary)

      Spacer()
    }
  }

  private var footer: some View {
    HStack {
      platformPicker
      Spacer()
      Button("完成") {
        dismiss()
      }
      .keyboardShortcut(.defaultAction)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
  }

  private var platformPicker: some View {
    Picker("使用方式", selection: $platform) {
      ForEach(HookGuidePlatform.allCases) { option in
        Text(option.title)
          .tag(option)
          .accessibilityIdentifier("hook-guide-tab-\(option.rawValue)")
      }
    }
    .labelsHidden()
    .pickerStyle(.segmented)
    .controlSize(.small)
    .accessibilityIdentifier("hook-guide-platform")
  }

  private var hookStatusColor: Color {
    if environment.hookConnectionIsReady { return .green }
    if environment.hookInspection.isInstalled,
      environment.hookStatusInspection.availability != .available
    {
      return .secondary
    }
    return environment.hookInspection.isInstalled ? .orange : .accentColor
  }

  private var compactHookStatus: String {
    guard environment.hookInspection.isInstalled else { return L10n.text("尚未安装") }
    if environment.isHookStatusRefreshing,
      environment.hookStatusInspection.availability == .notChecked
    {
      return L10n.text("正在检查")
    }
    guard environment.hookStatusInspection.availability == .available else {
      return environment.hookStatusInspection.availability == .notChecked
        ? L10n.text("待检查")
        : L10n.text("状态暂不可用")
    }
    if environment.hookStatusInspection.allRequiredHooksAreReady {
      return L10n.text("已连接")
    }
    let states = DesktopHookEventName.allCases.map {
      environment.hookDisplayState(for: $0)
    }
    if states.contains(.modified) { return L10n.text("需重新信任") }
    if states.contains(.untrusted) { return L10n.text("待信任") }
    if states.contains(.disabled) { return L10n.text("有项目关闭") }
    return L10n.text("未完整发现")
  }

}

enum HookGuidePlatform: String, CaseIterable, Identifiable {
  case desktop
  case cli

  var id: String { rawValue }

  var title: String {
    switch self {
    case .desktop: L10n.text("桌面端")
    case .cli: "CLI"
    }
  }
}

struct HookStatusList: View {
  @Environment(AppEnvironment.self) private var environment
  private let eventOrder: [DesktopHookEventName] = [
    .userPromptSubmit,
    .stop,
  ]

  var body: some View {
    VStack(spacing: 0) {
      ForEach(Array(eventOrder.enumerated()), id: \.element) { index, eventName in
        if index > 0 { Divider() }
        HookStatusRow(
          eventName: eventName,
          state: environment.hookDisplayState(for: eventName)
        )
      }
    }
    .background(
      Color(nsColor: .controlBackgroundColor),
      in: RoundedRectangle(cornerRadius: 12)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 12)
        .stroke(.separator, lineWidth: 1)
    }
  }
}

private struct HookStatusRow: View {
  let eventName: DesktopHookEventName
  let state: HookDisplayState

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: "point.3.connected.trianglepath.dotted")
        .foregroundStyle(.secondary)
        .frame(width: 20)
      Text(eventName.rawValue)
        .font(.body.weight(.medium))
      Spacer()
      Label(state.title, systemImage: state.symbolName)
        .font(.callout.weight(.medium))
        .foregroundStyle(statusColor)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(state.title)
        .accessibilityIdentifier("hook-guide-status-\(eventName.rawValue)")
    }
    .padding(.horizontal, 14)
    .frame(height: 48)
  }

  private var statusColor: Color {
    if state.isReady { return .green }
    if state.needsAction { return .orange }
    return .secondary
  }
}

@MainActor
final class InitializationGuideWindowController: NSWindowController {
  init(environment: AppEnvironment) {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 700, height: 540),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false
    )
    window.title = ProductConfiguration.displayName
    window.isReleasedWhenClosed = false
    window.center()
    super.init(window: window)

    window.contentViewController = NSHostingController(
      rootView: InitializationGuideView(onComplete: { [weak self] in self?.close() })
        .environment(environment)
        .applicationLocalized(using: environment.localization)
    )
    window.setContentSize(NSSize(width: 700, height: 540))
    window.setAccessibilityIdentifier("initialization-guide-window")
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func present() {
    window?.center()
    showWindow(nil)
    window?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }
}
