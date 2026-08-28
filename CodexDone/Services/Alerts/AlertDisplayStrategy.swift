import AppKit
import Foundation

enum AlertDisplayStrategy: String, CaseIterable, Identifiable, Sendable {
  case all
  case primary
  case focused

  static let defaultStrategy = Self.focused
  static let storageKey = "alerts.displayStrategy"

  var id: String { rawValue }

  var title: String {
    switch self {
    case .all: L10n.text("全部显示屏")
    case .primary: L10n.text("仅主显示屏")
    case .focused: L10n.text("跟随焦点")
    }
  }

  init(storedValue: String?) {
    self = Self(rawValue: storedValue ?? "") ?? Self.defaultStrategy
  }
}

@MainActor
enum AlertScreenSelection {
  static func screens(
    for strategy: AlertDisplayStrategy,
    screens: [NSScreen] = NSScreen.screens,
    focusedScreen: NSScreen? = NSScreen.main
  ) -> [NSScreen] {
    let focusedIndex = focusedScreen.flatMap { focused in
      screens.firstIndex { $0 === focused }
    }
    return selectedIndices(
      for: strategy,
      screenCount: screens.count,
      focusedIndex: focusedIndex
    ).map { screens[$0] }
  }

  static func selectedIndices(
    for strategy: AlertDisplayStrategy,
    screenCount: Int,
    focusedIndex: Int?
  ) -> [Int] {
    guard screenCount > 0 else { return [] }
    switch strategy {
    case .all:
      return Array(0..<screenCount)
    case .primary:
      return [0]
    case .focused:
      guard let focusedIndex, (0..<screenCount).contains(focusedIndex) else {
        return [0]
      }
      return [focusedIndex]
    }
  }
}
