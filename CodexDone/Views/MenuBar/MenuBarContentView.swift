import AppKit
import SwiftUI

struct MenuBarContentView: View {
  @Environment(AppEnvironment.self) private var environment
  @AppStorage("alerts.visualMode") private var visualMode = AlertVisualMode.defaultMode.rawValue
  let openCodex: () -> Void

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
            systemImage: "tray",
            description: Text("Agent 本轮结束后，消息会出现在这里。")
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
    VStack(alignment: .leading, spacing: 10) {
      Button {
        environment.openCodex(recordID: record.id)
      } label: {
        HStack(alignment: .top, spacing: 12) {
          Image(systemName: record.source.symbol)
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: 34, height: 34)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 9))
          VStack(alignment: .leading, spacing: 5) {
            HStack {
              Text(record.source.title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
              Spacer()
              Text(record.completedAt, style: .relative)
                .font(.caption)
                .foregroundStyle(.tertiary)
            }
            Text(record.conversationTitle ?? L10n.text("Agent 对话"))
              .font(.system(size: 13, weight: .semibold))
              .lineLimit(1)
              .privacySensitive()
              .accessibilityIdentifier("menu-conversation-title-\(record.id)")
            Text(record.replyPreview ?? L10n.text("本轮已停止，可以回来查看"))
              .font(.callout)
              .foregroundStyle(.secondary)
              .lineLimit(2)
              .multilineTextAlignment(.leading)
              .privacySensitive()
              .accessibilityIdentifier("menu-reply-preview-\(record.id)")
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .disabled(!environment.canOpenRecord(record))
      .help(record.terminalSessionID != nil ? L10n.text("在 iTerm2 中打开会话") : L10n.text("打开会话"))
      .accessibilityIdentifier("menu-open-session-\(record.id)")

      HStack(spacing: 8) {
        Label(record.projectDisplayName, systemImage: "folder")
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .privacySensitive()
          .accessibilityIdentifier("menu-project-\(record.id)")
        Spacer()
        Menu {
          if record.conversationTitle != nil {
            Button("屏蔽类似发送内容") { environment.blockSimilarSubmittedMessages(for: record) }
          }
          Button("屏蔽此项目") { environment.blockProject(for: record) }
        } label: {
          Image(systemName: "ellipsis")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("添加屏蔽规则")
        .accessibilityLabel("添加屏蔽规则")
        .accessibilityIdentifier("menu-block-\(record.id)")
        Button("已查看") { environment.completionStore.acknowledge(recordID: record.id) }
          .buttonStyle(.borderless)
          .font(.caption)
          .accessibilityIdentifier("menu-acknowledge-\(record.id)")
      }
      .padding(.leading, 46)
    }
    .padding(.horizontal, 2)
    .padding(.vertical, 14)
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

        if environment.canOpenLatestCodex {
          Button {
            openCodex()
          } label: {
            Label("打开会话", systemImage: "arrow.up.forward.app")
              .labelStyle(.iconOnly)
          }
          .help("打开会话")
          .accessibilityIdentifier("menu-open-codex")
        }

        Spacer()

        Button {
          NSApplication.shared.terminate(nil)
        } label: {
          Image(systemName: "power")
        }
        .help("退出 CodexDone")
        .accessibilityIdentifier("menu-quit")
      }
      .controlSize(.small)
      .buttonStyle(.borderless)

      if let failure = environment.systemIntegrationService.lastCodexOpenFailure
      {
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
    if !environment.hookInspection.isInstalled,
      !environment.additionalHookInspections.values.contains(where: \.isInstalled)
    { return L10n.text("Hook 尚未安装") }
    if environment.hookStatusInspection.availability == .available,
      !environment.hookConnectionIsReady
    {
      return environment.hookConnectionStatusTitle
    }
    if !environment.isSocketListening { return L10n.text("Socket 离线，使用 Spool") }
    return nil
  }
}
