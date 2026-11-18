import Foundation
import Observation

@MainActor
@Observable
final class DesktopCompletionStore {
  private(set) var sessions: [String: CompletionSessionState] = [:]
  private(set) var records: [ConversationCompletionRecord] = []
  private(set) var hookEventDiagnostics: [HookEventDiagnosticRecord] = []
  private(set) var lastUserPromptAt: Date?
  private(set) var lastStopAt: Date?
  private(set) var persistenceErrorMessage: String?
  private(set) var hasLoadedPersistence = false

  @ObservationIgnored private let persistence: CompletionPersistence
  @ObservationIgnored private var processedEventIDs: Set<UUID> = []
  @ObservationIgnored private var processedEventIDOrder: [UUID] = []
  @ObservationIgnored private var lastAcceptedEventOrder: [String: EventOrderKey] = [:]
  @ObservationIgnored private var debounceTasks: [String: Task<Void, Never>] = [:]
  @ObservationIgnored private var saveTask: Task<Bool, Never>?

  @ObservationIgnored var onReadyToReview: ((ConversationCompletionRecord) -> Void)?
  @ObservationIgnored var onDismissAlert: ((String) -> Void)?
  @ObservationIgnored var onUnreadCountChanged: ((Int) -> Void)?

  init(persistence: CompletionPersistence = CompletionPersistence()) {
    self.persistence = persistence
  }

  var unreadRecords: [ConversationCompletionRecord] {
    records.filter { !$0.isAcknowledged }
  }

  var unreadCount: Int { unreadRecords.count }

  func hasProcessedEventID(_ eventID: UUID) -> Bool {
    processedEventIDs.contains(eventID)
  }

  func recordIDs(for sessionID: String) -> [String] {
    Array(records.lazy.filter { $0.sessionID == sessionID }.map(\.id))
  }

  var menuBarTitle: String {
    unreadCount > 0
      ? L10n.format("%lld 条对话可查看", Int64(unreadCount))
      : "CodexDone"
  }

  func load() async {
    let previousUnreadCount = unreadCount
    defer { notifyUnreadCountChanged(from: previousUnreadCount) }
    do {
      let state = try await persistence.load()
      sessions = Dictionary(uniqueKeysWithValues: state.sessions.map { ($0.sessionID, $0) })
      records = state.records.sorted { $0.completedAt > $1.completedAt }
      hookEventDiagnostics = state.hookEventDiagnostics
      processedEventIDOrder = state.processedEventIDs
      processedEventIDs = Set(state.processedEventIDs)
      lastAcceptedEventOrder = Dictionary(
        uniqueKeysWithValues: sessions.values.map { session in
          (session.sessionID, restoredEventOrder(for: session))
        }
      )
      lastUserPromptAt = state.lastUserPromptAt
      lastStopAt = state.lastStopAt
      persistenceErrorMessage = nil
      hasLoadedPersistence = true

      for session in sessions.values where session.phase == .pendingCompletionDebounce {
        guard let eventID = session.pendingEventID else { continue }
        scheduleFinalization(
          sessionID: session.sessionID,
          eventID: eventID,
          delay: .zero,
          suppressAlert: true
        )
      }
    } catch {
      sessions = [:]
      records = []
      hookEventDiagnostics = []
      processedEventIDs = []
      processedEventIDOrder = []
      lastAcceptedEventOrder = [:]
      persistenceErrorMessage = L10n.text("本地完成记录无法读取")
      hasLoadedPersistence = true
    }
  }

  func handle(
    _ event: DesktopCompletionHookEvent,
    deliveryMode: HookEventDeliveryMode = .live,
    ingress: HookEventIngress = .socket
  ) {
    _ = process(event, deliveryMode: deliveryMode, ingress: ingress)
  }

  @discardableResult
  func handlePersisting(
    _ event: DesktopCompletionHookEvent,
    deliveryMode: HookEventDeliveryMode,
    ingress: HookEventIngress = .socket
  ) async -> Bool {
    await process(event, deliveryMode: deliveryMode, ingress: ingress).value
  }

  @discardableResult
  func flushPersistence() async -> Bool {
    await saveTask?.value ?? true
  }

  func acknowledge(recordID: String) {
    guard
      let index = records.firstIndex(where: { $0.id == recordID }),
      !records[index].isAcknowledged
    else {
      return
    }
    let previousUnreadCount = unreadCount
    let sessionID = records[index].sessionID
    records[index].isAcknowledged = true
    records[index].conversationTitle = nil
    records[index].replyPreview = nil
    let hasRemainingUnread = records.contains {
      $0.sessionID == sessionID && !$0.isAcknowledged
    }
    if !hasRemainingUnread, sessions[sessionID]?.phase == .readyToReview {
      sessions[sessionID]?.phase = .idle
    }
    if !hasRemainingUnread {
      sessions[sessionID]?.conversationTitle = nil
      sessions[sessionID]?.replyPreview = nil
      onDismissAlert?(sessionID)
    }
    persist()
    notifyUnreadCountChanged(from: previousUnreadCount)
  }

  func acknowledgeAll() {
    let previousUnreadCount = unreadCount
    let sessionIDs = Set(records.lazy.filter { !$0.isAcknowledged }.map(\.sessionID))
    for index in records.indices {
      records[index].isAcknowledged = true
      records[index].conversationTitle = nil
      records[index].replyPreview = nil
    }
    for sessionID in sessionIDs {
      if sessions[sessionID]?.phase == .readyToReview {
        sessions[sessionID]?.phase = .idle
      }
      sessions[sessionID]?.conversationTitle = nil
      sessions[sessionID]?.replyPreview = nil
      onDismissAlert?(sessionID)
    }
    persist()
    notifyUnreadCountChanged(from: previousUnreadCount)
  }

  func markNotificationDelivered(recordID: String) {
    guard let index = records.firstIndex(where: { $0.id == recordID }) else { return }
    records[index].notificationDelivered = true
    persist()
  }

  func clearHookEventDiagnostics() {
    guard !hookEventDiagnostics.isEmpty else { return }
    hookEventDiagnostics = []
    persist()
  }

  #if DEBUG
    func injectUITestRecords(multipleSessions: Bool = false, at date: Date = .now) {
      let previousUnreadCount = unreadCount
      let fixtures = [
        ConversationCompletionRecord(
          id: "ui-test-record-codexdone",
          sessionID: "ui-test-session-codexdone",
          turnID: "ui-test-turn-codexdone",
          projectDisplayName: "CodexDone",
          completedAt: date,
          isAcknowledged: false,
          notificationDelivered: true,
          conversationTitle: "优化 CodexDone 菜单信息层级",
          replyPreview: "已调整聊天主题、项目名称与回复预览的层级，菜单内容现在更容易快速浏览。"
        ),
        ConversationCompletionRecord(
          id: "ui-test-record-sprout",
          sessionID: "ui-test-session-sprout",
          turnID: "ui-test-turn-sprout",
          projectDisplayName: "ProjectSprout",
          completedAt: date.addingTimeInterval(-60),
          isAcknowledged: false,
          notificationDelivered: true,
          conversationTitle: "完善课程通知管理",
          replyPreview: "已完成通知范围选择与表单校验的调整，并通过了相关的针对性测试。"
        ),
      ]
      records = multipleSessions ? fixtures : [fixtures[0]]
      hookEventDiagnostics = [
        HookEventDiagnosticRecord(
          id: UUID(uuidString: "00000000-0000-0000-0000-000000000103")!,
          eventName: .stop,
          receivedAt: date,
          ingress: .socket,
          payloadKind: .text,
          outcome: .readyToReview
        ),
        HookEventDiagnosticRecord(
          id: UUID(uuidString: "00000000-0000-0000-0000-000000000102")!,
          eventName: .userPromptSubmit,
          receivedAt: date.addingTimeInterval(-2),
          ingress: .socket,
          payloadKind: .text,
          outcome: .trackingStarted
        ),
        HookEventDiagnosticRecord(
          id: UUID(uuidString: "00000000-0000-0000-0000-000000000101")!,
          eventName: .stop,
          receivedAt: date.addingTimeInterval(-60),
          ingress: .spool,
          payloadKind: .structuredText,
          outcome: .ignoredWithoutPrompt
        ),
      ]
      sessions = Dictionary(
        uniqueKeysWithValues: records.map { record in
          (
            record.sessionID,
            CompletionSessionState(
              sessionID: record.sessionID,
              phase: .readyToReview,
              turnID: record.turnID,
              projectDisplayName: record.projectDisplayName,
              lastEventAt: record.completedAt,
              pendingEventID: nil,
              conversationTitle: record.conversationTitle,
              replyPreview: record.replyPreview
            )
          )
        }
      )
      notifyUnreadCountChanged(from: previousUnreadCount)
    }
  #endif

  private func process(
    _ event: DesktopCompletionHookEvent,
    deliveryMode: HookEventDeliveryMode,
    ingress: HookEventIngress
  ) -> Task<Bool, Never> {
    let previous = saveTask
    let task = Task { @MainActor [weak self] in
      _ = await previous?.value
      guard let self else { return false }
      return await self.persistEvent(event, deliveryMode: deliveryMode, ingress: ingress)
    }
    saveTask = task
    return task
  }

  private func persistEvent(
    _ event: DesktopCompletionHookEvent,
    deliveryMode: HookEventDeliveryMode,
    ingress: HookEventIngress
  ) async -> Bool {
    // Only successfully persisted IDs enter the in-memory deduplication set.
    // A duplicate therefore already has durable ownership and can safely ACK
    // a Socket delivery or delete its Spool copy without another write.
    if processedEventIDs.contains(event.eventID) {
      return true
    }
    let previousUnreadCount = unreadCount

    var candidateSessions = sessions
    var candidateRecords = records
    var candidateProcessedEventIDs = processedEventIDs
    var candidateProcessedEventIDOrder = processedEventIDOrder
    var candidateHookEventDiagnostics = hookEventDiagnostics
    var candidateLastAcceptedEventOrder = lastAcceptedEventOrder
    var candidateLastUserPromptAt = lastUserPromptAt
    var candidateLastStopAt = lastStopAt

    rememberProcessed(
      event.eventID,
      ids: &candidateProcessedEventIDs,
      order: &candidateProcessedEventIDOrder
    )
    recordLatestReceipt(
      for: event,
      lastUserPromptAt: &candidateLastUserPromptAt,
      lastStopAt: &candidateLastStopAt
    )

    let incomingOrder = EventOrderKey(event: event)
    let previousSession = candidateSessions[event.sessionID]
    var effects: [CompletionEffect] = []
    var acknowledgedExistingRecords = false
    var diagnosticOutcome = HookEventDiagnosticOutcome.ignoredOlderEvent
    if let existingOrder = candidateLastAcceptedEventOrder[event.sessionID],
      incomingOrder <= existingOrder
    {
      // Keep the event ID and receipt durable even when ordering makes the
      // state transition a no-op.
    } else {
      candidateLastAcceptedEventOrder[event.sessionID] = incomingOrder
      if event.eventName == .userPromptSubmit {
        if previousSession?.phase == .pendingCompletionDebounce,
          let pendingEventID = previousSession?.pendingEventID
        {
          updateHookEventDiagnostic(
            eventID: pendingEventID,
            outcome: .cancelledByNewPrompt,
            diagnostics: &candidateHookEventDiagnostics
          )
        }
        acknowledgedExistingRecords = acknowledgeRecords(
          for: event.sessionID,
          in: &candidateRecords
        )
        diagnosticOutcome =
          acknowledgedExistingRecords
          ? .trackingStartedAndClearedUnread
          : .trackingStarted
      } else {
        if previousSession?.phase == .pendingCompletionDebounce,
          let pendingEventID = previousSession?.pendingEventID
        {
          updateHookEventDiagnostic(
            eventID: pendingEventID,
            outcome: .supersededByNewStop,
            diagnostics: &candidateHookEventDiagnostics
          )
        }
        let isTrackingTurn =
          previousSession?.phase == .running
          || previousSession?.phase == .pendingCompletionDebounce
        diagnosticOutcome =
          isTrackingTurn
          ? ((previousSession?.suppressesCurrentTurn == true || event.suppressedByRule)
            ? .suppressedByRule
            : .waitingForDebounce)
          : .ignoredWithoutPrompt
      }

      let (session, reducedEffects) = CompletionReducer.reduce(
        session: candidateSessions[event.sessionID],
        event: event
      )
      candidateSessions[event.sessionID] = session
      effects = reducedEffects
    }
    appendHookEventDiagnostic(
      for: event,
      ingress: ingress,
      outcome: diagnosticOutcome,
      diagnostics: &candidateHookEventDiagnostics
    )

    let snapshot = CompletionPersistedState(
      sessions: Array(candidateSessions.values),
      records: candidateRecords,
      processedEventIDs: candidateProcessedEventIDOrder,
      hookEventDiagnostics: candidateHookEventDiagnostics,
      lastUserPromptAt: candidateLastUserPromptAt,
      lastStopAt: candidateLastStopAt
    )
    do {
      try await persistence.save(snapshot)
    } catch {
      persistenceErrorMessage = L10n.text("本地完成记录无法保存")
      return false
    }

    sessions = candidateSessions
    records = candidateRecords
    processedEventIDs = candidateProcessedEventIDs
    processedEventIDOrder = candidateProcessedEventIDOrder
    hookEventDiagnostics = candidateHookEventDiagnostics
    lastAcceptedEventOrder = candidateLastAcceptedEventOrder
    lastUserPromptAt = candidateLastUserPromptAt
    lastStopAt = candidateLastStopAt
    persistenceErrorMessage = nil

    let reducerAlreadyDismissesAlert = effects.contains(
      .dismissAlert(sessionID: event.sessionID)
    )
    if acknowledgedExistingRecords, !reducerAlreadyDismissesAlert {
      onDismissAlert?(event.sessionID)
    }
    apply(effects, sourceEvent: event, deliveryMode: deliveryMode)
    notifyUnreadCountChanged(from: previousUnreadCount)
    return true
  }

  private func recordLatestReceipt(
    for event: DesktopCompletionHookEvent,
    lastUserPromptAt: inout Date?,
    lastStopAt: inout Date?
  ) {
    guard event.source == .codex else { return }
    switch event.eventName {
    case .userPromptSubmit:
      lastUserPromptAt = max(lastUserPromptAt ?? .distantPast, event.receivedAt)
    case .stop:
      lastStopAt = max(lastStopAt ?? .distantPast, event.receivedAt)
    }
  }

  private func restoredEventOrder(for session: CompletionSessionState) -> EventOrderKey {
    let eventName: DesktopHookEventName = session.phase == .running ? .userPromptSubmit : .stop
    let recordEventID = records.first { record in
      record.sessionID == session.sessionID && record.turnID == session.turnID
    }
    .flatMap { UUID(uuidString: $0.id) }
    return EventOrderKey(
      receivedAt: session.lastEventAt,
      eventName: eventName,
      turnID: session.turnID,
      eventID: session.pendingEventID ?? recordEventID ?? EventOrderKey.zeroEventID
    )
  }

  private func apply(
    _ effects: [CompletionEffect],
    sourceEvent: DesktopCompletionHookEvent,
    deliveryMode: HookEventDeliveryMode
  ) {
    for effect in effects {
      switch effect {
      case .cancelPendingAlert(let sessionID):
        debounceTasks.removeValue(forKey: sessionID)?.cancel()
      case .dismissAlert(let sessionID):
        onDismissAlert?(sessionID)
      case .scheduleCompletion(let sessionID, let eventID, let delay):
        let suppressAlert = deliveryMode == .replayWithoutAlert
        let elapsed = Date.now.timeIntervalSince(sourceEvent.receivedAt)
        let requestedSeconds = delay.timeInterval
        let remaining = max(0, requestedSeconds - elapsed)
        scheduleFinalization(
          sessionID: sessionID,
          eventID: eventID,
          delay: .seconds(remaining),
          suppressAlert: suppressAlert
        )
      case .deliverAlert:
        break
      }
    }
  }

  private func scheduleFinalization(
    sessionID: String,
    eventID: UUID,
    delay: Duration,
    suppressAlert: Bool
  ) {
    debounceTasks.removeValue(forKey: sessionID)?.cancel()
    debounceTasks[sessionID] = Task { @MainActor [weak self] in
      do {
        if delay > .zero {
          try await Task.sleep(for: delay)
        }
      } catch {
        return
      }
      guard !Task.isCancelled else { return }
      self?.finalize(sessionID: sessionID, eventID: eventID, suppressAlert: suppressAlert)
    }
  }

  private func finalize(sessionID: String, eventID: UUID, suppressAlert: Bool) {
    debounceTasks.removeValue(forKey: sessionID)
    let previous = saveTask
    let task = Task { @MainActor [weak self] in
      _ = await previous?.value
      guard let self else { return false }
      return await self.persistFinalization(
        sessionID: sessionID,
        eventID: eventID,
        suppressAlert: suppressAlert
      )
    }
    saveTask = task
  }

  private func persistFinalization(
    sessionID: String,
    eventID: UUID,
    suppressAlert: Bool
  ) async -> Bool {
    guard
      let session = sessions[sessionID],
      session.phase == .pendingCompletionDebounce,
      session.pendingEventID == eventID
    else {
      return true
    }
    let previousUnreadCount = unreadCount

    // Close the previous cycle before timestamping the replacement record. The
    // alert coordinator uses dismissal time to reject work that was queued
    // before a Prompt/acknowledgement, so the new cycle must be newer than that
    // dismissal tombstone.
    var candidateRecords = records
    let acknowledgedExistingRecords = acknowledgeRecords(
      for: sessionID,
      in: &candidateRecords
    )

    guard
      let (updated, record, effects) = CompletionReducer.finalize(
        session: session,
        eventID: eventID,
        completedAt: .now,
        suppressAlert: suppressAlert
      )
    else {
      return true
    }

    var candidateSessions = sessions
    candidateSessions[sessionID] = updated
    candidateRecords.removeAll { $0.id == record.id }
    candidateRecords.insert(record, at: 0)
    candidateRecords = Array(candidateRecords.prefix(CompletionPersistence.maximumRecords))
    var candidateHookEventDiagnostics = hookEventDiagnostics
    updateHookEventDiagnostic(
      eventID: eventID,
      outcome: suppressAlert ? .restoredWithoutAlert : .readyToReview,
      diagnostics: &candidateHookEventDiagnostics
    )
    let snapshot = CompletionPersistedState(
      sessions: Array(candidateSessions.values),
      records: candidateRecords,
      processedEventIDs: processedEventIDOrder,
      hookEventDiagnostics: candidateHookEventDiagnostics,
      lastUserPromptAt: lastUserPromptAt,
      lastStopAt: lastStopAt
    )
    do {
      try await persistence.save(snapshot)
    } catch {
      persistenceErrorMessage = L10n.text("本地完成记录无法保存")
      return false
    }

    sessions = candidateSessions
    records = candidateRecords
    hookEventDiagnostics = candidateHookEventDiagnostics
    persistenceErrorMessage = nil
    if acknowledgedExistingRecords {
      onDismissAlert?(sessionID)
    }
    if effects.contains(.deliverAlert(recordID: record.id)) {
      onReadyToReview?(record)
    }
    notifyUnreadCountChanged(from: previousUnreadCount)
    return true
  }

  private func notifyUnreadCountChanged(from previousUnreadCount: Int) {
    guard unreadCount != previousUnreadCount else { return }
    onUnreadCountChanged?(unreadCount)
  }

  private func acknowledgeExistingRecords(for sessionID: String) {
    let changed = acknowledgeRecords(for: sessionID, in: &records)
    if changed {
      onDismissAlert?(sessionID)
    }
  }

  private func acknowledgeRecords(
    for sessionID: String,
    in records: inout [ConversationCompletionRecord]
  ) -> Bool {
    var acknowledgedUnread = false
    for index in records.indices where records[index].sessionID == sessionID {
      if !records[index].isAcknowledged {
        records[index].isAcknowledged = true
        acknowledgedUnread = true
      }
      records[index].conversationTitle = nil
      records[index].replyPreview = nil
    }
    return acknowledgedUnread
  }

  private func rememberProcessed(
    _ eventID: UUID,
    ids: inout Set<UUID>,
    order: inout [UUID]
  ) {
    ids.insert(eventID)
    order.append(eventID)
    if order.count > CompletionPersistence.maximumProcessedEventIDs {
      let overflow = order.count - CompletionPersistence.maximumProcessedEventIDs
      let removed = order.prefix(overflow)
      order.removeFirst(overflow)
      for id in removed where !order.contains(id) {
        ids.remove(id)
      }
    }
  }

  private func appendHookEventDiagnostic(
    for event: DesktopCompletionHookEvent,
    ingress: HookEventIngress,
    outcome: HookEventDiagnosticOutcome,
    diagnostics: inout [HookEventDiagnosticRecord]
  ) {
    diagnostics.removeAll { $0.id == event.eventID }
    diagnostics.insert(
      HookEventDiagnosticRecord(
        id: event.eventID,
        eventName: event.eventName,
        receivedAt: event.receivedAt,
        ingress: ingress,
        payloadKind: HookEventPayloadKind(event: event),
        outcome: outcome
      ),
      at: 0
    )
    diagnostics = Array(diagnostics.prefix(CompletionPersistence.maximumHookEventDiagnostics))
  }

  private func updateHookEventDiagnostic(
    eventID: UUID,
    outcome: HookEventDiagnosticOutcome,
    diagnostics: inout [HookEventDiagnosticRecord]
  ) {
    guard let index = diagnostics.firstIndex(where: { $0.id == eventID }) else { return }
    diagnostics[index].outcome = outcome
  }

  @discardableResult
  private func persist() -> Task<Bool, Never> {
    let snapshot = CompletionPersistedState(
      sessions: Array(sessions.values),
      records: records,
      processedEventIDs: processedEventIDOrder,
      hookEventDiagnostics: hookEventDiagnostics,
      lastUserPromptAt: lastUserPromptAt,
      lastStopAt: lastStopAt
    )
    let previous = saveTask
    let persistence = persistence
    let task = Task { @MainActor [weak self] in
      _ = await previous?.value
      do {
        try await persistence.save(snapshot)
        self?.persistenceErrorMessage = nil
        return true
      } catch {
        self?.persistenceErrorMessage = L10n.text("本地完成记录无法保存")
        return false
      }
    }
    saveTask = task
    return task
  }
}

private struct EventOrderKey: Comparable, Sendable {
  static let zeroEventID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

  let receivedAt: Date
  let eventPriority: UInt8
  let turnID: String
  let eventID: String

  init(event: DesktopCompletionHookEvent) {
    self.init(
      receivedAt: event.receivedAt,
      eventName: event.eventName,
      turnID: event.turnID,
      eventID: event.eventID
    )
  }

  init(
    receivedAt: Date,
    eventName: DesktopHookEventName,
    turnID: String?,
    eventID: UUID
  ) {
    self.receivedAt = receivedAt
    eventPriority = eventName == .userPromptSubmit ? 1 : 0
    self.turnID = turnID ?? ""
    self.eventID = eventID.uuidString.lowercased()
  }

  static func < (lhs: Self, rhs: Self) -> Bool {
    if lhs.receivedAt != rhs.receivedAt {
      return lhs.receivedAt < rhs.receivedAt
    }
    if lhs.eventPriority != rhs.eventPriority {
      return lhs.eventPriority < rhs.eventPriority
    }
    if lhs.turnID != rhs.turnID {
      return lhs.turnID < rhs.turnID
    }
    return lhs.eventID < rhs.eventID
  }
}

extension Duration {
  fileprivate var timeInterval: TimeInterval {
    let components = self.components
    return TimeInterval(components.seconds)
      + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
  }
}
