import Foundation
import Observation
import SwiftUI

enum ApplicationLanguagePreference: String, CaseIterable, Identifiable, Sendable {
  case system
  case simplifiedChinese = "zh-Hans"
  case english = "en"

  static let storageKey = "localization.language"

  var id: String { rawValue }

  init(storedValue: String?) {
    self = Self(rawValue: storedValue ?? "") ?? .system
  }

  var title: String {
    switch self {
    case .system: L10n.text("跟随系统")
    case .simplifiedChinese: "简体中文"
    case .english: "English"
    }
  }

  var locale: Locale {
    switch self {
    case .system: .autoupdatingCurrent
    case .simplifiedChinese: Locale(identifier: "zh-Hans")
    case .english: Locale(identifier: "en")
    }
  }

  static func current(defaults: UserDefaults = .standard) -> Self {
    Self(storedValue: defaults.string(forKey: storageKey))
  }

  func localizedBundle(in rootBundle: Bundle = .main) -> Bundle {
    guard self != .system,
      let path = rootBundle.path(forResource: rawValue, ofType: "lproj"),
      let bundle = Bundle(path: path)
    else {
      return rootBundle
    }
    return bundle
  }
}

@MainActor
@Observable
final class ApplicationLocalization {
  static let shared = ApplicationLocalization(
    defaults: .standard,
    activatesGlobally: true
  )

  @ObservationIgnored private let defaults: UserDefaults
  @ObservationIgnored private let activatesGlobally: Bool
  private(set) var preference: ApplicationLanguagePreference

  init(
    defaults: UserDefaults = .standard,
    activatesGlobally: Bool = false
  ) {
    self.defaults = defaults
    self.activatesGlobally = activatesGlobally
    preference = ApplicationLanguagePreference.current(defaults: defaults)
    if activatesGlobally {
      L10n.activate(preference)
    }
  }

  var locale: Locale { preference.locale }

  func select(_ preference: ApplicationLanguagePreference) {
    guard self.preference != preference else { return }
    defaults.set(preference.rawValue, forKey: ApplicationLanguagePreference.storageKey)
    if activatesGlobally {
      L10n.activate(preference)
    }
    self.preference = preference
  }
}

struct ApplicationLocalizedView<Content: View>: View {
  let content: Content
  let localization: ApplicationLocalization

  var body: some View {
    content
      .environment(localization)
      .environment(\.locale, localization.locale)
      .id(localization.preference.rawValue)
  }
}

extension View {
  func applicationLocalized(
    using localization: ApplicationLocalization
  ) -> ApplicationLocalizedView<Self> {
    ApplicationLocalizedView(content: self, localization: localization)
  }
}

private final class ActiveApplicationLanguage: @unchecked Sendable {
  private let lock = NSLock()
  private var preference = ApplicationLanguagePreference.current()

  func read() -> ApplicationLanguagePreference {
    lock.withLock { preference }
  }

  func write(_ preference: ApplicationLanguagePreference) {
    lock.withLock { self.preference = preference }
  }
}

enum L10n {
  private static let activeLanguage = ActiveApplicationLanguage()

  static func activate(_ preference: ApplicationLanguagePreference) {
    activeLanguage.write(preference)
  }

  static func text(_ key: String, bundle: Bundle? = nil) -> String {
    let resolvedBundle =
      bundle
      ?? activeLanguage.read().localizedBundle()
    return resolvedBundle.localizedString(forKey: key, value: key, table: "Localizable")
  }

  static func text(
    _ key: String,
    preference: ApplicationLanguagePreference,
    rootBundle: Bundle = .main
  ) -> String {
    text(key, bundle: preference.localizedBundle(in: rootBundle))
  }

  static func format(_ key: String, _ arguments: CVarArg...) -> String {
    format(key, arguments: arguments)
  }

  static func format(
    _ key: String,
    arguments: [CVarArg],
    locale: Locale? = nil,
    bundle: Bundle? = nil
  ) -> String {
    let resolvedLocale = locale ?? activeLanguage.read().locale
    return String(
      format: text(key, bundle: bundle),
      locale: resolvedLocale,
      arguments: arguments
    )
  }
}
