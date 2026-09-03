import Foundation
import Testing

@testable import CodexDone

struct LocalizationTests {
  @Test("产品使用 Dian Studios Bundle Identifier")
  func productBundleIdentifier() {
    #expect(ProductConfiguration.bundleIdentifier == "com.dianstudios.codexdone")
  }

  @Test("产品公开仓库指向 CodexDone")
  func productGitHubRepository() throws {
    let repository = try #require(ProductConfiguration.githubRepository)

    #expect(repository.owner == "Diandd")
    #expect(repository.name == "CodexDone")
    #expect(repository.webURL.absoluteString == "https://github.com/Diandd/CodexDone")
  }

  @Test("GitHub Release 检查使用公开 latest release 接口")
  func githubReleaseRequest() throws {
    let repository = try #require(GitHubRepository(owner: "Diandd", name: "CodexDone"))
    let request = GitHubReleaseUpdateService.request(
      repository: repository,
      currentVersion: "0.2.0"
    )

    #expect(repository.webURL.absoluteString == "https://github.com/Diandd/CodexDone")
    #expect(
      request.url?.absoluteString
        == "https://api.github.com/repos/Diandd/CodexDone/releases/latest"
    )
    #expect(request.httpMethod == "GET")
    #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
    #expect(
      request.value(forHTTPHeaderField: "X-GitHub-Api-Version")
        == GitHubReleaseUpdateService.apiVersion
    )
    #expect(request.value(forHTTPHeaderField: "User-Agent") == "CodexDone/0.2.0")
  }

  @Test("GitHub Release 标签按数字版本比较")
  func githubReleaseVersionComparison() throws {
    let releaseURL = try #require(
      URL(string: "https://github.com/Diandd/CodexDone/releases/tag/v0.10.0")
    )
    let response = try #require(
      HTTPURLResponse(
        url: releaseURL,
        statusCode: 200,
        httpVersion: "HTTP/1.1",
        headerFields: nil
      )
    )
    let data = Data(
      #"{"tag_name":"v0.10.0","html_url":"https://github.com/Diandd/CodexDone/releases/tag/v0.10.0"}"#
        .utf8
    )

    #expect(
      try GitHubReleaseUpdateService.result(
        data: data,
        response: response,
        currentVersion: "0.9.0"
      ) == .updateAvailable(GitHubRelease(version: "0.10.0", pageURL: releaseURL))
    )
    #expect(
      try GitHubReleaseUpdateService.result(
        data: data,
        response: response,
        currentVersion: "0.10.0"
      ) == .upToDate(latestVersion: "0.10.0")
    )
    #expect(ReleaseVersion("v1.0") == ReleaseVersion("1.0.0"))
  }

  @Test("中英文资源随应用打包并覆盖核心界面")
  func bundledLocalizationsCoverCoreSurfaces() throws {
    let chinese = try localizedBundle("zh-Hans")
    let english = try localizedBundle("en")

    #expect(L10n.text("设置", bundle: chinese) == "设置")
    #expect(L10n.text("设置", bundle: english) == "Settings")
    #expect(L10n.text("语言", bundle: english) == "Language")
    #expect(
      L10n.text("打开 ChatGPT 设置 → 钩子 → 用户配置", bundle: english)
        == "Open ChatGPT Settings → Hooks → User Configuration"
    )
    #expect(L10n.text("欢迎使用 CodexDone", bundle: english) == "Welcome to CodexDone")
    #expect(
      L10n.text("Codex 本轮停下时，提醒你回来查看", bundle: english)
        == "Get notified when a Codex turn stops and is ready to review"
    )
    #expect(L10n.text("完成必要设置", bundle: english) == "Finish Setup")
    #expect(L10n.text("选择提示方式", bundle: english) == "Choose an Alert Style")
    #expect(L10n.text("开启提醒", bundle: english) == "Enable Alerts")
    #expect(
      L10n.text("以后可在“设置 → 常规 → 提醒”中更改", bundle: english)
        == "You can change this later in Settings → General → Alerts"
    )
    #expect(L10n.text("Codex 本轮已停止", bundle: english) == "Codex turn stopped")
    #expect(L10n.text("全屏外观", bundle: english) == "Full-Screen Appearance")
    #expect(L10n.text("自定义背景图", bundle: english) == "Custom Background Image")
    #expect(L10n.text("背景透明度", bundle: english) == "Background Opacity")
    #expect(L10n.text("图片模糊度", bundle: english) == "Image Blur")
    #expect(L10n.text("背景模糊度", bundle: english) == "Background Blur")
    #expect(L10n.text("留空使用默认", bundle: english) == "Leave blank to use the default")
    #expect(L10n.text("纯色", bundle: english) == "Solid Color")
    #expect(L10n.text("仅模糊", bundle: english) == "Blur Only")
    #expect(L10n.text("正在使用 Mac 时", bundle: english) == "While Using Your Mac")
    #expect(L10n.text("暂时离开时", bundle: english) == "While Away")
    #expect(L10n.text("使用自定义音频", bundle: english) == "Use Custom Audio")
    #expect(L10n.text("测试全屏提示", bundle: english) == "Test Full-Screen Alert")
    #expect(L10n.text("接收时间", bundle: english) == "Received At")
    #expect(L10n.text("接收方式", bundle: english) == "Delivery Path")
    #expect(L10n.text("内容形态", bundle: english) == "Content Shape")
    #expect(L10n.text("处理结果", bundle: english) == "Processing Result")
    #expect(L10n.text("发送内容", bundle: english) == "Submitted Message")
    #expect(L10n.text("回复内容", bundle: english) == "Assistant Reply")
    #expect(
      L10n.text("输入回复正则", bundle: english)
        == "Enter an assistant-reply regular expression"
    )
    #expect(
      L10n.text("屏蔽类似发送内容", bundle: english)
        == "Block Similar Submitted Messages"
    )
    #expect(L10n.text("已展开", bundle: english) == "Expanded")
    #expect(L10n.text("已收起", bundle: english) == "Collapsed")
    #expect(L10n.text("检查更新", bundle: english) == "Check for Updates")
    #expect(
      L10n.text("GitHub 仓库尚未配置", bundle: english)
        == "GitHub repository is not configured"
    )
    #expect(L10n.text("alert.visualMode.none", bundle: chinese) == "关闭提示")
    #expect(L10n.text("alert.visualMode.smart", bundle: chinese) == "智能提醒")
    #expect(L10n.text("alert.visualMode.hud", bundle: chinese) == "顶部提示")
    #expect(L10n.text("alert.visualMode.notch", bundle: chinese) == "刘海提示")
    #expect(L10n.text("alert.visualMode.fullscreen", bundle: chinese) == "全屏提示")
    #expect(L10n.text("alert.visualMode.none", bundle: english) == "Alerts Off")
    #expect(L10n.text("alert.visualMode.smart", bundle: english) == "Smart Alerts")
    #expect(L10n.text("alert.visualMode.hud", bundle: english) == "Top Alert")
    #expect(L10n.text("alert.visualMode.notch", bundle: english) == "Notch Alert")
    #expect(
      L10n.text("alert.visualMode.fullscreen", bundle: english) == "Full-Screen Alert"
    )
    #expect(L10n.text("提醒显示屏", bundle: english) == "Alert Displays")
    #expect(L10n.text("跟随焦点", bundle: english) == "Follow Focus")
    #expect(
      L10n.format(
        "%lld 条待查看",
        arguments: [Int64(2)],
        locale: Locale(identifier: "en_US"),
        bundle: english
      ) == "2 to review"
    )
  }

  @Test("应用内语言偏好持久化并选择对应资源")
  @MainActor
  func applicationLanguagePreferencePersists() throws {
    let suiteName = "ApplicationLocalizationTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let localization = ApplicationLocalization(defaults: defaults)
    let appBundle = try #require(Bundle(identifier: ProductConfiguration.bundleIdentifier))

    #expect(localization.preference == .system)
    localization.select(.english)
    #expect(localization.preference == .english)
    #expect(
      defaults.string(forKey: ApplicationLanguagePreference.storageKey)
        == ApplicationLanguagePreference.english.rawValue
    )
    #expect(
      L10n.text("设置", preference: .english, rootBundle: appBundle) == "Settings"
    )

    localization.select(.simplifiedChinese)
    #expect(localization.preference == .simplifiedChinese)
    #expect(
      L10n.text("设置", preference: .simplifiedChinese, rootBundle: appBundle) == "设置"
    )
  }

  @Test("英文翻译表不残留中文界面值")
  func englishLocalizationHasNoChineseValues() throws {
    let english = try localizedBundle("en")
    let url = try #require(english.url(forResource: "Localizable", withExtension: "strings"))
    let data = try Data(contentsOf: url)
    let object = try PropertyListSerialization.propertyList(from: data, format: nil)
    let translations = try #require(object as? [String: String])

    #expect(translations.count >= 170)
    for value in translations.values {
      #expect(!containsHanCharacter(value))
    }
  }

  @Test("中英文固定界面文案末尾不使用句号")
  func localizedInterfaceCopyHasNoTerminalPeriods() throws {
    for language in ["zh-Hans", "en"] {
      let bundle = try localizedBundle(language)
      let url = try #require(bundle.url(forResource: "Localizable", withExtension: "strings"))
      let data = try Data(contentsOf: url)
      let object = try PropertyListSerialization.propertyList(from: data, format: nil)
      let translations = try #require(object as? [String: String])

      for value in translations.values {
        #expect(!value.hasSuffix("。"))
        #expect(!value.hasSuffix("."))
      }
    }
  }

  private func localizedBundle(_ language: String) throws -> Bundle {
    let appBundle = try #require(Bundle(identifier: ProductConfiguration.bundleIdentifier))
    let path = try #require(appBundle.path(forResource: language, ofType: "lproj"))
    return try #require(Bundle(path: path))
  }

  private func containsHanCharacter(_ value: String) -> Bool {
    value.unicodeScalars.contains { scalar in
      (0x3400...0x4DBF).contains(scalar.value)
        || (0x4E00...0x9FFF).contains(scalar.value)
    }
  }
}
