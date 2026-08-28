import AppKit
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

enum SettingsDetailLayout {
  static let horizontalContentMargin: CGFloat = 24
}

struct SettingsRootView: View {
  @State private var selection = SettingsSection.general
  let presentInitializationGuide: @MainActor () -> Void

  init(presentInitializationGuide: @escaping @MainActor () -> Void) {
    self.presentInitializationGuide = presentInitializationGuide
  }

  var body: some View {
    NavigationSplitView {
      List(SettingsSection.allCases, selection: $selection) { section in
        Label(section.title, systemImage: section.symbol)
          .tag(section)
          .accessibilityIdentifier("settings-section-\(section.rawValue)")
      }
      .listStyle(.sidebar)
      .navigationTitle("设置")
      .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 220)
      .accessibilityIdentifier("settings-sidebar")
    } detail: {
      Group {
        switch selection {
        case .general: GeneralSettingsView()
        case .alerts: AlertSettingsView()
        case .diagnostics:
          PrivacyAndDiagnosticsSettingsView(
            presentInitializationGuide: presentInitializationGuide
          )
        case .about: AboutSettingsView()
        }
      }
      .navigationTitle(selection.title)
    }
    .frame(width: 780, height: 560)
    .background(SettingsWindowConfigurator(title: selection.title))
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("settings-root")
  }
}

private struct SettingsWindowConfigurator: NSViewRepresentable {
  let title: String

  func makeNSView(context: Context) -> SettingsWindowObservationView {
    let view = SettingsWindowObservationView()
    update(view)
    return view
  }

  func updateNSView(_ nsView: SettingsWindowObservationView, context: Context) {
    update(nsView)
  }

  private func update(_ view: SettingsWindowObservationView) {
    view.onWindowAvailable = { window in
      window.toolbarStyle = .unified
      window.titleVisibility = .visible
      window.title = title
    }
    view.configureCurrentWindowIfAvailable()
  }
}

private final class SettingsWindowObservationView: NSView {
  var onWindowAvailable: ((NSWindow) -> Void)?

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    configureCurrentWindowIfAvailable()
  }

  func configureCurrentWindowIfAvailable() {
    guard let window else { return }
    onWindowAvailable?(window)
  }
}

private enum SettingsSection: String, CaseIterable, Identifiable {
  case general
  case alerts
  case diagnostics
  case about

  var id: String { rawValue }

  var title: String {
    switch self {
    case .general: L10n.text("常规")
    case .alerts: L10n.text("提醒")
    case .diagnostics: L10n.text("隐私与诊断")
    case .about: L10n.text("关于")
    }
  }

  var symbol: String {
    switch self {
    case .general: "gearshape"
    case .alerts: "bell"
    case .diagnostics: "hand.raised"
    case .about: "info.circle"
    }
  }
}

private struct GeneralSettingsView: View {
  @Environment(\.colorScheme) private var effectiveColorScheme
  @Environment(AppEnvironment.self) private var environment
  @AppStorage("alerts.systemNotificationEnabled") private var systemNotificationEnabled = true
  @AppStorage("alerts.visualMode") private var visualMode = AlertVisualMode.defaultMode.rawValue
  @AppStorage("appearance.colorScheme") private var colorScheme = "system"
  @AppStorage("general.showDockIcon") private var showDockIcon = false
  @State private var showEnablementGuide = false

  var body: some View {
    Form {
      Section {
        LabeledContent("Hooks") {
          Label(
            environment.hookConnectionStatusTitle,
            systemImage: environment.hookConnectionSymbolName
          )
          .foregroundStyle(hookStatusColor)
        }
        HStack {
          Button(
            environment.hookInspection.isInstalled
              ? L10n.text("修复 Hooks")
              : L10n.text("安装 Hooks")
          ) {
            Task { await environment.installHooks() }
          }
          .disabled(environment.isHookOperationInProgress)
          .accessibilityIdentifier("settings-install-hooks")

          Button {
            showEnablementGuide = true
          } label: {
            Label("如何启用", systemImage: "questionmark.circle")
          }
          .accessibilityIdentifier("settings-hook-enablement-guide")
        }
        if let message = environment.hookOperationMessage {
          Text(message)
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
      } header: {
        Text("Codex 连接")
          .accessibilityIdentifier("settings-general-section-title")
      }

      Section("提醒") {
        Toggle("系统通知", isOn: $systemNotificationEnabled)
          .accessibilityIdentifier("settings-system-notification-enabled")
        if systemNotificationEnabled,
          environment.notificationAuthorizationStatus != .authorized
        {
          LabeledContent("通知权限") {
            HStack {
              Text(environment.notificationAuthorizationTitle)
              Button("请求权限") {
                Task { await environment.requestNotificationAuthorization() }
              }
            }
          }
        }
        VisualAlertModeSelector(
          storedMode: $visualMode,
          accessibilityPrefix: "settings"
        )
        AlertDisplayStrategyPicker(
          accessibilityPrefix: "settings",
          onChange: environment.refreshNotchUnreadIndicatorPlacement
        )
      }

      Section("菜单栏") {
        Toggle(
          "显示未读数量",
          isOn: Binding(
            get: { environment.statusItemShowsUnreadCount },
            set: { environment.setStatusItemShowsUnreadCount($0) }
          )
        )
        .accessibilityIdentifier("settings-status-item-count")
        Toggle(
          "显示刘海未读状态",
          isOn: Binding(
            get: { environment.notchUnreadIndicatorEnabled },
            set: { environment.setNotchUnreadIndicatorEnabled($0) }
          )
        )
        .accessibilityIdentifier("settings-notch-unread-indicator")
      }

      Section("应用") {
        Toggle(
          "登录时启动",
          isOn: Binding(
            get: { environment.systemIntegrationService.launchAtLoginState == .enabled },
            set: { environment.systemIntegrationService.setLaunchAtLoginEnabled($0) }
          )
        )
        .disabled(environment.systemIntegrationService.launchAtLoginState == .updating)
        if environment.systemIntegrationService.launchAtLoginState == .requiresApproval {
          Button("打开登录项设置") {
            environment.systemIntegrationService.openLoginItemsSettings()
          }
        }
        Toggle("在 Dock 中显示", isOn: $showDockIcon)
        Picker(
          "语言",
          selection: Binding(
            get: { environment.localization.preference },
            set: { environment.selectLanguage($0) }
          )
        ) {
          ForEach(ApplicationLanguagePreference.allCases) { preference in
            Text(preference.title)
              .tag(preference)
              .accessibilityIdentifier("settings-language-\(preference.rawValue)")
          }
        }
        .pickerStyle(.menu)
        .accessibilityIdentifier("settings-language")
        Picker("外观", selection: $colorScheme) {
          Text("跟随系统")
            .tag("system")
            .accessibilityIdentifier("settings-appearance-system")
          Text("浅色")
            .tag("light")
            .accessibilityIdentifier("settings-appearance-light")
          Text("深色")
            .tag("dark")
            .accessibilityIdentifier("settings-appearance-dark")
        }
        .pickerStyle(.segmented)
      }
    }
    .formStyle(.grouped)
    .contentMargins(
      .horizontal,
      SettingsDetailLayout.horizontalContentMargin,
      for: .scrollContent
    )
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("settings-general-root")
    .accessibilityValue(effectiveColorScheme == .dark ? "dark" : "light")
    .task { await environment.refreshHealth() }
    .onChange(of: showDockIcon) { _, visible in
      environment.systemIntegrationService.setDockIconVisible(visible)
    }
    .sheet(isPresented: $showEnablementGuide) {
      HookEnablementGuideView()
    }
  }

  private var hookStatusColor: Color {
    if environment.hookConnectionIsReady { return .green }
    if environment.hookInspection.isInstalled,
      environment.hookStatusInspection.availability != .available
    {
      return .secondary
    }
    return .orange
  }
}

private struct AlertSettingsView: View {
  @Environment(AppEnvironment.self) private var environment
  @AppStorage("alerts.visualMode") private var visualMode = AlertVisualMode.defaultMode.rawValue
  @AppStorage("alerts.completion.soundVolume") private var completionSoundVolume = 1.0
  @AppStorage("alerts.overlayDismissalMode") private var overlayDismissalMode =
    OverlayDismissalMode.defaultMode.rawValue
  @AppStorage("alerts.overlayAutoDismiss") private var overlayAutoDismiss =
    OverlayAutoDismissDuration.never.rawValue

  var body: some View {
    Form {
      Section("视觉提醒") {
        VisualAlertModeSelector(
          storedMode: $visualMode,
          accessibilityPrefix: "alert-settings"
        )
        AlertDisplayStrategyPicker(
          accessibilityPrefix: "alert-settings",
          onChange: environment.refreshNotchUnreadIndicatorPlacement
        )
      }

      Section("自定义音频") {
        LabeledContent(
          "音频文件",
          value: environment.soundService.customSoundDisplayName ?? L10n.text("尚未导入")
        )
        HStack {
          Button("导入音频…") { chooseAudio() }
            .accessibilityIdentifier("settings-import-custom-audio")
          if environment.soundService.customSoundDisplayName != nil {
            Button("试听") {
              environment.soundService.previewCustom(volume: completionSoundVolume)
            }
            .accessibilityIdentifier("settings-preview-custom-audio")
            Button("移除") { environment.removeCustomSound() }
          }
        }
        LabeledContent(
          "最近播放",
          value: environment.soundService.playbackStatusTitle
        )
        .accessibilityIdentifier("settings-sound-playback-status")
        if let message = environment.alertOperationMessage {
          Text(message)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("settings-alert-operation-message")
        }
      }

      AlertSituationSoundSettingsView(
        situation: .completion,
        sectionTitle: L10n.text("提示音")
      )

      AlertHeadlineSettingsView()

      OverlayAppearanceSettingsView()

      Section("全屏交互") {
        Picker("全屏关闭方式", selection: $overlayDismissalMode) {
          ForEach(OverlayDismissalMode.allCases) { mode in
            Text(mode.title).tag(mode.rawValue)
          }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("settings-overlay-dismissal-mode")
        Picker("全屏自动关闭", selection: $overlayAutoDismiss) {
          ForEach(OverlayAutoDismissDuration.allCases) { duration in
            Text(duration.title).tag(duration.rawValue)
          }
        }
        .pickerStyle(.menu)
        .accessibilityIdentifier("settings-overlay-auto-dismiss")
      }

      Section("测试") {
        HStack {
          Button("测试全屏提示") {
            Task { await environment.sendTestAlert(visualModeOverride: .fullscreen) }
          }
          .accessibilityIdentifier("settings-test-fullscreen-alert")

          Button("测试顶部 HUD") {
            Task { await environment.sendTestAlert(visualModeOverride: .hud) }
          }
          .accessibilityIdentifier("settings-test-hud-alert")

          Button("测试刘海提示") {
            Task { await environment.sendTestAlert(visualModeOverride: .notch) }
          }
          .accessibilityIdentifier("settings-test-notch-alert")
        }
      }
    }
    .formStyle(.grouped)
    .contentMargins(
      .horizontal,
      SettingsDetailLayout.horizontalContentMargin,
      for: .scrollContent
    )
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("settings-alerts-root")
  }

  private func chooseAudio() {
    let panel = NSOpenPanel()
    panel.title = L10n.text("选择提醒音频")
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    panel.allowsMultipleSelection = false
    let supportedTypes = CompletionSoundService.supportedExtensions
      .sorted()
      .compactMap { UTType(filenameExtension: $0) }
    panel.allowedContentTypes = supportedTypes.isEmpty ? [.audio] : supportedTypes
    guard panel.runModal() == .OK, let url = panel.url else { return }
    environment.importCustomSound(from: url)
  }
}

private struct AlertHeadlineSettingsView: View {
  var body: some View {
    Section("主标题") {
      ForEach(AlertHeadlineChannel.allCases) { channel in
        AlertHeadlineField(channel: channel)
      }
    }
  }
}

private struct AlertHeadlineField: View {
  let channel: AlertHeadlineChannel
  @AppStorage private var value: String

  init(channel: AlertHeadlineChannel) {
    self.channel = channel
    _value = AppStorage(wrappedValue: "", channel.storageKey)
  }

  var body: some View {
    LabeledContent(channel.title) {
      TextField(
        "",
        text: Binding(
          get: { value },
          set: { value = AlertHeadlineChannel.editableValue($0) }
        ),
        prompt: Text("留空使用默认")
      )
      .labelsHidden()
      .textFieldStyle(.roundedBorder)
      .frame(width: 260)
      .accessibilityIdentifier("settings-headline-\(channel.rawValue)")
    }
  }
}

private struct OverlayAppearanceSettingsView: View {
  @Environment(AppEnvironment.self) private var environment
  @AppStorage(OverlayAppearanceKeys.backgroundStyle) private var backgroundStyle =
    OverlayBackgroundStyle.gradient.rawValue
  @AppStorage(OverlayAppearanceKeys.solidColor) private var solidColor =
    OverlayAppearanceConfiguration.defaultSolidHex
  @AppStorage(OverlayAppearanceKeys.gradientStartColor) private var gradientStartColor =
    OverlayAppearanceConfiguration.defaultGradientStartHex
  @AppStorage(OverlayAppearanceKeys.gradientEndColor) private var gradientEndColor =
    OverlayAppearanceConfiguration.defaultGradientEndHex
  @AppStorage(OverlayAppearanceKeys.backgroundOpacity) private var backgroundOpacity =
    OverlayAppearanceConfiguration.defaultOpacity
  @AppStorage(OverlayAppearanceKeys.backgroundBlur) private var backgroundBlur =
    OverlayAppearanceConfiguration.defaultBlurRadius
  @AppStorage(OverlayAppearanceKeys.blurOnlyIntensity) private var blurOnlyIntensity =
    OverlayAppearanceConfiguration.defaultBlurOnlyIntensity
  @AppStorage(OverlayAppearanceKeys.imageBlur) private var imageBlur =
    OverlayAppearanceConfiguration.defaultImageBlurRadius

  var body: some View {
    let selectedStyle = OverlayBackgroundStyle(storedValue: backgroundStyle)

    Section("全屏外观") {
      Picker("背景类型", selection: $backgroundStyle) {
        ForEach(OverlayBackgroundStyle.allCases) { style in
          Text(style.title)
            .tag(style.rawValue)
        }
      }
      .pickerStyle(.menu)
      .accessibilityIdentifier("settings-overlay-background-style")

      switch selectedStyle {
      case .solid:
        ColorPicker(
          "背景颜色",
          selection: solidColorBinding,
          supportsOpacity: false
        )
        .accessibilityIdentifier("settings-overlay-solid-color")
      case .gradient:
        ColorPicker(
          "渐变起始颜色",
          selection: gradientStartColorBinding,
          supportsOpacity: false
        )
        .accessibilityIdentifier("settings-overlay-gradient-start")
        ColorPicker(
          "渐变结束颜色",
          selection: gradientEndColorBinding,
          supportsOpacity: false
        )
        .accessibilityIdentifier("settings-overlay-gradient-end")
      case .blurOnly:
        EmptyView()
      case .image:
        LabeledContent(
          "自定义背景图",
          value: environment.overlayAppearanceService.customImageDisplayName
            ?? L10n.text("尚未导入")
        )
        HStack {
          Button(
            environment.overlayAppearanceService.hasCustomImage
              ? L10n.text("更换图片…")
              : L10n.text("导入图片…")
          ) {
            chooseImage()
          }
          .accessibilityIdentifier("settings-import-overlay-background")
          if environment.overlayAppearanceService.hasCustomImage {
            Button("移除") {
              environment.removeOverlayBackground()
              backgroundStyle = OverlayBackgroundStyle.gradient.rawValue
            }
            .accessibilityIdentifier("settings-remove-overlay-background")
          }
        }
      }

      if selectedStyle != .blurOnly {
        LabeledContent("背景透明度") {
          HStack(spacing: 10) {
            Slider(
              value: $backgroundOpacity,
              in: OverlayAppearanceConfiguration.opacityRange
            )
            Text("\(Int((backgroundOpacity * 100).rounded()))%")
              .monospacedDigit()
              .frame(width: 42, alignment: .trailing)
          }
          .frame(width: 260)
        }
        .accessibilityIdentifier("settings-overlay-background-opacity")
      }

      if selectedStyle == .image {
        LabeledContent("图片模糊度") {
          HStack(spacing: 10) {
            Slider(
              value: $imageBlur,
              in: OverlayAppearanceConfiguration.imageBlurRange,
              step: 1
            )
            Text("\(Int(imageBlur.rounded()))")
              .monospacedDigit()
              .frame(width: 42, alignment: .trailing)
          }
          .frame(width: 260)
        }
        .accessibilityIdentifier("settings-overlay-image-blur")
      } else if selectedStyle == .blurOnly {
        LabeledContent("背景模糊度") {
          HStack(spacing: 10) {
            Slider(
              value: $blurOnlyIntensity,
              in: OverlayAppearanceConfiguration.blurOnlyIntensityRange
            )
            Text("\(blurOnlyIntensityPercentage)%")
              .monospacedDigit()
              .frame(width: 42, alignment: .trailing)
          }
          .frame(width: 260)
        }
        .accessibilityIdentifier("settings-overlay-blur-only-intensity")
      } else {
        LabeledContent("背景模糊度") {
          HStack(spacing: 10) {
            Slider(
              value: $backgroundBlur,
              in: OverlayAppearanceConfiguration.blurRange,
              step: 1
            )
            Text("\(backgroundBlurPercentage)%")
              .monospacedDigit()
              .frame(width: 42, alignment: .trailing)
          }
          .frame(width: 260)
        }
        .accessibilityIdentifier("settings-overlay-background-blur")
      }

      if let message = environment.overlayAppearanceOperationMessage {
        Text(message)
          .font(.footnote)
          .foregroundStyle(.secondary)
          .accessibilityIdentifier("settings-overlay-background-message")
      }

      Button("恢复默认") {
        environment.restoreOverlayAppearanceDefaults()
      }
      .accessibilityIdentifier("settings-restore-overlay-appearance")
    }
  }

  private var solidColorBinding: Binding<Color> {
    Binding(
      get: {
        OverlayColorCodec.color(
          for: solidColor,
          fallback: OverlayAppearanceConfiguration.defaultSolidHex
        )
      },
      set: {
        solidColor = OverlayColorCodec.hex(
          for: $0,
          fallback: OverlayAppearanceConfiguration.defaultSolidHex
        )
      }
    )
  }

  private var backgroundBlurPercentage: Int {
    Int(
      (backgroundBlur / OverlayAppearanceConfiguration.blurRange.upperBound * 100)
        .rounded()
    )
  }

  private var blurOnlyIntensityPercentage: Int {
    Int((blurOnlyIntensity * 100).rounded())
  }

  private var gradientStartColorBinding: Binding<Color> {
    Binding(
      get: {
        OverlayColorCodec.color(
          for: gradientStartColor,
          fallback: OverlayAppearanceConfiguration.defaultGradientStartHex
        )
      },
      set: {
        gradientStartColor = OverlayColorCodec.hex(
          for: $0,
          fallback: OverlayAppearanceConfiguration.defaultGradientStartHex
        )
      }
    )
  }

  private var gradientEndColorBinding: Binding<Color> {
    Binding(
      get: {
        OverlayColorCodec.color(
          for: gradientEndColor,
          fallback: OverlayAppearanceConfiguration.defaultGradientEndHex
        )
      },
      set: {
        gradientEndColor = OverlayColorCodec.hex(
          for: $0,
          fallback: OverlayAppearanceConfiguration.defaultGradientEndHex
        )
      }
    )
  }

  private func chooseImage() {
    let panel = NSOpenPanel()
    panel.title = L10n.text("选择全屏背景图")
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    panel.allowsMultipleSelection = false
    panel.allowedContentTypes = [.image]
    guard panel.runModal() == .OK, let url = panel.url else { return }
    environment.importOverlayBackground(from: url)
    if environment.overlayAppearanceService.hasCustomImage {
      backgroundStyle = OverlayBackgroundStyle.image.rawValue
    }
  }
}

private struct AlertSituationSoundSettingsView: View {
  @Environment(AppEnvironment.self) private var environment
  let situation: AlertSituation
  let sectionTitle: String
  @AppStorage private var soundEnabled: Bool
  @AppStorage private var builtInSound: String
  @AppStorage private var useCustomSound: Bool
  @AppStorage private var soundVolume: Double

  init(
    situation: AlertSituation,
    sectionTitle: String
  ) {
    self.situation = situation
    self.sectionTitle = sectionTitle
    _soundEnabled = AppStorage(
      wrappedValue: situation.defaultSoundEnabled,
      situation.soundEnabledKey
    )
    _builtInSound = AppStorage(
      wrappedValue: situation.defaultBuiltInSound,
      situation.builtInSoundKey
    )
    _useCustomSound = AppStorage(wrappedValue: false, situation.useCustomSoundKey)
    _soundVolume = AppStorage(wrappedValue: 1, situation.soundVolumeKey)
  }

  var body: some View {
    Section(sectionTitle) {
      Toggle("播放提示音", isOn: $soundEnabled)
      LabeledContent("系统提示音") {
        HStack(spacing: 8) {
          Picker("系统提示音", selection: $builtInSound) {
            ForEach(CompletionSoundService.builtInSounds, id: \.self) { name in
              Text(name).tag(name)
            }
          }
          .labelsHidden()
          .pickerStyle(.menu)
          .disabled(!soundEnabled)
          Button("试听") {
            environment.soundService.previewBuiltIn(
              named: builtInSound,
              volume: soundVolume
            )
          }
          .accessibilityIdentifier("settings-preview-system-sound")
        }
      }
      Toggle("使用自定义音频", isOn: $useCustomSound)
        .disabled(!canSelectCustomSound)
        .opacity(canSelectCustomSound ? 1 : 0.45)
        .accessibilityIdentifier("settings-use-custom-audio")
      HStack {
        Text("音量")
        Slider(value: $soundVolume, in: 0...1)
        Text("\(Int((soundVolume * 100).rounded()))%")
          .monospacedDigit()
          .frame(width: 42, alignment: .trailing)
      }
      .disabled(!soundEnabled)
    }
  }

  private var canSelectCustomSound: Bool {
    AlertSettingsRules.canSelectCustomSound(
      soundEnabled: soundEnabled,
      hasImportedSound: environment.soundService.customSoundDisplayName != nil
    )
  }
}

enum AlertSettingsRules {
  static func canSelectCustomSound(
    soundEnabled: Bool,
    hasImportedSound: Bool
  ) -> Bool {
    soundEnabled && hasImportedSound
  }
}

private struct PrivacyAndDiagnosticsSettingsView: View {
  @Environment(AppEnvironment.self) private var environment
  @State private var confirmUninstall = false
  let presentInitializationGuide: @MainActor () -> Void

  var body: some View {
    Form {
      Section("Hooks") {
        LabeledContent("配置") {
          Label(
            environment.hookConnectionStatusTitle,
            systemImage: environment.hookConnectionSymbolName
          )
          .foregroundStyle(hookSummaryColor)
        }
        ForEach(
          [
            DesktopHookEventName.userPromptSubmit,
            DesktopHookEventName.stop,
          ],
          id: \.self
        ) { eventName in
          hookStatusRow(eventName)
        }
        statusRow(
          "Bridge",
          isHealthy: environment.hookInspection.helperIsExecutable,
          value: environment.hookInspection.helperIsExecutable
            ? L10n.text("正常")
            : L10n.text("缺失")
        )
        statusRow(
          "Socket",
          isHealthy: environment.isSocketListening,
          value: environment.isSocketListening ? L10n.text("正常") : L10n.text("离线")
        )
        LabeledContent("Spool 待处理", value: "\(environment.spoolCount)")
        HStack {
          Button("刷新") {
            Task { await environment.refreshHealth() }
          }
          .disabled(
            environment.isHookOperationInProgress || environment.isHookStatusRefreshing
          )
          Button("移除 Hooks", role: .destructive) {
            confirmUninstall = true
          }
          .disabled(
            environment.isHookOperationInProgress || !environment.hookInspection.isInstalled
          )
        }
        if let message = environment.hookOperationMessage {
          Text(message)
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
      }

      Section {
        if environment.completionStore.hookEventDiagnostics.isEmpty {
          Text("暂无事件记录")
            .foregroundStyle(.secondary)
        } else {
          ForEach(environment.completionStore.hookEventDiagnostics) { record in
            hookEventDiagnosticRow(record)
          }
        }
        Button("清空事件记录", role: .destructive) {
          environment.completionStore.clearHookEventDiagnostics()
        }
        .disabled(environment.completionStore.hookEventDiagnostics.isEmpty)
        .accessibilityIdentifier("settings-clear-hook-diagnostics")
      } header: {
        Text("最近事件")
          .accessibilityIdentifier("settings-hook-diagnostic-list")
      } footer: {
        Text("仅记录事件类型、时间、接收方式、内容形态和处理结果，不保存诊断内容")
      }

      Section("记录") {
        LabeledContent("待查看", value: "\(environment.completionStore.unreadCount)")
        Button("全部标记已查看") {
          environment.completionStore.acknowledgeAll()
        }
        .disabled(environment.completionStore.unreadCount == 0)
      }

      Section("诊断") {
        Button("打开首次使用引导") {
          presentInitializationGuide()
        }
        .accessibilityIdentifier("settings-open-initialization-guide")

        Button("打开诊断日志") {
          environment.systemIntegrationService.openDiagnosticLogs()
        }
      }
    }
    .formStyle(.grouped)
    .contentMargins(
      .horizontal,
      SettingsDetailLayout.horizontalContentMargin,
      for: .scrollContent
    )
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("settings-diagnostics-root")
    .task { await environment.refreshHealth() }
    .confirmationDialog(
      "移除 CodexDone 添加的 Hooks？",
      isPresented: $confirmUninstall,
      titleVisibility: .visible
    ) {
      Button("移除", role: .destructive) {
        Task { await environment.uninstallHooks() }
      }
      Button("取消", role: .cancel) {}
    } message: {
      Text("其他 Hooks 会保留。")
    }
  }

  private func statusRow(_ label: String, isHealthy: Bool, value: String) -> some View {
    LabeledContent(label) {
      Label(
        value,
        systemImage: isHealthy ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
      )
      .foregroundStyle(isHealthy ? .green : .orange)
    }
  }

  private func hookStatusRow(_ eventName: DesktopHookEventName) -> some View {
    let state = environment.hookDisplayState(for: eventName)
    return LabeledContent(eventName.rawValue) {
      Label(state.title, systemImage: state.symbolName)
        .foregroundStyle(hookColor(for: state))
        .accessibilityIdentifier("settings-hook-status-\(eventName.rawValue)")
    }
  }

  private var hookSummaryColor: Color {
    if environment.hookConnectionIsReady { return .green }
    if environment.hookStatusInspection.availability != .available { return .secondary }
    return .orange
  }

  private func hookColor(for state: HookDisplayState) -> Color {
    if state.isReady { return .green }
    if state.needsAction { return .orange }
    return .secondary
  }

  private func hookEventDiagnosticRow(_ record: HookEventDiagnosticRecord) -> some View {
    HookEventDiagnosticDisclosureRow(
      record: record,
      receivedAtText: dateText(record.receivedAt)
    )
  }

  private func dateText(_ date: Date) -> String {
    return date.formatted(
      Date.FormatStyle(date: .abbreviated, time: .standard)
        .locale(environment.localization.locale)
    )
  }
}

private struct HookEventDiagnosticDisclosureRow: View {
  let record: HookEventDiagnosticRecord
  let receivedAtText: String

  @State private var isExpanded = false

  private var identifier: String {
    "settings-hook-diagnostic-\(record.id.uuidString.lowercased())"
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Button {
        withAnimation(.easeInOut(duration: 0.16)) {
          isExpanded.toggle()
        }
      } label: {
        HStack(alignment: .top, spacing: 10) {
          Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(width: 12, height: 20, alignment: .center)

          Image(
            systemName: record.eventName == .userPromptSubmit
              ? "arrow.up.message"
              : "stop.circle"
          )
          .font(.system(size: 15))
          .foregroundStyle(.secondary)
          .frame(width: 18, height: 20, alignment: .center)

          VStack(alignment: .leading, spacing: 3) {
            Text(record.eventName.rawValue)
              .frame(minHeight: 20, alignment: .center)
            Text(record.outcome.title)
              .font(.caption)
              .foregroundStyle(.secondary)
          }

          Spacer(minLength: 12)
          Text(receivedAtText)
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.trailing)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityValue(isExpanded ? L10n.text("已展开") : L10n.text("已收起"))
      .accessibilityIdentifier(identifier)

      if isExpanded {
        VStack(spacing: 7) {
          LabeledContent("接收时间", value: receivedAtText)
            .accessibilityIdentifier("\(identifier)-detail-received-at")
          LabeledContent("接收方式", value: record.ingress.title)
            .accessibilityIdentifier("\(identifier)-detail-ingress")
          LabeledContent("内容形态", value: record.payloadKind.title)
            .accessibilityIdentifier("\(identifier)-detail-payload-kind")
          LabeledContent("处理结果", value: record.outcome.title)
            .accessibilityIdentifier("\(identifier)-detail-outcome")
        }
        .font(.callout)
        .padding(.leading, 40)
        .padding(.top, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("\(identifier)-details")
        .transition(.opacity.combined(with: .move(edge: .top)))
      }
    }
  }
}

@MainActor
private struct AboutSettingsView: View {
  @State private var updateState = AboutUpdateState.idle

  private let updateService = GitHubReleaseUpdateService()

  var body: some View {
    Form {
      Section {
        VStack(spacing: 8) {
          Image(nsImage: NSApplication.shared.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .frame(width: 88, height: 88)
            .accessibilityLabel("CodexDone 应用图标")
            .accessibilityIdentifier("settings-about-app-icon")

          Text(ProductConfiguration.displayName)
            .font(.title2.weight(.semibold))

          Text(L10n.format("版本 %@", ProductConfiguration.marketingVersion))
            .foregroundStyle(.secondary)

          Text(ProductConfiguration.shortDescription)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings-about-header")
      }

      Section("项目") {
        Text(ProductConfiguration.thirdPartyNotice)
          .font(.footnote)
          .foregroundStyle(.secondary)
        if let license = ProductConfiguration.licenseDisplayName {
          LabeledContent("许可证", value: license)
        }

        LabeledContent("GitHub") {
          if let repository = ProductConfiguration.githubRepository {
            Link("打开项目主页", destination: repository.webURL)
              .accessibilityIdentifier("settings-about-github-link")
          } else {
            Text("待配置")
              .foregroundStyle(.secondary)
              .accessibilityIdentifier("settings-about-github-unconfigured")
          }
        }
      }

      Section("更新") {
        HStack(spacing: 12) {
          updateStatus

          Spacer(minLength: 12)

          if case let .updateAvailable(release) = updateState {
            Link("查看新版本", destination: release.pageURL)
              .accessibilityIdentifier("settings-about-open-release")
          }

          Button("检查更新") {
            Task { await checkForUpdates() }
          }
          .disabled(
            ProductConfiguration.githubRepository == nil || updateState == .checking
          )
          .accessibilityIdentifier("settings-about-check-updates")
        }
      }
    }
    .formStyle(.grouped)
    .contentMargins(
      .horizontal,
      SettingsDetailLayout.horizontalContentMargin,
      for: .scrollContent
    )
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("settings-about-root")
  }

  @ViewBuilder
  private var updateStatus: some View {
    switch updateState {
    case .idle:
      Text(
        ProductConfiguration.githubRepository == nil
          ? L10n.text("GitHub 仓库尚未配置")
          : L10n.text("待检查")
      )
      .foregroundStyle(.secondary)
      .accessibilityIdentifier("settings-about-update-status")

    case .checking:
      HStack(spacing: 7) {
        ProgressView()
          .controlSize(.small)
        Text("正在检查更新")
      }
      .accessibilityIdentifier("settings-about-update-status")

    case let .upToDate(version):
      Label(
        L10n.format("已是最新版本 %@", version),
        systemImage: "checkmark.circle.fill"
      )
      .foregroundStyle(.green)
      .accessibilityIdentifier("settings-about-update-status")

    case let .updateAvailable(release):
      Label(
        L10n.format("发现新版本 %@", release.version),
        systemImage: "arrow.down.circle.fill"
      )
      .foregroundStyle(.green)
      .accessibilityIdentifier("settings-about-update-status")

    case let .failed(error):
      Label(updateErrorTitle(error), systemImage: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
        .accessibilityIdentifier("settings-about-update-status")
    }
  }

  private func checkForUpdates() async {
    guard let repository = ProductConfiguration.githubRepository else { return }
    updateState = .checking
    do {
      switch try await updateService.check(
        repository: repository,
        currentVersion: ProductConfiguration.marketingVersion
      ) {
      case let .upToDate(latestVersion):
        updateState = .upToDate(version: latestVersion)
      case let .updateAvailable(release):
        updateState = .updateAvailable(release)
      }
    } catch let error as GitHubReleaseUpdateError {
      updateState = .failed(error)
    } catch {
      updateState = .failed(.connectionFailed)
    }
  }

  private func updateErrorTitle(_ error: GitHubReleaseUpdateError) -> String {
    switch error {
    case .connectionFailed:
      L10n.text("无法连接 GitHub")
    case .rateLimited:
      L10n.text("请求过于频繁，请稍后再试")
    case .releaseUnavailable:
      L10n.text("尚未发布可用版本")
    case .invalidResponse, .server:
      L10n.text("更新信息无法读取")
    }
  }
}

private enum AboutUpdateState: Equatable {
  case idle
  case checking
  case upToDate(version: String)
  case updateAvailable(GitHubRelease)
  case failed(GitHubReleaseUpdateError)
}
