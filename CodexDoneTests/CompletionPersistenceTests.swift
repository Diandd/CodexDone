import AVFoundation
import Foundation
import Testing
import UserNotifications

@testable import CodexDone

struct CompletionPersistenceTests {
  @Test("自定义音频只有在声音开启且文件已导入时才能启用")
  func customAudioAvailabilityRequiresSoundAndImportedFile() {
    #expect(
      AlertSettingsRules.canSelectCustomSound(
        soundEnabled: true,
        hasImportedSound: true,
      )
    )
    #expect(
      !AlertSettingsRules.canSelectCustomSound(
        soundEnabled: false,
        hasImportedSound: true,
      )
    )
    #expect(
      !AlertSettingsRules.canSelectCustomSound(
        soundEnabled: true,
        hasImportedSound: false,
      )
    )
  }

  @Test("智能提醒默认在使用中显示刘海提示，离开一分钟后显示全屏")
  @MainActor
  func smartAlertDefaultsAndBoundary() {
    let configuration = SmartAlertConfiguration.defaultConfiguration

    #expect(AlertVisualMode.defaultMode == .smart)
    #expect(configuration.activeDestination == .notch)
    #expect(configuration.awayDestination == .fullscreen)
    #expect(configuration.inactivityDuration == .oneMinute)
    #expect(configuration.activityState(idleSeconds: 59.9) == .active)
    #expect(configuration.activityState(idleSeconds: 60) == .away)
    #expect(
      CompletionAlertCoordinator.resolvedVisualDestination(
        configuredMode: .smart,
        smartConfiguration: configuration,
        idleSeconds: 59.9
      ) == .notch
    )
    #expect(
      CompletionAlertCoordinator.resolvedVisualDestination(
        configuredMode: .smart,
        smartConfiguration: configuration,
        idleSeconds: 60
      ) == .fullscreen
    )
  }

  @Test("智能提醒允许分别关闭使用中或离开后的视觉提示")
  @MainActor
  func smartAlertDestinationsAreIndependent() {
    let configuration = SmartAlertConfiguration(
      activeDestination: .none,
      awayDestination: .hud,
      inactivityDuration: .fiveMinutes
    )

    #expect(
      CompletionAlertCoordinator.resolvedVisualDestination(
        configuredMode: .smart,
        smartConfiguration: configuration,
        idleSeconds: 0
      ) == .none
    )
    #expect(
      CompletionAlertCoordinator.resolvedVisualDestination(
        configuredMode: .smart,
        smartConfiguration: configuration,
        idleSeconds: 300
      ) == .hud
    )
    #expect(
      CompletionAlertCoordinator.resolvedVisualDestination(
        configuredMode: .fullscreen,
        smartConfiguration: configuration,
        idleSeconds: 0
      ) == .fullscreen
    )
    #expect(
      CompletionAlertCoordinator.resolvedVisualDestination(
        configuredMode: .notch,
        smartConfiguration: configuration,
        idleSeconds: 0
      ) == .notch
    )
  }

  @Test("持久化按上限保留 session、记录、诊断与去重键")
  func retentionLimits() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let url = root.appendingPathComponent("state.json")
    let persistence = CompletionPersistence(fileURL: url)
    let records = (0..<75).map { index in
      ConversationCompletionRecord(
        id: "record-\(index)",
        sessionID: "session-\(index)",
        turnID: nil,
        projectDisplayName: "Project",
        completedAt: Date(timeIntervalSince1970: TimeInterval(index)),
        isAcknowledged: index.isMultiple(of: 2),
        notificationDelivered: true
      )
    }
    let ids = (0..<550).map { _ in UUID() }
    let sessions = (0..<75).map { index in
      CompletionSessionState(
        sessionID: "session-\(index)",
        phase: index < 5 ? .running : .idle,
        turnID: "turn-\(index)",
        projectDisplayName: "Project",
        lastEventAt: Date(timeIntervalSince1970: TimeInterval(index)),
        pendingEventID: nil
      )
    }
    let diagnostics = (0..<75).map { index in
      HookEventDiagnosticRecord(
        id: UUID(),
        eventName: index.isMultiple(of: 2) ? .userPromptSubmit : .stop,
        receivedAt: Date(timeIntervalSince1970: TimeInterval(index)),
        ingress: index.isMultiple(of: 2) ? .socket : .spool,
        payloadKind: .text,
        outcome: .readyToReview
      )
    }
    let state = CompletionPersistedState(
      sessions: sessions,
      records: records,
      processedEventIDs: ids,
      hookEventDiagnostics: diagnostics
    )

    try await persistence.save(state)
    let loaded = try await persistence.load()

    #expect(loaded.sessions.count == 50)
    #expect(Set(loaded.sessions.prefix(5).map(\.sessionID)) == Set((0..<5).map { "session-\($0)" }))
    #expect(loaded.records.count == 50)
    #expect(loaded.records.first?.id == "record-74")
    #expect(loaded.processedEventIDs.count == 500)
    #expect(loaded.processedEventIDs.first == ids[50])
    #expect(loaded.hookEventDiagnostics.count == 20)
    #expect(loaded.hookEventDiagnostics.first?.receivedAt == Date(timeIntervalSince1970: 74))
    #expect(loaded.hookEventDiagnostics.last?.receivedAt == Date(timeIntervalSince1970: 55))
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    let parentAttributes = try FileManager.default.attributesOfItem(atPath: root.path)
    #expect((parentAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
  }

  @Test("持久化会清除已查看记录和 idle session 的短内容")
  func persistenceRedactsInactiveContent() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let persistence = CompletionPersistence(fileURL: root.appendingPathComponent("state.json"))
    let state = CompletionPersistedState(
      sessions: [
        CompletionSessionState(
          sessionID: "session-redacted",
          phase: .idle,
          turnID: "turn-redacted",
          projectDisplayName: "Project",
          lastEventAt: .now,
          pendingEventID: nil,
          conversationTitle: "不应继续保存的主题",
          replyPreview: "不应继续保存的回复"
        ),
        CompletionSessionState(
          sessionID: "session-running",
          phase: .running,
          turnID: "turn-running",
          projectDisplayName: "Project",
          lastEventAt: .now,
          pendingEventID: nil,
          conversationTitle: "运行时只保留在内存的主题",
          replyPreview: nil
        ),
      ],
      records: [
        ConversationCompletionRecord(
          id: "record-redacted",
          sessionID: "session-redacted",
          turnID: "turn-redacted",
          projectDisplayName: "Project",
          completedAt: .now,
          isAcknowledged: true,
          notificationDelivered: true,
          conversationTitle: "不应继续保存的主题",
          replyPreview: "不应继续保存的回复"
        )
      ]
    )

    try await persistence.save(state)
    let loaded = try await persistence.load()

    #expect(loaded.sessions.allSatisfy { $0.conversationTitle == nil })
    #expect(loaded.sessions.allSatisfy { $0.replyPreview == nil })
    #expect(loaded.records.first?.conversationTitle == nil)
    #expect(loaded.records.first?.replyPreview == nil)
    let fileText = try String(
      contentsOf: root.appendingPathComponent("state.json"),
      encoding: .utf8
    )
    #expect(!fileText.contains("不应继续保存"))
    #expect(!fileText.contains("运行时只保留"))
  }

  @Test("从已发布 0.2 的 v5 状态迁移并保留待查看记录")
  func migratesReleasedV020State() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let stateURL = root.appendingPathComponent("state.json")
    let processedEventID = UUID()
    let diagnosticID = UUID()
    let releasedState: [String: Any] = [
      "version": 5,
      "sessions": [[
        "sessionID": "released-session",
        "phase": "readyToReview",
        "turnID": "released-turn",
        "projectDisplayName": "ReleasedProject",
        "lastEventAt": 1_000_000,
        "pendingEventID": NSNull(),
        "conversationTitle": "已发布版本主题",
        "replyPreview": "已发布版本回复",
      ]],
      "records": [[
        "id": "released-record",
        "sessionID": "released-session",
        "turnID": "released-turn",
        "projectDisplayName": "ReleasedProject",
        "completedAt": 1_000_000,
        "isAcknowledged": false,
        "notificationDelivered": true,
        "conversationTitle": "已发布版本主题",
        "replyPreview": "已发布版本回复",
      ]],
      "processedEventIDs": [processedEventID.uuidString],
      "hookEventDiagnostics": [[
        "id": diagnosticID.uuidString,
        "eventName": "Stop",
        "receivedAt": 1_000_000,
        "ingress": "spool",
        "payloadKind": "text",
        "outcome": "readyToReview",
      ]],
      "lastUserPromptAt": 900_000,
      "lastStopAt": 1_000_000,
    ]
    try JSONSerialization.data(withJSONObject: releasedState).write(to: stateURL)
    let persistence = CompletionPersistence(fileURL: stateURL)

    let loaded = try await persistence.load()

    #expect(loaded.version == CompletionPersistedState.currentVersion)
    #expect(loaded.sessions.count == 1)
    #expect(loaded.sessions.first?.phase == .readyToReview)
    #expect(loaded.sessions.first?.suppressesCurrentTurn == false)
    #expect(loaded.sessions.first?.conversationTitle == "已发布版本主题")
    #expect(loaded.records.first?.id == "released-record")
    #expect(loaded.records.first?.replyPreview == "已发布版本回复")
    #expect(loaded.processedEventIDs == [processedEventID])
    #expect(loaded.hookEventDiagnostics.first?.id == diagnosticID)

    try await persistence.save(loaded)
    let rewrittenEnvelope = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any]
    )
    #expect(rewrittenEnvelope["version"] as? Int == CompletionPersistedState.currentVersion)
  }

  @Test("不识别的状态版本仍按安全空状态处理")
  func discardsUnsupportedStateVersion() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let stateURL = root.appendingPathComponent("state.json")
    let unsupportedJSON = Data(
      #"{"lastStopAt":1000,"lastUserPromptAt":900,"processedEventIDs":[],"records":[{"completedAt":1000,"id":"unsupported-record","isAcknowledged":false,"notificationDelivered":true,"projectDisplayName":"UnsupportedProject","sessionID":"unsupported-session","turnID":"unsupported-turn"}],"sessions":[{"lastEventAt":1000,"pendingEventID":null,"phase":"readyToReview","projectDisplayName":"UnsupportedProject","sessionID":"unsupported-session","turnID":"unsupported-turn"}],"version":2}"#
        .utf8
    )
    try unsupportedJSON.write(to: stateURL)
    let persistence = CompletionPersistence(fileURL: stateURL)

    let loaded = try await persistence.load()

    #expect(loaded == CompletionPersistedState())
  }

  @Test("MP3 可作为一种支持的音频导入并走真实播放器试听")
  @MainActor
  func customMP3ImportAndPlayback() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let suiteName = "CompletionSoundTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set(true, forKey: "alerts.completion.soundEnabled")
    let destination = root.appendingPathComponent("completion.audio")
    let service = CompletionSoundService(
      defaults: defaults,
      customSoundURL: destination
    )
    let source = try #require(
      Bundle(for: CompletionSoundFixtureToken.self).url(
        forResource: "test-tone",
        withExtension: "mp3"
      )
    )

    try service.importAudio(from: source)
    defaults.set(true, forKey: "alerts.completion.useCustomSound")

    #expect(FileManager.default.fileExists(atPath: destination.path))
    let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    #expect(service.usesCustomSound(for: .completion))
    #expect(service.preview(situation: .completion))
    #expect(service.lastPlaybackUsedCustomSound)
    #expect(service.playbackStatusTitle == L10n.text("自定义音频已播放"))
    service.stopAll()
  }

  @Test("WAV 也可导入并单独试听")
  @MainActor
  func customWAVImportAndPlayback() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let source = root.appendingPathComponent("source.wav")
    let format = try #require(
      AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)
    )
    do {
      let audioFile = try AVAudioFile(forWriting: source, settings: format.settings)
      let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_410))
      buffer.frameLength = 4_410
      try audioFile.write(from: buffer)
    }
    let suiteName = "CompletionSoundWAVTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let service = CompletionSoundService(
      defaults: defaults,
      customSoundURL: root.appendingPathComponent("completion.audio")
    )

    try service.importAudio(from: source)

    #expect(service.customSoundDisplayName == "source.wav")
    #expect(service.previewCustom())
    #expect(service.lastPlaybackUsedCustomSound)
    service.stopAll()
  }

  @Test("损坏或扩展名不支持的音频会被拒绝")
  @MainActor
  func rejectsInvalidOrUnsupportedAudio() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let invalid = root.appendingPathComponent("invalid.wav")
    let unsupported = root.appendingPathComponent("unsupported.ogg")
    try Data("not audio".utf8).write(to: invalid)
    try Data("not audio".utf8).write(to: unsupported)
    let service = CompletionSoundService(
      defaults: UserDefaults(suiteName: "CompletionSoundFormatTests.\(UUID().uuidString)")!,
      customSoundURL: root.appendingPathComponent("completion.audio")
    )

    #expect(throws: CompletionSoundError.invalidAudio) {
      try service.importAudio(from: invalid)
    }
    #expect(throws: CompletionSoundError.unsupportedFormat) {
      try service.importAudio(from: unsupported)
    }
  }

  @Test("超过 10 MB 的音频会在解码前被拒绝")
  @MainActor
  func rejectsOversizedAudio() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let source = root.appendingPathComponent("oversized.wav")
    #expect(FileManager.default.createFile(atPath: source.path, contents: nil))
    let handle = try FileHandle(forWritingTo: source)
    handle.truncateFile(atOffset: UInt64(10 * 1_024 * 1_024 + 1))
    try handle.close()
    let service = CompletionSoundService(
      defaults: UserDefaults(suiteName: "CompletionSoundSizeTests.\(UUID().uuidString)")!,
      customSoundURL: root.appendingPathComponent("completion.audio")
    )

    #expect(throws: CompletionSoundError.fileTooLarge) {
      try service.importAudio(from: source)
    }
  }

  @Test("应用声音成功时通知静音，失败或关闭时通知兜底发声")
  @MainActor
  func notificationSoundHasSingleSource() {
    #expect(!CompletionAlertCoordinator.notificationShouldPlaySound(appSoundPlayed: true))
    #expect(CompletionAlertCoordinator.notificationShouldPlaySound(appSoundPlayed: false))
  }

  @Test("完成提醒读取自己的声音配置")
  @MainActor
  func completionAlertUsesSoundSettings() {
    let suiteName = "AlertSituationSoundTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set("Purr", forKey: "alerts.completion.builtInSound")
    let service = CompletionSoundService(
      defaults: defaults,
      customSoundURL: FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathComponent("completion.audio")
    )

    #expect(service.soundEnabled(for: .completion))
    defaults.set(false, forKey: "alerts.completion.soundEnabled")
    #expect(!service.soundEnabled(for: .completion))
    #expect(service.selectedBuiltInSound(for: .completion) == "Purr")
  }

  @Test("系统通知默认使用中性文案并允许有界自定义标题")
  func notificationContentUsesConfiguredHeadline() {
    let content = SystemNotificationService.notificationContent(
      alertID: "record-private",
      situation: .completion,
      playSound: false
    )

    #expect(content.title == L10n.text("Codex 本轮已停止"))
    #expect(content.body == L10n.text("可以返回 Codex 查看本轮结果"))
    #expect(!content.body.contains("SecretProject"))
    #expect(content.sound == nil)
    #expect(content.userInfo["alertID"] as? String == "record-private")

    let customized = SystemNotificationService.notificationContent(
      alertID: "record-custom",
      situation: .completion,
      title: "  提醒我回来\n查看  ",
      playSound: false
    )
    #expect(customized.title == "提醒我回来 查看")
    #expect(customized.body == L10n.text("可以返回 Codex 查看本轮结果"))
  }

  @Test("前台通知保留声音选项以便在应用声音失败时兜底")
  func foregroundNotificationIncludesSound() {
    let options = SystemNotificationService.foregroundPresentationOptions

    #expect(options.contains(.banner))
    #expect(options.contains(.list))
    #expect(options.contains(.sound))
  }

  @Test("新 Prompt 或已查看后，晚返回的通知会被再次移除")
  @MainActor
  func delayedNotificationIsRemovedAfterDismissal() async {
    let suiteName = "CompletionAlertCancellationTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set(false, forKey: "alerts.completion.soundEnabled")
    defaults.set(AlertVisualMode.none.rawValue, forKey: "alerts.visualMode")
    defaults.set(true, forKey: "alerts.systemNotificationEnabled")
    let driver = DelayedNotificationDriver()
    let soundService = CompletionSoundService(
      defaults: defaults,
      customSoundURL: FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathComponent("completion.audio")
    )
    let coordinator = CompletionAlertCoordinator(
      soundService: soundService,
      notificationDriver: driver,
      defaults: defaults
    )
    let record = ConversationCompletionRecord(
      id: "record-late",
      sessionID: "session-late",
      turnID: "turn-private",
      projectDisplayName: "SecretProject",
      completedAt: .now,
      isAcknowledged: false,
      notificationDelivered: false
    )

    let delivery = Task { @MainActor in
      await coordinator.deliver(AlertPresentation(completion: record))
    }
    await driver.waitUntilDeliveryStarts()
    coordinator.dismiss(sessionID: record.sessionID, alertIDs: [record.id])
    driver.finishDelivery()
    await delivery.value

    #expect(driver.activeRecordIDs.isEmpty)
    #expect(driver.removedRecordIDs.contains(record.id))
  }

  @Test("同 session 旧投递晚返回时不会清除新通知")
  @MainActor
  func staleGenerationCannotRemoveNewNotification() async {
    let suiteName = "CompletionAlertGenerationTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set(false, forKey: "alerts.completion.soundEnabled")
    defaults.set(AlertVisualMode.none.rawValue, forKey: "alerts.visualMode")
    defaults.set(true, forKey: "alerts.systemNotificationEnabled")
    let driver = OverlappingNotificationDriver(delayedRecordID: "record-old")
    let coordinator = CompletionAlertCoordinator(
      soundService: CompletionSoundService(
        defaults: defaults,
        customSoundURL: FileManager.default.temporaryDirectory
          .appendingPathComponent(UUID().uuidString)
          .appendingPathComponent("completion.audio")
      ),
      notificationDriver: driver,
      defaults: defaults
    )
    let oldRecord = ConversationCompletionRecord(
      id: "record-old",
      sessionID: "session-overlap",
      turnID: "turn-old",
      projectDisplayName: "PrivateOld",
      completedAt: .now,
      isAcknowledged: false,
      notificationDelivered: false
    )
    let newRecord = ConversationCompletionRecord(
      id: "record-new",
      sessionID: oldRecord.sessionID,
      turnID: "turn-new",
      projectDisplayName: "PrivateNew",
      completedAt: .now,
      isAcknowledged: false,
      notificationDelivered: false
    )

    let oldDelivery = Task { @MainActor in
      await coordinator.deliver(AlertPresentation(completion: oldRecord))
    }
    await driver.waitUntilDelayedDeliveryStarts()
    await coordinator.deliver(AlertPresentation(completion: newRecord))
    driver.finishDelayedDelivery()
    await oldDelivery.value

    #expect(driver.activeRecordIDs == [newRecord.id])
    #expect(driver.removedRecordIDs.contains(oldRecord.id))
    #expect(!driver.removedRecordIDs.contains(newRecord.id))
  }

  @Test("已取消的排队投递不会在稍后启动")
  @MainActor
  func dismissalBeforeDeliveryPreventsQueuedAlert() async {
    let suiteName = "CompletionAlertQueuedCancellationTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set(false, forKey: "alerts.completion.soundEnabled")
    defaults.set(AlertVisualMode.none.rawValue, forKey: "alerts.visualMode")
    defaults.set(true, forKey: "alerts.systemNotificationEnabled")
    defaults.set(
      "自定义通知标题",
      forKey: AlertHeadlineChannel.notification.storageKey
    )
    let driver = RecordingNotificationDriver()
    let coordinator = CompletionAlertCoordinator(
      soundService: CompletionSoundService(
        defaults: defaults,
        customSoundURL: FileManager.default.temporaryDirectory
          .appendingPathComponent(UUID().uuidString)
          .appendingPathComponent("completion.audio")
      ),
      notificationDriver: driver,
      defaults: defaults
    )
    let record = ConversationCompletionRecord(
      id: "record-queued",
      sessionID: "session-queued",
      turnID: nil,
      projectDisplayName: "SecretProject",
      completedAt: Date(timeIntervalSinceNow: -1),
      isAcknowledged: false,
      notificationDelivered: false
    )

    let cancelledDelivery = Task { @MainActor in
      withUnsafeCurrentTask { $0?.cancel() }
      await coordinator.deliver(AlertPresentation(completion: record))
    }
    await cancelledDelivery.value

    #expect(driver.deliveredRecordIDs.isEmpty)
    #expect(driver.removedRecordIDs == [record.id])

    let nextRecord = ConversationCompletionRecord(
      id: "record-next",
      sessionID: record.sessionID,
      turnID: "turn-next",
      projectDisplayName: "AnotherSecretProject",
      completedAt: .now,
      isAcknowledged: false,
      notificationDelivered: false
    )
    await coordinator.deliver(AlertPresentation(completion: nextRecord))

    #expect(driver.deliveredRecordIDs == [nextRecord.id])
    #expect(driver.deliveredTitles[nextRecord.id] == "自定义通知标题")
  }
}

private final class CompletionSoundFixtureToken: NSObject {}

@MainActor
private final class DelayedNotificationDriver: CompletionNotificationDriving {
  private(set) var activeRecordIDs: Set<String> = []
  private(set) var removedRecordIDs: Set<String> = []
  private var deliveryStarted = false
  private var startWaiters: [CheckedContinuation<Void, Never>] = []
  private var deliveryContinuation: CheckedContinuation<Void, Never>?

  func deliver(
    alertID: String,
    situation: AlertSituation,
    title: String,
    playSound: Bool
  ) async {
    _ = situation
    _ = title
    _ = playSound
    deliveryStarted = true
    let waiters = startWaiters
    startWaiters.removeAll()
    for waiter in waiters { waiter.resume() }
    await withCheckedContinuation { continuation in
      deliveryContinuation = continuation
    }
    activeRecordIDs.insert(alertID)
  }

  func remove(alertIDs: Set<String>) {
    removedRecordIDs.formUnion(alertIDs)
    activeRecordIDs.subtract(alertIDs)
  }

  func waitUntilDeliveryStarts() async {
    guard !deliveryStarted else { return }
    await withCheckedContinuation { continuation in
      startWaiters.append(continuation)
    }
  }

  func finishDelivery() {
    deliveryContinuation?.resume()
    deliveryContinuation = nil
  }
}

@MainActor
private final class RecordingNotificationDriver: CompletionNotificationDriving {
  private(set) var deliveredRecordIDs: Set<String> = []
  private(set) var removedRecordIDs: Set<String> = []
  private(set) var deliveredTitles: [String: String] = [:]

  func deliver(
    alertID: String,
    situation: AlertSituation,
    title: String,
    playSound: Bool
  ) async {
    _ = situation
    _ = playSound
    deliveredRecordIDs.insert(alertID)
    deliveredTitles[alertID] = title
  }

  func remove(alertIDs: Set<String>) {
    removedRecordIDs.formUnion(alertIDs)
  }
}

@MainActor
private final class OverlappingNotificationDriver: CompletionNotificationDriving {
  private let delayedRecordID: String
  private(set) var activeRecordIDs: Set<String> = []
  private(set) var removedRecordIDs: Set<String> = []
  private var delayedDeliveryStarted = false
  private var startWaiters: [CheckedContinuation<Void, Never>] = []
  private var delayedContinuation: CheckedContinuation<Void, Never>?

  init(delayedRecordID: String) {
    self.delayedRecordID = delayedRecordID
  }

  func deliver(
    alertID: String,
    situation: AlertSituation,
    title: String,
    playSound: Bool
  ) async {
    _ = situation
    _ = title
    _ = playSound
    if alertID == delayedRecordID {
      delayedDeliveryStarted = true
      let waiters = startWaiters
      startWaiters.removeAll()
      for waiter in waiters { waiter.resume() }
      await withCheckedContinuation { continuation in
        delayedContinuation = continuation
      }
    }
    activeRecordIDs.insert(alertID)
  }

  func remove(alertIDs: Set<String>) {
    removedRecordIDs.formUnion(alertIDs)
    activeRecordIDs.subtract(alertIDs)
  }

  func waitUntilDelayedDeliveryStarts() async {
    guard !delayedDeliveryStarted else { return }
    await withCheckedContinuation { continuation in
      startWaiters.append(continuation)
    }
  }

  func finishDelayedDelivery() {
    delayedContinuation?.resume()
    delayedContinuation = nil
  }
}
