import AppKit
import SwiftUI
import UserNotifications

struct InitializationGuideView: View {
  @Environment(AppEnvironment.self) private var environment
  @AppStorage("alerts.visualMode") private var visualMode = AlertVisualMode.defaultMode.rawValue
  @AppStorage("alerts.systemNotificationEnabled") private var systemNotificationEnabled = true
  @AppStorage("alerts.completion.soundEnabled") private var soundEnabled =
    AlertSituation.completion.defaultSoundEnabled
  @AppStorage("alerts.completion.builtInSound") private var builtInSound =
    AlertSituation.completion.defaultBuiltInSound
  @AppStorage("alerts.completion.useCustomSound") private var useCustomSound = false
  @State private var page = InitializationPage.welcome
  @State private var hookPlatform = HookGuidePlatform.desktop

  let onComplete: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      ZStack {
        pageContent
          .id(page)
          .transition(.opacity)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)

      Divider()
      footer
    }
    .frame(width: 700, height: 540)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("initialization-guide")
    .task { await environment.refreshHealth() }
  }

  @ViewBuilder
  private var pageContent: some View {
    switch page {
    case .welcome:
      welcomePage
    case .permissions:
      permissionsPage
    case .alertStyle:
      ScrollView {
        alertStylePage
          .frame(maxWidth: .infinity, alignment: .topLeading)
      }
      .accessibilityIdentifier("initialization-alert-style-scroll")
    }
  }

  private var welcomePage: some View {
    VStack(spacing: 26) {
      Spacer(minLength: 12)

      Image(nsImage: NSApplication.shared.applicationIconImage)
        .resizable()
        .scaledToFit()
        .frame(width: 88, height: 88)
        .accessibilityLabel("CodexDone")
        .accessibilityIdentifier("initialization-app-icon")

      VStack(spacing: 8) {
        Text("欢迎使用 CodexDone")
          .font(.largeTitle.bold())
        Text("Codex 本轮停下时，提醒你回来查看")
          .font(.title3)
          .foregroundStyle(.secondary)
      }

      VStack(alignment: .leading, spacing: 12) {
        introductionRow(
          symbol: "bell.badge.fill",
          title: "无需一直盯着 Codex",
          detail: "本轮停止后及时提醒"
        )
        introductionRow(
          symbol: "menubar.rectangle",
          title: "从菜单栏回来查看",
          detail: "待查看对话会保留到你确认"
        )
      }
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("initialization-welcome-features")

      Spacer(minLength: 12)
    }
    .padding(.horizontal, 36)
    .padding(.vertical, 22)
  }

  private var permissionsPage: some View {
    VStack(alignment: .leading, spacing: 16) {
      pageHeader(
        title: "完成必要设置",
        subtitle: "安装 Hooks 并允许系统通知"
      )

      HStack(spacing: 12) {
        permissionCard(
          symbol: environment.hookConnectionSymbolName,
          symbolColor: hookStatusColor,
          title: "Hooks",
          status: compactHookStatus
        ) {
          HStack(spacing: 8) {
            Button {
              Task { await environment.refreshHealth() }
            } label: {
              Image(systemName: "arrow.clockwise")
            }
            .help("刷新状态")
            .accessibilityLabel("刷新状态")
            .accessibilityIdentifier("initialization-refresh-hooks")
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
            .accessibilityIdentifier("initialization-install-hooks")
          }
        }

        permissionCard(
          symbol: notificationIsAuthorized ? "checkmark.circle.fill" : "bell.badge",
          symbolColor: notificationIsAuthorized ? .green : .accentColor,
          title: L10n.text("系统通知"),
          status: environment.notificationAuthorizationTitle
        ) {
          Button(notificationActionTitle) {
            Task { await environment.requestNotificationAuthorization() }
          }
          .disabled(environment.notificationAuthorizationStatus != .notDetermined)
          .accessibilityIdentifier("initialization-notification-permission")
        }
      }

      VStack(alignment: .leading, spacing: 12) {
        HStack {
          Picker("使用方式", selection: $hookPlatform) {
            ForEach(HookGuidePlatform.allCases) { option in
              Text(option.title)
                .tag(option)
                .accessibilityIdentifier("initialization-hook-tab-\(option.rawValue)")
            }
          }
          .labelsHidden()
          .pickerStyle(.segmented)
          .controlSize(.small)
          .fixedSize(horizontal: true, vertical: false)
          .accessibilityIdentifier("initialization-hook-platform")

          Spacer()
        }

        switch hookPlatform {
        case .desktop:
          Label("打开 ChatGPT 设置 → 钩子 → 用户配置", systemImage: "desktopcomputer")
            .font(.headline)
            .accessibilityIdentifier("initialization-desktop-instruction")
          Text("信任并开启未就绪项")
            .font(.callout)
            .foregroundStyle(.secondary)
          HookStatusList()
        case .cli:
          Text("在 Codex CLI 中输入")
            .font(.headline)
          Text("/hooks")
            .font(.system(size: 15, weight: .medium, design: .monospaced))
            .textSelection(.enabled)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 9))
            .accessibilityIdentifier("initialization-hook-cli-command")
          Text("然后信任并开启未就绪项")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
      }
      .padding(14)
      .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
      .overlay {
        RoundedRectangle(cornerRadius: 14)
          .stroke(.separator, lineWidth: 1)
      }

      Spacer(minLength: 0)
    }
    .padding(.horizontal, 28)
    .padding(.vertical, 22)
  }

  private var alertStylePage: some View {
    VStack(alignment: .leading, spacing: 18) {
      pageHeader(
        title: "选择提示方式",
        subtitle: "以后可在“设置 → 常规 → 提醒”中更改"
      )

      VisualAlertModeSelector(
        storedMode: $visualMode,
        accessibilityPrefix: "initialization"
      )

      Divider()

      HStack {
        Text("系统通知")
        Spacer()
        Toggle("系统通知", isOn: $systemNotificationEnabled)
          .labelsHidden()
          .toggleStyle(.switch)
          .accessibilityIdentifier("initialization-system-notification-enabled")
      }

      Divider()

      HStack {
        Text("登录时启动")
        Spacer()
        if environment.systemIntegrationService.launchAtLoginState == .requiresApproval {
          Button("打开登录项设置") {
            environment.systemIntegrationService.openLoginItemsSettings()
          }
          .accessibilityIdentifier("initialization-open-login-items-settings")
        }
        Toggle(
          "登录时启动",
          isOn: Binding(
            get: {
              environment.systemIntegrationService.launchAtLoginState == .enabled
            },
            set: {
              environment.systemIntegrationService.setLaunchAtLoginEnabled($0)
            }
          )
        )
        .labelsHidden()
        .toggleStyle(.switch)
        .disabled(environment.systemIntegrationService.launchAtLoginState == .updating)
        .accessibilityIdentifier("initialization-launch-at-login")
      }

      Divider()

      HStack {
        Text("播放提示音")
        Spacer()
        Toggle("播放提示音", isOn: $soundEnabled)
          .labelsHidden()
          .toggleStyle(.switch)
          .accessibilityIdentifier("initialization-sound-enabled")
      }

      Divider()

      HStack {
        Text("提示音")
        Spacer()
        HStack(spacing: 8) {
          Picker("提示音", selection: $builtInSound) {
            ForEach(CompletionSoundService.builtInSounds, id: \.self) { name in
              Text(name).tag(name)
            }
          }
          .labelsHidden()
          .pickerStyle(.menu)
          .frame(width: 120, alignment: .trailing)
          .disabled(!soundEnabled)
          .accessibilityIdentifier("initialization-built-in-sound")

          Button("试听") {
            environment.soundService.previewBuiltIn(named: builtInSound)
          }
          .accessibilityIdentifier("initialization-preview-system-sound")
        }
      }
      .onChange(of: builtInSound) { _, _ in
        useCustomSound = false
      }

    }
    .padding(.horizontal, 36)
    .padding(.vertical, 30)
  }

  private func pageHeader(title: LocalizedStringKey, subtitle: LocalizedStringKey) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(title)
        .font(.title2.bold())
      Text(subtitle)
        .font(.callout)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func introductionRow(
    symbol: String,
    title: LocalizedStringKey,
    detail: LocalizedStringKey
  ) -> some View {
    HStack(spacing: 14) {
      Image(systemName: symbol)
        .font(.title3)
        .foregroundStyle(.tint)
        .frame(width: 28, alignment: .leading)
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.headline)
        Text(detail)
          .font(.callout)
          .foregroundStyle(.secondary)
      }
    }
    .padding(.horizontal, 16)
    .frame(height: 66)
  }

  private func permissionCard<Action: View>(
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
        .frame(width: 26)

      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.headline)
        Text(status)
          .font(.callout)
          .foregroundStyle(.secondary)
      }

      Spacer(minLength: 8)
      action()
    }
    .padding(.horizontal, 14)
    .frame(maxWidth: .infinity, minHeight: 76)
    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
    .overlay {
      RoundedRectangle(cornerRadius: 14)
        .stroke(.separator, lineWidth: 1)
    }
  }

  private var footer: some View {
    ZStack {
      HStack {
        if page != .welcome {
          Button("上一步") { move(to: page.previous) }
            .accessibilityIdentifier("initialization-back")
        }

        Spacer()

        if page == .alertStyle {
          Button("开始使用") { onComplete() }
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("initialization-finish")
        } else {
          Button("继续") { move(to: page.next) }
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("initialization-next")
        }
      }

      HStack(spacing: 8) {
        ForEach(InitializationPage.allCases) { item in
          Circle()
            .fill(item == page ? Color.accentColor : Color.secondary.opacity(0.28))
            .frame(width: 7, height: 7)
        }
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("引导进度")
      .accessibilityValue("\(page.rawValue + 1) / \(InitializationPage.allCases.count)")
      .accessibilityIdentifier("initialization-page-indicator")
    }
    .frame(minHeight: 28)
    .padding(.horizontal, 20)
    .padding(.vertical, 12)
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
    let states = DesktopHookEventName.allCases.map(environment.hookDisplayState(for:))
    if states.contains(.modified) { return L10n.text("需重新信任") }
    if states.contains(.untrusted) { return L10n.text("待信任") }
    if states.contains(.disabled) { return L10n.text("有项目关闭") }
    return L10n.text("未完整发现")
  }

  private var notificationIsAuthorized: Bool {
    environment.notificationAuthorizationStatus == .authorized
      || environment.notificationAuthorizationStatus == .provisional
  }

  private var notificationActionTitle: String {
    switch environment.notificationAuthorizationStatus {
    case .notDetermined: L10n.text("允许通知")
    case .denied: L10n.text("已拒绝")
    case .authorized, .provisional, .ephemeral: L10n.text("已允许")
    @unknown default: L10n.text("不可用")
    }
  }

  private func move(to destination: InitializationPage) {
    withAnimation(.easeInOut(duration: 0.18)) {
      page = destination
    }
  }
}

private enum InitializationPage: Int, CaseIterable, Identifiable {
  case welcome
  case permissions
  case alertStyle

  var id: Int { rawValue }

  var next: Self {
    Self(rawValue: min(rawValue + 1, Self.allCases.count - 1)) ?? self
  }

  var previous: Self {
    Self(rawValue: max(rawValue - 1, 0)) ?? self
  }
}

struct VisualAlertModeSelector: View {
  @Binding var storedMode: String
  @State private var lastEnabledMode: AlertVisualMode
  @AppStorage(SmartAlertPreferenceKeys.activeDestination)
  private var smartActiveDestination = AlertVisualDestination.defaultActive.rawValue
  @AppStorage(SmartAlertPreferenceKeys.awayDestination)
  private var smartAwayDestination = AlertVisualDestination.defaultAway.rawValue
  @AppStorage(SmartAlertPreferenceKeys.inactivityDuration)
  private var smartInactivityDuration = SmartAlertInactivityDuration.defaultDuration.rawValue

  let accessibilityPrefix: String

  init(
    storedMode: Binding<String>,
    accessibilityPrefix: String
  ) {
    _storedMode = storedMode
    self.accessibilityPrefix = accessibilityPrefix
    let current = AlertVisualMode(storedValue: storedMode.wrappedValue)
    _lastEnabledMode = State(
      initialValue: current == .none ? AlertVisualMode.defaultMode : current
    )
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 13) {
      HStack {
        Text("开启提醒")
        Spacer()
        Toggle("开启提醒", isOn: alertsEnabled)
          .labelsHidden()
          .toggleStyle(.switch)
          .accessibilityIdentifier("\(accessibilityPrefix)-visual-alert-enabled")
      }

      Divider()

      VStack(alignment: .leading, spacing: 9) {
        Text("提示方式")
          .accessibilityIdentifier("\(accessibilityPrefix)-visual-mode-label")

        HStack(spacing: 8) {
          modeButton(.smart)
          modeButton(.fullscreen)
          modeButton(.hud)
          modeButton(.notch)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("\(accessibilityPrefix)-visual-mode-options")
        .disabled(selectedMode == .none)
        .opacity(selectedMode == .none ? 0.46 : 1)
      }

      if selectedMode == .smart {
        Divider()
        smartSettings
      }
    }
    .padding(.vertical, 4)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("\(accessibilityPrefix)-visual-mode")
    .onChange(of: storedMode) { _, newValue in
      let mode = AlertVisualMode(storedValue: newValue)
      if mode != .none {
        lastEnabledMode = mode
      }
    }
  }

  private var selectedMode: AlertVisualMode {
    AlertVisualMode(storedValue: storedMode)
  }

  private var alertsEnabled: Binding<Bool> {
    Binding(
      get: { selectedMode != .none },
      set: { enabled in
        if enabled {
          if selectedMode == .none {
            storedMode = lastEnabledMode.rawValue
          }
        } else {
          if selectedMode != .none {
            lastEnabledMode = selectedMode
          }
          storedMode = AlertVisualMode.none.rawValue
        }
      }
    )
  }

  private func modeButton(_ mode: AlertVisualMode) -> some View {
    let selected = selectedMode == mode
    return Button {
      lastEnabledMode = mode
      storedMode = mode.rawValue
    } label: {
      VStack(spacing: 9) {
        AlertStyleDesktopPreview(
          mode: mode,
          smartActiveDestination: AlertVisualDestination(
            storedValue: smartActiveDestination,
            fallback: .defaultActive
          ),
          smartAwayDestination: AlertVisualDestination(
            storedValue: smartAwayDestination,
            fallback: .defaultAway
          )
        )
          .frame(width: 88, height: 68)
          .clipped()
          .accessibilityHidden(true)

        HStack(spacing: 6) {
          Text(mode.title)
            .font(.callout.weight(.semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.62)
          if selected {
            Image(systemName: "checkmark.circle.fill")
              .foregroundStyle(.tint)
          }
        }
      }
      .padding(6)
      .frame(width: 100)
      .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 11))
      .overlay {
        RoundedRectangle(cornerRadius: 11)
          .stroke(
            selected ? Color.accentColor : Color(nsColor: .separatorColor),
            lineWidth: selected ? 3 : 1)
      }
    }
    .buttonStyle(.plain)
    .accessibilityLabel(mode.title)
    .accessibilityValue(selected ? L10n.text("已选择") : L10n.text("未选择"))
    .accessibilityIdentifier("\(accessibilityPrefix)-visual-option-\(mode.rawValue)")
  }

  private var smartSettings: some View {
    VStack(spacing: 10) {
      smartDestinationRow(
        "正在使用 Mac 时",
        selection: $smartActiveDestination,
        identifier: "\(accessibilityPrefix)-smart-active-destination"
      )
      smartDestinationRow(
        "暂时离开时",
        selection: $smartAwayDestination,
        identifier: "\(accessibilityPrefix)-smart-away-destination"
      )
      HStack {
        Text("多久未操作算离开")
        Spacer()
        Picker("多久未操作算离开", selection: $smartInactivityDuration) {
          ForEach(SmartAlertInactivityDuration.allCases) { duration in
            Text(duration.title).tag(duration.rawValue)
          }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(width: 130, alignment: .trailing)
        .accessibilityIdentifier("\(accessibilityPrefix)-smart-inactivity-duration")
      }
    }
  }

  private func smartDestinationRow(
    _ title: LocalizedStringKey,
    selection: Binding<String>,
    identifier: String
  ) -> some View {
    HStack {
      Text(title)
      Spacer()
      Picker(title, selection: selection) {
        ForEach(AlertVisualDestination.allCases) { destination in
          Text(destination.title).tag(destination.rawValue)
        }
      }
      .labelsHidden()
      .pickerStyle(.menu)
      .frame(width: 130, alignment: .trailing)
      .accessibilityIdentifier(identifier)
    }
  }
}

struct AlertDisplayStrategyPicker: View {
  @AppStorage(AlertDisplayStrategy.storageKey) private var storedStrategy =
    AlertDisplayStrategy.defaultStrategy.rawValue

  let accessibilityPrefix: String
  var onChange: () -> Void = {}

  var body: some View {
    Picker("提醒显示屏", selection: $storedStrategy) {
      ForEach(AlertDisplayStrategy.allCases) { strategy in
        Text(strategy.title).tag(strategy.rawValue)
      }
    }
    .pickerStyle(.menu)
    .accessibilityIdentifier("\(accessibilityPrefix)-display-strategy")
    .onChange(of: storedStrategy) { _, _ in onChange() }
  }
}

private struct AlertStyleDesktopPreview: View {
  let mode: AlertVisualMode
  let smartActiveDestination: AlertVisualDestination
  let smartAwayDestination: AlertVisualDestination

  var body: some View {
    GeometryReader { proxy in
      ZStack(alignment: .top) {
        Color(red: 0.24, green: 0.31, blue: 0.43)

        simulatedDesktop(in: proxy.size)

        switch mode {
        case .smart:
          smartAlert
        case .fullscreen:
          fullscreenAlert
        case .hud:
          hudAlert
            .padding(.top, 11)
        case .notch:
          notchAlert
        case .none:
          EmptyView()
        }
      }
      .clipShape(RoundedRectangle(cornerRadius: 7))
      .overlay {
        RoundedRectangle(cornerRadius: 7)
          .stroke(.white.opacity(0.28), lineWidth: 1)
      }
    }
  }

  private var smartAlert: some View {
    HStack(spacing: 2) {
      smartState(smartActiveDestination, symbol: "keyboard")
      smartState(smartAwayDestination, symbol: "figure.walk")
    }
    .padding(5)
  }

  private func smartState(
    _ destination: AlertVisualDestination,
    symbol: String
  ) -> some View {
    ZStack(alignment: .bottomLeading) {
      RoundedRectangle(cornerRadius: 4)
        .fill(.black.opacity(0.10))

      switch destination {
      case .none:
        Image(systemName: "bell.slash.fill")
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(.white.opacity(0.7))
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      case .hud:
        Capsule()
          .fill(.regularMaterial)
          .frame(width: 42, height: 13)
          .overlay(alignment: .leading) {
            Circle()
              .fill(.green)
              .frame(width: 5, height: 5)
              .padding(.leading, 5)
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
          .padding(.top, 7)
      case .notch:
        UnevenRoundedRectangle(
          topLeadingRadius: 0,
          bottomLeadingRadius: 5,
          bottomTrailingRadius: 5,
          topTrailingRadius: 0,
          style: .continuous
        )
        .fill(.black.opacity(0.94))
        .frame(width: 42, height: 16)
        .overlay(alignment: .bottomLeading) {
          Circle()
            .fill(.green)
            .frame(width: 5, height: 5)
            .padding(4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
      case .fullscreen:
        LinearGradient(
          colors: [
            Color(red: 0.03, green: 0.46, blue: 0.23),
            Color(red: 0.01, green: 0.10, blue: 0.06),
          ],
          startPoint: .topLeading,
          endPoint: .bottomTrailing
        )
        .opacity(CompletionOverlayView.backdropOpacity)
      }

      Image(systemName: symbol)
        .font(.system(size: 7, weight: .semibold))
        .foregroundStyle(.white.opacity(0.88))
        .padding(4)
    }
  }

  private func simulatedDesktop(in size: CGSize) -> some View {
    ZStack(alignment: .top) {
      Rectangle()
        .fill(.white.opacity(0.12))
        .frame(height: 7)

      RoundedRectangle(cornerRadius: 4)
        .fill(.white.opacity(0.13))
        .frame(width: size.width * 0.72, height: size.height * 0.60)
        .overlay(alignment: .leading) {
          Rectangle()
            .fill(.black.opacity(0.10))
            .frame(width: size.width * 0.16)
        }
        .padding(.top, 14)

      RoundedRectangle(cornerRadius: 4)
        .fill(.black.opacity(0.18))
        .frame(width: size.width * 0.30, height: 6)
        .frame(maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 5)
    }
  }

  private var fullscreenAlert: some View {
    ZStack {
      LinearGradient(
        colors: [
          Color(red: 0.03, green: 0.46, blue: 0.23),
          Color(red: 0.01, green: 0.10, blue: 0.06),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
      .opacity(CompletionOverlayView.backdropOpacity)

      VStack(spacing: 3) {
        Image(systemName: "bell.badge.fill")
          .font(.system(size: 15, weight: .semibold))
          .symbolRenderingMode(.hierarchical)
        Text("Codex 本轮已停止")
          .font(.system(size: 7.5, weight: .bold, design: .rounded))
          .lineLimit(1)
        Text("检查 CodexDone 提醒样式")
          .font(.system(size: 5.5, weight: .semibold, design: .rounded))
          .lineLimit(1)
        HStack(spacing: 2) {
          Image(systemName: "folder")
          Text("CodexDone")
        }
        .font(.system(size: 4.5, weight: .medium))
        .foregroundStyle(.white.opacity(0.82))
      }
      .foregroundStyle(.white)
    }
  }

  private var hudAlert: some View {
    HStack(spacing: 4) {
      Image(systemName: "bell.badge.fill")
        .font(.system(size: 8, weight: .semibold))
        .foregroundStyle(.green)
      VStack(alignment: .leading, spacing: 1) {
        Text("Codex 本轮已停止")
          .font(.system(size: 5.3, weight: .semibold))
          .lineLimit(1)
          .minimumScaleFactor(0.8)
        Text("检查 CodexDone 提醒样式")
          .font(.system(size: 4.1, weight: .medium))
          .lineLimit(1)
          .minimumScaleFactor(0.72)
        Text("CodexDone")
          .font(.system(size: 3.8))
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.horizontal, 6)
    .frame(width: 82, height: 30, alignment: .leading)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
    .clipShape(RoundedRectangle(cornerRadius: 7))
    .overlay {
      RoundedRectangle(cornerRadius: 7)
        .stroke(.white.opacity(0.25), lineWidth: 1)
    }
    .shadow(color: .black.opacity(0.22), radius: 4, y: 2)
  }

  private var notchAlert: some View {
    VStack(spacing: 0) {
      UnevenRoundedRectangle(
        topLeadingRadius: 0,
        bottomLeadingRadius: 10,
        bottomTrailingRadius: 10,
        topTrailingRadius: 0,
        style: .continuous
      )
      .fill(.black.opacity(0.95))
      .frame(width: 84, height: 34)
      .overlay(alignment: .leading) {
        HStack(spacing: 4) {
          Image(systemName: "bell.badge.fill")
            .font(.system(size: 7.5, weight: .semibold))
            .foregroundStyle(.green)
          VStack(alignment: .leading, spacing: 1) {
            Text("Codex 本轮已停止")
              .font(.system(size: 5, weight: .semibold))
              .lineLimit(1)
              .minimumScaleFactor(0.8)
            Text("检查 CodexDone 提醒样式")
              .font(.system(size: 3.8))
              .foregroundStyle(.white.opacity(0.72))
              .lineLimit(1)
              .minimumScaleFactor(0.7)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .foregroundStyle(.white)
        }
        .padding(.horizontal, 6)
        .padding(.top, 6)
      }
      .clipShape(
        UnevenRoundedRectangle(
          topLeadingRadius: 0,
          bottomLeadingRadius: 10,
          bottomTrailingRadius: 10,
          topTrailingRadius: 0,
          style: .continuous
        )
      )
      Spacer(minLength: 0)
    }
  }
}
