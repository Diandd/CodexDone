import AppKit
import Foundation
import ImageIO
import Observation
import SwiftUI

enum AlertHeadlineChannel: String, CaseIterable, Identifiable, Sendable {
  case fullscreen
  case hud
  case notification

  static let maximumLength = 40

  var id: String { rawValue }

  var title: String {
    switch self {
    case .fullscreen: L10n.text("全屏提示")
    case .hud: L10n.text("顶部 HUD")
    case .notification: L10n.text("系统通知")
    }
  }

  var storageKey: String {
    switch self {
    case .fullscreen: "alerts.overlay.customHeadline"
    case .hud: "alerts.hud.customHeadline"
    case .notification: "alerts.notification.customHeadline"
    }
  }

  func customTitle(defaults: UserDefaults = .standard) -> String? {
    Self.normalized(defaults.string(forKey: storageKey))
  }

  func resolvedTitle(
    for situation: AlertSituation,
    defaults: UserDefaults = .standard
  ) -> String {
    customTitle(defaults: defaults) ?? situation.alertTitle
  }

  static func editableValue(_ value: String) -> String {
    String(value.replacingOccurrences(of: "\n", with: " ").prefix(maximumLength))
  }

  static func normalized(_ value: String?) -> String? {
    guard let value else { return nil }
    let collapsed =
      value
      .components(separatedBy: .whitespacesAndNewlines)
      .filter { !$0.isEmpty }
      .joined(separator: " ")
    guard !collapsed.isEmpty else { return nil }
    return String(collapsed.prefix(maximumLength))
  }
}

enum OverlayBackgroundStyle: String, CaseIterable, Identifiable, Sendable {
  case solid
  case gradient
  case blurOnly
  case image

  var id: String { rawValue }

  var title: String {
    switch self {
    case .solid: L10n.text("纯色")
    case .gradient: L10n.text("渐变色")
    case .blurOnly: L10n.text("仅模糊")
    case .image: L10n.text("自定义图片")
    }
  }

  init(storedValue: String?) {
    self = Self(rawValue: storedValue ?? "") ?? .gradient
  }
}

enum OverlayAppearanceKeys {
  static let backgroundStyle = "alerts.overlay.backgroundStyle"
  static let solidColor = "alerts.overlay.solidColor"
  static let gradientStartColor = "alerts.overlay.gradientStartColor"
  static let gradientEndColor = "alerts.overlay.gradientEndColor"
  static let backgroundOpacity = "alerts.overlay.backgroundOpacity"
  static let backgroundBlur = "alerts.overlay.backgroundBlur"
  static let blurOnlyIntensity = "alerts.overlay.blurOnlyIntensity"
  static let imageBlur = "alerts.overlay.imageBlur"
  static let backgroundImageDisplayName = "alerts.overlay.backgroundImageDisplayName"
}

struct OverlayAppearanceConfiguration: Equatable, Sendable {
  static let defaultSolidHex = "#08753B"
  static let defaultGradientStartHex = "#08753B"
  static let defaultGradientEndHex = "#031A0F"
  static let defaultOpacity = 0.72
  static let defaultBlurRadius = 0.0
  static let defaultBlurOnlyIntensity = 0.85
  static let defaultImageBlurRadius = 0.0
  static let opacityRange = 0.0...1.0
  static let blurRange = 0.0...40.0
  static let blurOnlyIntensityRange = 0.0...1.0
  static let imageBlurRange = 0.0...40.0

  let backgroundStyle: OverlayBackgroundStyle
  let solidHex: String
  let gradientStartHex: String
  let gradientEndHex: String
  let opacity: Double
  let blurRadius: Double
  let blurOnlyIntensity: Double
  let imageBlurRadius: Double
  let imageURL: URL?

  var usesBackdropBlur: Bool {
    switch backgroundStyle {
    case .solid, .gradient, .blurOnly: true
    case .image: false
    }
  }

  var backdropBlurIntensity: Double {
    switch backgroundStyle {
    case .solid, .gradient:
      guard Self.blurRange.upperBound > 0 else { return 0 }
      return (blurRadius / Self.blurRange.upperBound).clamped(to: 0...1)
    case .blurOnly:
      return blurOnlyIntensity
    case .image:
      return 0
    }
  }

  static let defaultConfiguration = Self(
    backgroundStyle: .gradient,
    solidHex: defaultSolidHex,
    gradientStartHex: defaultGradientStartHex,
    gradientEndHex: defaultGradientEndHex,
    opacity: defaultOpacity,
    blurRadius: defaultBlurRadius,
    blurOnlyIntensity: defaultBlurOnlyIntensity,
    imageBlurRadius: defaultImageBlurRadius,
    imageURL: nil
  )

  init(
    backgroundStyle: OverlayBackgroundStyle,
    solidHex: String,
    gradientStartHex: String,
    gradientEndHex: String,
    opacity: Double,
    blurRadius: Double,
    blurOnlyIntensity: Double = Self.defaultBlurOnlyIntensity,
    imageBlurRadius: Double,
    imageURL: URL?
  ) {
    self.backgroundStyle = backgroundStyle
    self.solidHex = OverlayColorCodec.normalizedHex(
      solidHex,
      fallback: Self.defaultSolidHex
    )
    self.gradientStartHex = OverlayColorCodec.normalizedHex(
      gradientStartHex,
      fallback: Self.defaultGradientStartHex
    )
    self.gradientEndHex = OverlayColorCodec.normalizedHex(
      gradientEndHex,
      fallback: Self.defaultGradientEndHex
    )
    self.opacity = opacity.clamped(to: Self.opacityRange)
    self.blurRadius = blurRadius.clamped(to: Self.blurRange)
    self.blurOnlyIntensity = blurOnlyIntensity.clamped(to: Self.blurOnlyIntensityRange)
    self.imageBlurRadius = imageBlurRadius.clamped(to: Self.imageBlurRange)
    self.imageURL = backgroundStyle == .image ? imageURL : nil
  }

  init(defaults: UserDefaults, imageURL: URL?) {
    self.init(
      backgroundStyle: OverlayBackgroundStyle(
        storedValue: defaults.string(forKey: OverlayAppearanceKeys.backgroundStyle)
      ),
      solidHex: defaults.string(
        forKey: OverlayAppearanceKeys.solidColor
      ) ?? Self.defaultSolidHex,
      gradientStartHex: defaults.string(
        forKey: OverlayAppearanceKeys.gradientStartColor
      ) ?? Self.defaultGradientStartHex,
      gradientEndHex: defaults.string(
        forKey: OverlayAppearanceKeys.gradientEndColor
      ) ?? Self.defaultGradientEndHex,
      opacity: defaults.object(forKey: OverlayAppearanceKeys.backgroundOpacity) as? Double
        ?? Self.defaultOpacity,
      blurRadius: defaults.object(forKey: OverlayAppearanceKeys.backgroundBlur) as? Double
        ?? Self.defaultBlurRadius,
      blurOnlyIntensity: defaults.object(
        forKey: OverlayAppearanceKeys.blurOnlyIntensity
      ) as? Double ?? Self.defaultBlurOnlyIntensity,
      imageBlurRadius: defaults.object(forKey: OverlayAppearanceKeys.imageBlur) as? Double
        ?? Self.defaultImageBlurRadius,
      imageURL: imageURL
    )
  }
}

enum OverlayColorCodec {
  static func normalizedHex(_ value: String, fallback: String) -> String {
    let candidate = value.trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "#", with: "")
      .uppercased()
    guard candidate.count == 6, UInt64(candidate, radix: 16) != nil else {
      return fallback
    }
    return "#\(candidate)"
  }

  static func components(
    for value: String,
    fallback: String
  ) -> (red: Double, green: Double, blue: Double) {
    let normalized = normalizedHex(value, fallback: fallback)
    let raw = String(normalized.dropFirst())
    let number = UInt64(raw, radix: 16) ?? 0
    return (
      Double((number >> 16) & 0xFF) / 255,
      Double((number >> 8) & 0xFF) / 255,
      Double(number & 0xFF) / 255
    )
  }

  @MainActor
  static func color(for value: String, fallback: String) -> Color {
    let components = components(for: value, fallback: fallback)
    return Color(
      red: components.red,
      green: components.green,
      blue: components.blue
    )
  }

  @MainActor
  static func hex(for color: Color, fallback: String) -> String {
    guard let resolved = NSColor(color).usingColorSpace(.sRGB) else { return fallback }
    return String(
      format: "#%02X%02X%02X",
      Int((resolved.redComponent * 255).rounded()),
      Int((resolved.greenComponent * 255).rounded()),
      Int((resolved.blueComponent * 255).rounded())
    )
  }
}

enum OverlayBackgroundImageError: LocalizedError, Equatable {
  case unsupportedFormat
  case fileTooLarge
  case invalidImage
  case dimensionsTooLarge

  var errorDescription: String? {
    switch self {
    case .unsupportedFormat: L10n.text("请选择图片文件。")
    case .fileTooLarge: L10n.text("背景图不能超过 20 MB。")
    case .invalidImage: L10n.text("该文件不是有效的图片。")
    case .dimensionsTooLarge: L10n.text("背景图像素不能超过 6400 万。")
    }
  }
}

@MainActor
@Observable
final class OverlayAppearanceService {
  static let maximumImageBytes = 20 * 1_024 * 1_024
  static let maximumPixelCount = 64_000_000
  static let supportedExtensions: Set<String> = [
    "heic", "heif", "jpeg", "jpg", "png", "tif", "tiff",
  ]

  private(set) var customImageDisplayName: String?

  @ObservationIgnored private let defaults: UserDefaults
  @ObservationIgnored private let fileManager: FileManager
  @ObservationIgnored private let customImageURL: URL

  init(
    defaults: UserDefaults = .standard,
    fileManager: FileManager = .default,
    customImageURL: URL = HookRuntimePaths.overlayBackgroundImageURL
  ) {
    self.defaults = defaults
    self.fileManager = fileManager
    self.customImageURL = customImageURL
    if fileManager.fileExists(atPath: customImageURL.path) {
      customImageDisplayName = defaults.string(
        forKey: OverlayAppearanceKeys.backgroundImageDisplayName
      )
    } else {
      customImageDisplayName = nil
      if OverlayBackgroundStyle(
        storedValue: defaults.string(forKey: OverlayAppearanceKeys.backgroundStyle)
      ) == .image {
        defaults.set(
          OverlayBackgroundStyle.gradient.rawValue,
          forKey: OverlayAppearanceKeys.backgroundStyle
        )
      }
    }
  }

  var hasCustomImage: Bool {
    fileManager.fileExists(atPath: customImageURL.path)
  }

  func configuration() -> OverlayAppearanceConfiguration {
    OverlayAppearanceConfiguration(
      defaults: defaults,
      imageURL: hasCustomImage ? customImageURL : nil
    )
  }

  func restoreDefaults() {
    defaults.set(
      OverlayBackgroundStyle.gradient.rawValue,
      forKey: OverlayAppearanceKeys.backgroundStyle
    )
    defaults.set(
      OverlayAppearanceConfiguration.defaultSolidHex,
      forKey: OverlayAppearanceKeys.solidColor
    )
    defaults.set(
      OverlayAppearanceConfiguration.defaultGradientStartHex,
      forKey: OverlayAppearanceKeys.gradientStartColor
    )
    defaults.set(
      OverlayAppearanceConfiguration.defaultGradientEndHex,
      forKey: OverlayAppearanceKeys.gradientEndColor
    )
    defaults.set(
      OverlayAppearanceConfiguration.defaultOpacity,
      forKey: OverlayAppearanceKeys.backgroundOpacity
    )
    defaults.set(
      OverlayAppearanceConfiguration.defaultBlurRadius,
      forKey: OverlayAppearanceKeys.backgroundBlur
    )
    defaults.set(
      OverlayAppearanceConfiguration.defaultBlurOnlyIntensity,
      forKey: OverlayAppearanceKeys.blurOnlyIntensity
    )
    defaults.set(
      OverlayAppearanceConfiguration.defaultImageBlurRadius,
      forKey: OverlayAppearanceKeys.imageBlur
    )
    AppLog.alerts.notice("The overlay appearance was restored to defaults")
  }

  func importImage(from sourceURL: URL) throws {
    guard Self.supportedExtensions.contains(sourceURL.pathExtension.lowercased()) else {
      throw OverlayBackgroundImageError.unsupportedFormat
    }
    let accessed = sourceURL.startAccessingSecurityScopedResource()
    defer { if accessed { sourceURL.stopAccessingSecurityScopedResource() } }

    let values = try sourceURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
    guard values.isRegularFile == true else {
      throw OverlayBackgroundImageError.invalidImage
    }
    guard (values.fileSize ?? 0) <= Self.maximumImageBytes else {
      throw OverlayBackgroundImageError.fileTooLarge
    }
    guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
      CGImageSourceGetCount(source) > 0,
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
        as? [CFString: Any],
      let width = properties[kCGImagePropertyPixelWidth] as? Int,
      let height = properties[kCGImagePropertyPixelHeight] as? Int,
      width > 0,
      height > 0
    else {
      throw OverlayBackgroundImageError.invalidImage
    }
    guard width <= Self.maximumPixelCount / height else {
      throw OverlayBackgroundImageError.dimensionsTooLarge
    }

    let directory = customImageURL.deletingLastPathComponent()
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    let staging = directory.appendingPathComponent(".overlay-\(UUID().uuidString).image")
    defer { try? fileManager.removeItem(at: staging) }
    try fileManager.copyItem(at: sourceURL, to: staging)
    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staging.path)
    if fileManager.fileExists(atPath: customImageURL.path) {
      _ = try fileManager.replaceItemAt(customImageURL, withItemAt: staging)
    } else {
      try fileManager.moveItem(at: staging, to: customImageURL)
    }
    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: customImageURL.path)

    customImageDisplayName = String(sourceURL.lastPathComponent.prefix(80))
    defaults.set(
      customImageDisplayName,
      forKey: OverlayAppearanceKeys.backgroundImageDisplayName
    )
    defaults.set(
      OverlayBackgroundStyle.image.rawValue,
      forKey: OverlayAppearanceKeys.backgroundStyle
    )
    AppLog.alerts.notice("A validated custom overlay background was imported")
  }

  func removeCustomImage() throws {
    if fileManager.fileExists(atPath: customImageURL.path) {
      try fileManager.removeItem(at: customImageURL)
    }
    customImageDisplayName = nil
    defaults.removeObject(forKey: OverlayAppearanceKeys.backgroundImageDisplayName)
    defaults.set(
      OverlayBackgroundStyle.gradient.rawValue,
      forKey: OverlayAppearanceKeys.backgroundStyle
    )
    AppLog.alerts.notice("The custom overlay background was removed")
  }
}

extension Comparable {
  fileprivate func clamped(to range: ClosedRange<Self>) -> Self {
    min(max(self, range.lowerBound), range.upperBound)
  }
}
