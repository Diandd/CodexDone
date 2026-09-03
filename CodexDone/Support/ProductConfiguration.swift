import Foundation
import OSLog

enum ProductConfiguration {
  static let displayName = "CodexDone"
  static let bundleIdentifier = "com.dianstudios.codexdone"
  static let loggerSubsystem = bundleIdentifier
  static var shortDescription: String {
    L10n.text("Codex 本轮停下时，提醒你回来查看")
  }
  static let settingsWindowID = "settings"
  static let initializationGuidePresentedKey = "onboarding.initializationGuidePresented"
  static let statusItemShowsUnreadCountKey = "menuBar.showUnreadCount"
  static let licenseDisplayName: String? = "MIT License"

  static let githubRepository = GitHubRepository(owner: "Diandd", name: "CodexDone")

  static var marketingVersion: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.3.0"
  }

  static var thirdPartyNotice: String {
    L10n.text(
      "CodexDone 是独立开发的第三方工具，与 OpenAI 不存在隶属、合作、赞助或官方背书关系。Codex 是 OpenAI 的产品和商标。"
    )
  }
}

enum AppLog {
  static let lifecycle = Logger(
    subsystem: ProductConfiguration.loggerSubsystem,
    category: "lifecycle"
  )
  static let hooks = Logger(
    subsystem: ProductConfiguration.loggerSubsystem,
    category: "hooks"
  )
  static let alerts = Logger(
    subsystem: ProductConfiguration.loggerSubsystem,
    category: "alerts"
  )
}
