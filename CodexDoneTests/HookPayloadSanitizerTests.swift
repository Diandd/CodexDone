import Foundation
import Testing

@testable import CodexDone

struct HookPayloadSanitizerTests {
  @Test("不同 Agent 的同名会话独立，终端标识可持久化")
  func agentNamespacesAndTerminalIdentity() throws {
    let payload = Data(#"{"hook_event_name":"UserPromptSubmit","session_id":"shared","prompt":"Fix tests"}"#.utf8)
    let terminalID = "12345678-1234-1234-1234-123456789ABC"
    let events = try AgentSource.allCases.map { source in
      try HookPayloadSanitizer.event(from: payload, source: source,
        terminalSessionID: "w1t2p0:" + terminalID, receivedAt: Date(timeIntervalSince1970: 100))
    }
    #expect(Set(events.map(\.sessionID)).count == 3)
    #expect(Set(events.map(\.eventID)).count == 3)
    #expect(events.map(\.source) == AgentSource.allCases)
    #expect(events.allSatisfy { $0.terminalSessionID == terminalID })
    let restored = try JSONDecoder().decode(DesktopCompletionHookEvent.self, from: JSONEncoder().encode(events[1]))
    #expect(restored == events[1])
    #expect(HookPayloadSanitizer.normalizedTerminalSessionID("invalid\";activate") == nil)
  }

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

  @Test("屏蔽规则在桥接侧匹配且事件只携带布尔结果")
  func matchesSuppressionRulesWithoutTransmittingThem() throws {
    let rules = AlertSuppressionRules(
      submittedMessageKeywords: ["private marker"],
      submittedMessageRegexPatterns: [#"(?i)build\s+failed"#],
      assistantReplyRegexPatterns: [#"(?i)release\s+note:\s+skip alert"#],
      projectNames: ["Muted  Project"]
    )
    let promptPayload = try JSONSerialization.data(
      withJSONObject: [
        "hook_event_name": "UserPromptSubmit",
        "session_id": "blocked-message",
        "turn_id": "turn-1",
        "cwd": "/tmp/VisibleProject",
        "prompt": "## My request:\nPlease handle this PRIVATE\nMARKER quietly",
      ]
    )
    let projectPayload = try JSONSerialization.data(
      withJSONObject: [
        "hook_event_name": "Stop",
        "session_id": "blocked-project",
        "turn_id": "turn-1",
        "cwd": "/tmp/muted  project",
      ]
    )
    let regexPayload = try JSONSerialization.data(
      withJSONObject: [
        "hook_event_name": "UserPromptSubmit",
        "session_id": "blocked-regex",
        "turn_id": "turn-1",
        "cwd": "/tmp/VisibleProject",
        "prompt": "## My request:\nThe BUILD\nFAILED during packaging",
      ]
    )
    let replyPayload = try JSONSerialization.data(
      withJSONObject: [
        "hook_event_name": "Stop",
        "session_id": "blocked-reply",
        "turn_id": "turn-1",
        "cwd": "/tmp/VisibleProject",
        "last_assistant_message": "Release note:\nSKIP ALERT",
      ]
    )

    let promptEvent = try HookPayloadSanitizer.event(
      from: promptPayload,
      suppressionRules: rules
    )
    let projectEvent = try HookPayloadSanitizer.event(
      from: projectPayload,
      suppressionRules: rules
    )
    let regexEvent = try HookPayloadSanitizer.event(
      from: regexPayload,
      suppressionRules: rules
    )
    let replyEvent = try HookPayloadSanitizer.event(
      from: replyPayload,
      suppressionRules: rules
    )

    #expect(promptEvent.suppressedByRule)
    #expect(projectEvent.suppressedByRule)
    #expect(regexEvent.suppressedByRule)
    #expect(replyEvent.suppressedByRule)
    let encoded = String(decoding: try JSONEncoder().encode(promptEvent), as: UTF8.self)
    #expect(!encoded.contains("submittedMessageKeywords"))
    #expect(!encoded.contains("submittedMessageRegexPatterns"))
    #expect(!encoded.contains("assistantReplyRegexPatterns"))
    #expect(!encoded.contains("projectNames"))
  }

  @Test("正则规则拒绝无效输入并给匹配设置总超时")
  func validatesAndBoundsRegexRules() {
    #expect(AlertSuppressionRules.normalizedRegexRule(#"^release\s+blocked$"#) != nil)
    #expect(AlertSuppressionRules.normalizedRegexRule("(") == nil)
    #expect(
      AlertSuppressionRules.normalizedRegexRule(
        String(repeating: "a", count: AlertSuppressionRules.maximumRuleCharacters + 1)
      ) == nil
    )

    let rules = AlertSuppressionRules(
      assistantReplyRegexPatterns: [#"^(a|aa)+$"#]
    )
    let started = ContinuousClock.now
    #expect(
      !rules.suppresses(
        submittedMessage: nil,
        assistantReply: String(repeating: "a", count: 20_000) + "!",
        workingDirectory: nil
      )
    )
    #expect(started.duration(to: .now) < .seconds(1))
  }

  @Test("屏蔽规则文件限制大小并使用私有权限")
  func persistsPrivateBoundedSuppressionRules() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let fileURL = root.appendingPathComponent("rules.json")
    let rules = AlertSuppressionRules(
      submittedMessageKeywords: ["无需提醒"],
      submittedMessageRegexPatterns: [#"^/quiet\b"#],
      assistantReplyRegexPatterns: [#"(?i)nothing\s+to\s+review"#],
      projectNames: ["CodexDone"]
    )

    try AlertSuppressionRulesFile.save(rules, to: fileURL)

    #expect(AlertSuppressionRulesFile.load(from: fileURL) == rules)
    let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
    let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
    #expect(permissions.intValue & 0o777 == 0o600)
  }

  @Test("缺少规则文件时使用两条可删除默认项且保存删除后不再注入")
  func loadsVisibleProductDefaultsAndRespectsSavedDeletion() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let rulesURL = root.appendingPathComponent("rules.json")

    let defaults = AlertSuppressionRulesFile.load(from: rulesURL)

    #expect(defaults.submittedMessageKeywords.isEmpty)
    #expect(defaults.submittedMessageRegexPatterns.isEmpty)
    #expect(
      defaults.assistantReplyRegexPatterns
        == [AlertSuppressionRules.defaultInternalSuggestionsReplyRegex]
    )
    #expect(defaults.projectNames == [AlertSuppressionRules.defaultRootProjectName])
    #expect(
      defaults.suppresses(
        submittedMessage: nil,
        assistantReply: #"{"suggestions":[{"title":"内部建议"}]}"#,
        workingDirectory: "/tmp/VisibleProject"
      )
    )
    #expect(
      defaults.suppresses(
        submittedMessage: "正常请求",
        assistantReply: nil,
        workingDirectory: "/"
      )
    )
    #expect(
      !defaults.suppresses(
        submittedMessage: "正常请求",
        assistantReply: "正常回复",
        workingDirectory: "/tmp/VisibleProject"
      )
    )

    try AlertSuppressionRulesFile.save(AlertSuppressionRules(), to: rulesURL)
    let deletedDefaults = AlertSuppressionRulesFile.load(from: rulesURL)
    #expect(deletedDefaults == AlertSuppressionRules())
  }

  @Test("旧版屏蔽规则迁移到当前结构并只合并一次默认项")
  func migratesLegacySuppressionRules() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let rulesURL = root.appendingPathComponent("rules.json")

    try JSONSerialization.data(withJSONObject: [
      "version": 1,
      "messageKeywords": ["无需提醒"],
      "projectNames": ["LegacyProject"],
    ]).write(to: rulesURL)
    let migratedV1 = AlertSuppressionRulesFile.load(from: rulesURL)
    #expect(migratedV1.version == AlertSuppressionRules.currentVersion)
    #expect(migratedV1.submittedMessageKeywords == ["无需提醒"])
    #expect(migratedV1.submittedMessageRegexPatterns.isEmpty)
    #expect(
      migratedV1.assistantReplyRegexPatterns
        == [AlertSuppressionRules.defaultInternalSuggestionsReplyRegex]
    )
    #expect(
      migratedV1.projectNames
        == ["LegacyProject", AlertSuppressionRules.defaultRootProjectName]
    )

    try JSONSerialization.data(withJSONObject: [
      "version": 2,
      "messageKeywords": ["skip me"],
      "messageRegexPatterns": [#"(?i)^/quiet\b"#],
      "projectNames": ["RegexProject"],
    ]).write(to: rulesURL)
    let migratedV2 = AlertSuppressionRulesFile.load(from: rulesURL)
    #expect(migratedV2.version == AlertSuppressionRules.currentVersion)
    #expect(migratedV2.submittedMessageKeywords == ["skip me"])
    #expect(migratedV2.submittedMessageRegexPatterns == [#"(?i)^/quiet\b"#])
    #expect(
      migratedV2.assistantReplyRegexPatterns
        == [AlertSuppressionRules.defaultInternalSuggestionsReplyRegex]
    )
    #expect(
      migratedV2.projectNames
        == ["RegexProject", AlertSuppressionRules.defaultRootProjectName]
    )

    try JSONSerialization.data(withJSONObject: [
      "version": 3,
      "submittedMessageKeywords": ["legacy v3"],
      "submittedMessageRegexPatterns": [#"^legacy-v3$"#],
      "assistantReplyRegexPatterns": [#"^user reply$"#],
      "projectNames": ["V3Project"],
    ]).write(to: rulesURL)
    let migratedV3 = AlertSuppressionRulesFile.load(from: rulesURL)
    #expect(migratedV3.version == AlertSuppressionRules.currentVersion)
    #expect(migratedV3.submittedMessageKeywords == ["legacy v3"])
    #expect(migratedV3.submittedMessageRegexPatterns == [#"^legacy-v3$"#])
    #expect(
      migratedV3.assistantReplyRegexPatterns
        == [#"^user reply$"#, AlertSuppressionRules.defaultInternalSuggestionsReplyRegex]
    )
    #expect(
      migratedV3.projectNames
        == ["V3Project", AlertSuppressionRules.defaultRootProjectName]
    )

    try AlertSuppressionRulesFile.save(migratedV3, to: rulesURL)
    let rewrittenEnvelope = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: rulesURL)) as? [String: Any]
    )
    #expect(rewrittenEnvelope["version"] as? Int == AlertSuppressionRules.currentVersion)
  }

  @Test("拒绝未支持 Hook 与超大输入")
  func rejectsUnsupportedInput() {
    for eventName in ["PermissionRequest", "SubagentStop"] {
      let unsupported = Data(
        "{\"hook_event_name\":\"\(eventName)\",\"session_id\":\"s\",\"turn_id\":\"t\"}".utf8
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
