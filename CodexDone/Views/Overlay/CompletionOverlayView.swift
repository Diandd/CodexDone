import AppKit
import SwiftUI

struct OverlayPresentation: Equatable, Sendable {
  let situation: AlertSituation
  let alerts: [AlertPresentation]
  let headlineOverride: String?

  var latestAlert: AlertPresentation? { alerts.last }

  var headline: String {
    if let headlineOverride = AlertHeadlineChannel.normalized(headlineOverride) {
      return headlineOverride
    }
    guard alerts.count > 1 else { return situation.alertTitle }
    return L10n.format("%lld 个对话待查看", Int64(alerts.count))
  }

  var additionalSummary: String? {
    guard alerts.count > 1 else { return nil }
    return L10n.format("另有 %lld 个对话", Int64(alerts.count - 1))
  }
}

enum OverlayImageFillLayout {
  static func centeredFrame(
    imageSize: CGSize,
    containerSize: CGSize
  ) -> CGRect {
    guard imageSize.width > 0, imageSize.height > 0,
      containerSize.width > 0, containerSize.height > 0
    else {
      return CGRect(origin: .zero, size: containerSize)
    }
    let scale = max(
      containerSize.width / imageSize.width,
      containerSize.height / imageSize.height
    )
    let fittedSize = CGSize(
      width: imageSize.width * scale,
      height: imageSize.height * scale
    )
    return CGRect(
      x: (containerSize.width - fittedSize.width) / 2,
      y: (containerSize.height - fittedSize.height) / 2,
      width: fittedSize.width,
      height: fittedSize.height
    )
  }

  static func blurScale(radius: Double, containerSize: CGSize) -> CGFloat {
    guard radius > 0 else { return 1 }
    let shortestEdge = max(min(containerSize.width, containerSize.height), 1)
    return 1 + CGFloat(radius * 2) / shortestEdge
  }
}

enum OverlayForegroundTone: Equatable, Sendable {
  case fixedLight
  case systemAdaptive

  init(backgroundStyle: OverlayBackgroundStyle, usesPrivacyShield: Bool) {
    self = backgroundStyle == .blurOnly && !usesPrivacyShield
      ? .systemAdaptive
      : .fixedLight
  }
}

struct CompletionOverlayView: View {
  static let backdropOpacity = 0.72

  let presentation: OverlayPresentation
  let usesPrivacyShield: Bool
  let dismissalMode: OverlayDismissalMode
  let appearance: OverlayAppearanceConfiguration

  init(
    presentation: OverlayPresentation,
    usesPrivacyShield: Bool = false,
    dismissalMode: OverlayDismissalMode = .defaultMode,
    appearance: OverlayAppearanceConfiguration = .defaultConfiguration
  ) {
    self.presentation = presentation
    self.usesPrivacyShield = usesPrivacyShield
    self.dismissalMode = dismissalMode
    self.appearance = appearance
  }

  var body: some View {
    ZStack {
      if usesPrivacyShield {
        Color(red: 0.018, green: 0.035, blue: 0.065)
          .ignoresSafeArea()
          .accessibilityElement()
          .accessibilityLabel(L10n.text("UI 测试脱敏背景"))
          .accessibilityIdentifier("completion-overlay-privacy-shield")
      }

      if !usesPrivacyShield, appearance.usesBackdropBlur {
        OverlayBackdropBlurView(intensity: appearance.backdropBlurIntensity)
          .ignoresSafeArea()
          .accessibilityLabel(L10n.text("背景模糊层"))
          .accessibilityIdentifier("completion-overlay-backdrop-blur")
      }

      backgroundLayer
        .ignoresSafeArea()

      VStack(spacing: 18) {
        Image(systemName: presentation.situation.systemImage)
          .font(.system(size: 66, weight: .semibold))
          .symbolRenderingMode(.hierarchical)

        Text(presentation.headline)
          .font(.system(size: 42, weight: .bold, design: .rounded))
          .multilineTextAlignment(.center)
          .lineLimit(2)
          .accessibilityIdentifier("completion-overlay-headline")

        if let alert = presentation.latestAlert {
          Text(alert.conversationTitle ?? L10n.text("Agent 对话"))
            .font(.system(size: 28, weight: .semibold, design: .rounded))
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .privacySensitive()
            .accessibilityIdentifier("completion-overlay-conversation-title")

          Label(alert.projectDisplayName, systemImage: "folder")
            .font(.title3)
            .foregroundStyle(secondaryForegroundColor)
            .lineLimit(1)
            .privacySensitive()
            .accessibilityIdentifier("completion-overlay-project")
        }

        if let additionalSummary = presentation.additionalSummary {
          Text(additionalSummary)
            .font(.headline)
            .foregroundStyle(secondaryForegroundColor)
        }

        Text(dismissalMode.instruction)
          .font(.callout)
          .foregroundStyle(tertiaryForegroundColor)
          .padding(.top, 4)
      }
      .foregroundStyle(primaryForegroundColor)
      .padding(48)
      .frame(maxWidth: 760)
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("completion-overlay")
  }

  @ViewBuilder
  private var backgroundLayer: some View {
    if usesPrivacyShield {
      OverlayColorCodec.color(
        for: appearance.solidHex,
        fallback: OverlayAppearanceConfiguration.defaultSolidHex
      )
      .opacity(appearance.opacity)
      .accessibilityLabel(L10n.text("纯色背景"))
      .accessibilityIdentifier("completion-overlay-background-solid")
    } else {
      switch appearance.backgroundStyle {
      case .solid:
        OverlayColorCodec.color(
          for: appearance.solidHex,
          fallback: OverlayAppearanceConfiguration.defaultSolidHex
        )
        .opacity(appearance.opacity)
        .accessibilityLabel(L10n.text("纯色背景"))
        .accessibilityIdentifier("completion-overlay-background-solid")
      case .gradient:
        gradientBackground
          .opacity(appearance.opacity)
      case .blurOnly:
        Color.clear
          .accessibilityLabel(L10n.text("仅模糊背景"))
          .accessibilityIdentifier("completion-overlay-background-blur-only")
      case .image:
        if let imageURL = appearance.imageURL,
          let image = NSImage(contentsOf: imageURL)
        {
          centeredImage(image)
            .opacity(appearance.opacity)
        } else {
          OverlayColorCodec.color(
            for: OverlayAppearanceConfiguration.defaultSolidHex,
            fallback: OverlayAppearanceConfiguration.defaultSolidHex
          )
          .opacity(appearance.opacity)
          .accessibilityLabel(L10n.text("纯色背景"))
          .accessibilityIdentifier("completion-overlay-background-image-placeholder")
        }
      }
    }
  }

  private func centeredImage(_ image: NSImage) -> some View {
    GeometryReader { geometry in
      let imageFrame = OverlayImageFillLayout.centeredFrame(
        imageSize: image.size,
        containerSize: geometry.size
      )
      Image(nsImage: image)
        .resizable()
        .frame(width: imageFrame.width, height: imageFrame.height)
        .blur(radius: appearance.imageBlurRadius)
        .scaleEffect(
          OverlayImageFillLayout.blurScale(
            radius: appearance.imageBlurRadius,
            containerSize: geometry.size
          ),
          anchor: .center
        )
        .position(x: imageFrame.midX, y: imageFrame.midY)
    }
    .clipped()
    .privacySensitive()
    .accessibilityLabel(L10n.text("自定义背景图"))
    .accessibilityIdentifier("completion-overlay-background-image")
  }

  private var gradientBackground: some View {
    LinearGradient(
      colors: [
        OverlayColorCodec.color(
          for: appearance.gradientStartHex,
          fallback: OverlayAppearanceConfiguration.defaultGradientStartHex
        ),
        OverlayColorCodec.color(
          for: appearance.gradientEndHex,
          fallback: OverlayAppearanceConfiguration.defaultGradientEndHex
        ),
      ],
      startPoint: .topLeading,
      endPoint: .bottomTrailing
    )
    .accessibilityLabel(L10n.text("渐变色背景"))
    .accessibilityIdentifier("completion-overlay-background-gradient")
  }

  private var foregroundTone: OverlayForegroundTone {
    OverlayForegroundTone(
      backgroundStyle: appearance.backgroundStyle,
      usesPrivacyShield: usesPrivacyShield
    )
  }

  private var primaryForegroundColor: Color {
    switch foregroundTone {
    case .fixedLight: .white
    case .systemAdaptive: Color(nsColor: .labelColor)
    }
  }

  private var secondaryForegroundColor: Color {
    switch foregroundTone {
    case .fixedLight: .white.opacity(0.82)
    case .systemAdaptive: Color(nsColor: .secondaryLabelColor)
    }
  }

  private var tertiaryForegroundColor: Color {
    switch foregroundTone {
    case .fixedLight: .white.opacity(0.68)
    case .systemAdaptive: Color(nsColor: .tertiaryLabelColor)
    }
  }
}

private struct OverlayBackdropBlurView: NSViewRepresentable {
  let intensity: Double

  func makeNSView(context: Context) -> NSVisualEffectView {
    let view = NSVisualEffectView()
    configure(view)
    return view
  }

  func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
    configure(nsView)
  }

  private func configure(_ view: NSVisualEffectView) {
    view.material = .fullScreenUI
    view.blendingMode = .behindWindow
    view.state = .active
    view.isEmphasized = false
    view.alphaValue = CGFloat(min(max(intensity, 0), 1))
  }
}
