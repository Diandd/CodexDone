import SwiftUI

struct CompletionHUDView: View {
  static let preferredSize = CGSize(width: 410, height: 82)

  let alert: AlertPresentation
  let headline: String

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: alert.situation.systemImage)
        .font(.title3)
        .foregroundStyle(.green)
        .padding(.top, 1)

      VStack(alignment: .leading, spacing: 2) {
        Text(headline)
          .font(.headline)
          .lineLimit(1)

        Text(alert.conversationTitle ?? L10n.text("Codex 对话"))
          .font(.callout)
          .fontWeight(.medium)
          .lineLimit(1)
          .privacySensitive()
          .accessibilityIdentifier("completion-hud-conversation-title")

        Label(alert.projectDisplayName, systemImage: "folder")
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .privacySensitive()
          .accessibilityIdentifier("completion-hud-project")
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .frame(
      width: Self.preferredSize.width,
      height: Self.preferredSize.height,
      alignment: .leading
    )
    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("completion-hud")
  }
}
