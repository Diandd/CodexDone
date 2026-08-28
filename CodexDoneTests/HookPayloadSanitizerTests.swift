import Foundation
import Testing

@testable import CodexDone

struct HookPayloadSanitizerTests {
  @Test("只传递有界派生内容且事件 ID 对同一 Hook 稳定")
  func sanitizesAndDeduplicates() throws {
    let payload = try JSONSerialization.data(
      withJSONObject: [
        "hook_event_name": "UserPromptSubmit",
        "session_id": "session-a",
        "turn_id": "turn-a",
        "cwd": "/tmp/SafeProject",
        "prompt": "前置附件说明\n## My request:\n# 重新设计菜单信息层级",
        "transcript_path": "/private/secret.jsonl",
      ]
    )
    let first = try HookPayloadSanitizer.event(from: payload, receivedAt: .now)
    let second = try HookPayloadSanitizer.event(
      from: payload,
      receivedAt: .now.addingTimeInterval(1)
    )

    #expect(first.eventID == second.eventID)
    #expect(first.eventName == .userPromptSubmit)
    #expect(first.sessionID == "session-a")
    #expect(first.workingDirectory == "/tmp/SafeProject")
    #expect(first.conversationTitle == "重新设计菜单信息层级")
    #expect(first.replyPreview == nil)

    let encoder = JSONEncoder()
    let encoded = try encoder.encode(first)
    let text = String(decoding: encoded, as: UTF8.self)
    #expect(!text.contains("前置附件说明"))
    #expect(!text.contains("\"prompt\""))
    #expect(!text.contains("transcript"))
  }

  @Test("本轮主题取最后一个请求区的最新完整输入")
  func derivesTitleFromLatestSubmittedContent() throws {
    let payload = try JSONSerialization.data(
      withJSONObject: [
        "hook_event_name": "UserPromptSubmit",
        "session_id": "session-title",
        "turn_id": "turn-title",
        "prompt": """
        ## My request:
        旧内容

        ## My request:
        最新一次内容
        补充说明
        """,
      ]
    )

    let event = try HookPayloadSanitizer.event(from: payload)

    #expect(event.conversationTitle == "最新一次内容 补充说明")
  }

  @Test("回复预览折叠空白并严格限制为 180 字")
  func boundsReplyPreview() throws {
    let rawReply = "已完成菜单调整。\n\n" + String(repeating: "回", count: 220)
    let payload = try JSONSerialization.data(
      withJSONObject: [
        "hook_event_name": "Stop",
        "session_id": "session-a",
        "turn_id": "turn-a",
        "last_assistant_message": rawReply,
        "transcript_path": "/private/secret.jsonl",
      ]
    )

    let event = try HookPayloadSanitizer.event(from: payload)
    #expect(event.conversationTitle == nil)
    #expect(event.replyPreview?.hasPrefix("已完成菜单调整。 回") == true)
    #expect(event.replyPreview?.count == HookPayloadSanitizer.maximumReplyPreviewCharacters)
    #expect(event.replyPreview?.hasSuffix("…") == true)
    let encoded = String(decoding: try JSONEncoder().encode(event), as: UTF8.self)
    #expect(!encoded.contains(rawReply))
    #expect(!encoded.contains("last_assistant_message"))
    #expect(!encoded.contains("transcript"))
  }

  @Test("拒绝未支持 Hook 与超大输入")
  func rejectsUnsupportedInput() {
    for eventName in ["PermissionRequest", "SubagentStop"] {
      let unsupported = Data(
        "{\"hook_event_name\":\"(eventName)\",\"session_id\":\"s\",\"turn_id\":\"t\"}".utf8
      )
      #expect(throws: HookPayloadSanitizationError.unsupportedEvent) {
        try HookPayloadSanitizer.event(from: unsupported)
      }
    }
    let oversized = Data(repeating: 0x20, count: HookPayloadSanitizer.maximumPayloadBytes + 1)
    #expect(throws: HookPayloadSanitizationError.payloadTooLarge) {
      try HookPayloadSanitizer.event(from: oversized)
    }
  }
}
