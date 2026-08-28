import AppKit
import SwiftUI

struct MenuBarContentView: View {
  @Environment(AppEnvironment.self) private var environment
  @AppStorage("alerts.visualMode") private var visualMode = AlertVisualMode.defaultMode.rawValue

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
        .padding(.horizontal, 16)
        .padding(.vertical, 12)

      Divider()

      Group {
        if environment.completionStore.unreadRecords.isEmpty {
          ContentUnavailableView(
            "没有待查看对话",
            systemImage: "checkmark.circle",
            description: Text("Codex 每轮停止后会出现在这里。")
          )
          .accessibilityIdentifier("menu-empty-state")
        } else {
          ScrollView {
            LazyVStack(spacing: 0) {
              ForEach(environment.completionStore.unreadRecords) { record in
                completionRow(record)
                if record.id != environment.completionStore.unreadRecords.last?.id {
                  Divider()
                    .padding(.leading, 30)
                }
              }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
          }
          .accessibilityIdentifier("menu-unread-list")
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)

      Divider()
      footer
        .padding(12)
    }
    .frame(
      width: StatusItemPopoverLayout.size.width,
      height: StatusItemPopoverLayout.size.height
    )
    .task {
      await environment.refreshHealth()
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("menu-popover-root")
  }

  private var header: some View {
    HStack(alignment: .center, spacing: 10) {
      Text(
        environment.completionStore.unreadCount > 0
          ? L10n.format(
            "%lld 条待查看",
            Int64(environment.completionStore.unreadCount)
          )
          : L10n.text("暂无待查看")
      )
      .font(.headline)
      .fixedSize(horizontal: true, vertical: false)
      .layoutPriority(1)

      Spacer(minLength: 8)

      if let healthWarning {
        Label(healthWarning, systemImage: "exclamationmark.triangle.fill")
          .font(.caption)
          .foregroundStyle(.orange)
          .lineLimit(1)
          .minimumScaleFactor(0.85)
          .accessibilityIdentifier("menu-health-warning")
      }

      if environment.completionStore.unreadCount > 0 {
        Button("全部已查看") {
          environment.completionStore.acknowledgeAll()
        }
        .buttonStyle(.link)
        .controlSize(.small)
        .fixedSize()
        .accessibilityIdentifier("menu-acknowledge-all")
      }
    }
  }

  private func completionRow(_ record: ConversationCompletionRecord) -> some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: "bubble.left.and.exclamationmark.bubble.right.fill")
        .font(.body)
        .foregroundStyle(.green)
        .frame(width: 20)
        .padding(.top, 3)

      VStack(alignment: .leading, spacing: 6) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text(record.conversationTitle ?? L10n.text("Codex 对话"))
            .font(.headline)
            .lineLimit(1)
            .privacySensitive()
            .accessibilityIdentifier("menu-conversation-title-\(record.id)")

          Spacer(minLength: 8)

          Button("已查看") {
            environment.completionStore.acknowledge(recordID: record.id)
          }
          .controlSize(.small)
          .accessibilityIdentifier("menu-acknowledge-\(record.id)")
        }

        HStack(spacing: 4) {
          Image(systemName: "folder")
          Text(record.projectDisplayName)
            .lineLimit(1)
            .privacySensitive()
            .accessibilityIdentifier("menu-project-\(record.id)")
          Text("·")
          Text(record.completedAt, style: .relative)
        }
        .font(.caption)
        .foregroundStyle(.tertiary)

        Text(record.replyPreview ?? L10n.text("本轮已停止，可以回来查看"))
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .lineLimit(2)
          .fixedSize(horizontal: false, vertical: true)
          .privacySensitive()
          .accessibilityIdentifier("menu-reply-preview-\(record.id)")
      }
    }
    .padding(.horizontal, 2)
    .padding(.vertical, 12)
  }

  private var footer: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        SettingsLink {
          Label("设置", systemImage: "gearshape")
            .accessibilityIdentifier("menu-open-settings")
        }
        .accessibilityLabel("设置")

        Menu {
          ForEach(AlertVisualMode.allCases) { mode in
            Button {
              visualMode = mode.rawValue
            } label: {
              if visualMode == mode.rawValue {
                Label(mode.title, systemImage: "checkmark")
              } else {
                Text(mode.title)
              }
            }
          }
        } label: {
          Text(AlertVisualMode(storedValue: visualMode).title)
        }
        .fixedSize()
        .accessibilityLabel(AlertVisualMode(storedValue: visualMode).title)
        .accessibilityIdentifier("menu-visual-mode-menu")

        Button("打开 Codex") {
          environment.openCodex()
        }
        .accessibilityIdentifier("menu-open-codex")

        Spacer()

        Button {
          NSApplication.shared.terminate(nil)
        } label: {
          Image(systemName: "power")
        }
        .help("退出 CodexDone")
        .accessibilityIdentifier("menu-quit")
      }

      if let failure = environment.systemIntegrationService.lastCodexOpenFailure {
        Text(failure.userMessage)
          .font(.caption)
          .foregroundStyle(.orange)
          .accessibilityIdentifier("menu-open-codex-error")
      }
    }
  }

  private var healthWarning: String? {
    if !environment.hookInspection.helperIsExecutable {
      return L10n.text("Hook Bridge 不可用")
    }
    if !environment.hookInspection.isInstalled { return L10n.text("Hook 尚未安装") }
    if environment.hookStatusInspection.availability == .available,
      !environment.hookConnectionIsReady
    {
      return environment.hookConnectionStatusTitle
    }
    if !environment.isSocketListening { return L10n.text("Socket 离线，使用 Spool") }
    return nil
  }
}
