import Foundation
import Testing

@testable import CodexDone

struct CodexHookStatusServiceTests {
  private let configurationPath = "/Users/tester/.codex/hooks.json"
  private let command = "'/Applications/CodexDone.app/Contents/Helpers/CodexDoneHookBridge'"

  @Test("hooks/list 只接收当前配置与当前 Bridge 的两条 Hook")
  func filtersToCurrentCodexDoneHooks() throws {
    let output = try appServerOutput(hooks: [
      hook(event: "permissionRequest", enabled: true, trust: "managed"),
      hook(event: "userPromptSubmit", enabled: true, trust: "trusted"),
      hook(event: "stop", enabled: true, trust: "trusted"),
      hook(event: "stop", enabled: true, trust: "trusted", command: "'/tmp/other'"),
      hook(
        event: "stop",
        enabled: true,
        trust: "trusted",
        sourcePath: "/Users/tester/project/hooks.json"
      ),
      hook(event: "subagentStop", enabled: true, trust: "trusted"),
    ])

    let inspection = CodexHookStatusService.parseOutput(
      output,
      configurationPath: configurationPath,
      handlerCommand: command
    )

    #expect(inspection.availability == .available)
    #expect(inspection.statuses.count == 2)
    #expect(
      inspection.status(for: .userPromptSubmit)
        == CodexHookRuntimeStatus(isEnabled: true, trustStatus: .trusted)
    )
    #expect(
      inspection.status(for: .stop)
        == CodexHookRuntimeStatus(isEnabled: true, trustStatus: .trusted)
    )
  }

  @Test("信任变更与关闭状态保持逐项独立")
  func preservesActionableStates() throws {
    let output = try appServerOutput(hooks: [
      hook(event: "userPromptSubmit", enabled: true, trust: "modified"),
      hook(event: "stop", enabled: false, trust: "trusted"),
    ])

    let inspection = CodexHookStatusService.parseOutput(
      output,
      configurationPath: configurationPath,
      handlerCommand: command
    )

    #expect(
      inspection.status(for: .userPromptSubmit)
        == CodexHookRuntimeStatus(isEnabled: true, trustStatus: .modified)
    )
    #expect(
      inspection.status(for: .stop)
        == CodexHookRuntimeStatus(isEnabled: false, trustStatus: .trusted)
    )
  }

  @Test("无效或错误响应只返回无内容的不可用状态")
  func rejectsInvalidResponsesWithoutRetainingDetails() throws {
    let sensitiveCommand = "secret-command --token hidden"
    let malformed = Data("{not-json}\n".utf8)
    let error = try JSONSerialization.data(withJSONObject: [
      "id": 2,
      "error": ["code": -32603, "message": sensitiveCommand],
    ]) + Data("\n".utf8)

    for output in [malformed, error] {
      let inspection = CodexHookStatusService.parseOutput(
        output,
        configurationPath: configurationPath,
        handlerCommand: command
      )
      #expect(inspection == .unavailable)
      #expect(!String(reflecting: inspection).contains(sensitiveCommand))
    }
  }

  @Test("客户端等待初始化响应后再查询并主动结束短时进程")
  func performsOrderedHandshakeWithoutClosingInputEarly() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let executable = root.appendingPathComponent("fake-codex")
    let testConfigurationPath = "/tmp/codexdone-hooks.json"
    let testCommand = "/tmp/CodexDoneHookBridge"
    let listResponse = try appServerOutput(
      hooks: [
        hook(
          event: "userPromptSubmit",
          enabled: true,
          trust: "trusted",
          command: testCommand,
          sourcePath: testConfigurationPath
        ),
        hook(
          event: "stop",
          enabled: true,
          trust: "trusted",
          command: testCommand,
          sourcePath: testConfigurationPath
        ),
      ],
      includesInitializeResponse: false
    )
    let listLine = try #require(String(data: listResponse, encoding: .utf8))
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let script = """
    #!/bin/sh
    IFS= read -r initialize_request
    printf '%s\\n' '{"id":1,"result":{}}'
    IFS= read -r initialized_notification
    IFS= read -r hooks_request
    printf '%s\\n' '\(listLine)'
    """
    try Data(script.utf8).write(to: executable)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755],
      ofItemAtPath: executable.path
    )

    let inspection = await CodexHookStatusService().inspect(
      executableURL: executable,
      workingDirectory: root,
      configurationPath: testConfigurationPath,
      handlerCommand: testCommand,
      timeout: 2
    )

    #expect(inspection.allRequiredHooksAreReady)
  }

  private func appServerOutput(
    hooks: [[String: Any]],
    includesInitializeResponse: Bool = true
  ) throws -> Data {
    let list = try JSONSerialization.data(withJSONObject: [
      "id": 2,
      "result": [
        "data": [[
          "cwd": "/Users/tester",
          "hooks": hooks,
          "warnings": [],
          "errors": [],
        ]]
      ],
    ])
    guard includesInitializeResponse else { return list + Data("\n".utf8) }
    let initialize = try JSONSerialization.data(withJSONObject: [
      "id": 1,
      "result": ["userAgent": "test"],
    ])
    return initialize + Data("\n".utf8) + list + Data("\n".utf8)
  }

  private func hook(
    event: String,
    enabled: Bool,
    trust: String,
    command overrideCommand: String? = nil,
    sourcePath overrideSourcePath: String? = nil
  ) -> [String: Any] {
    [
      "handlerType": "command",
      "command": overrideCommand ?? command,
      "currentHash": "private-hash",
      "displayOrder": 0,
      "enabled": enabled,
      "eventName": event,
      "isManaged": trust == "managed",
      "key": "private-key",
      "source": "user",
      "sourcePath": overrideSourcePath ?? configurationPath,
      "timeoutSec": 5,
      "trustStatus": trust,
    ]
  }
}
