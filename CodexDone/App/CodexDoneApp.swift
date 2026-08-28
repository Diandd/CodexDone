import AppKit
import SwiftUI

enum ApplicationAppearancePreference: String {
  case system
  case light
  case dark

  init(storedValue: String?) {
    self = Self(rawValue: storedValue ?? "") ?? .system
  }

  var appKitAppearance: NSAppearance? {
    switch self {
    case .system: nil
    case .light: NSAppearance(named: .aqua)
    case .dark: NSAppearance(named: .darkAqua)
    }
  }

  @MainActor
  func applyToApplication() {
    NSApplication.shared.appearance = appKitAppearance
  }
}

@main
struct CodexDoneApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @AppStorage("appearance.colorScheme") private var appearanceColorScheme = "system"

  var body: some Scene {
    Settings {
      SettingsRootView {
        appDelegate.presentInitializationGuide()
      }
        .environment(appDelegate.environment)
        .applicationLocalized(using: appDelegate.environment.localization)
        .onAppear {
          ApplicationAppearancePreference(storedValue: appearanceColorScheme)
            .applyToApplication()
        }
        .onChange(of: appearanceColorScheme) { _, value in
          ApplicationAppearancePreference(storedValue: value).applyToApplication()
        }
    }
    .windowResizability(.contentSize)
    .windowToolbarStyle(.unified(showsTitle: true))
  }
}
