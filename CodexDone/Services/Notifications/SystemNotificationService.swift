import Foundation
import UserNotifications

@MainActor
protocol CompletionNotificationDriving: AnyObject {
  func deliver(
    alertID: String,
    situation: AlertSituation,
    title: String,
    playSound: Bool
  ) async
  func remove(alertIDs: Set<String>)
}

final class SystemNotificationService: NSObject, @unchecked Sendable,
  UNUserNotificationCenterDelegate
{
  private let center: UNUserNotificationCenter
  var onNotificationOpened: (@Sendable (String) -> Void)?

  init(center: UNUserNotificationCenter = .current()) {
    self.center = center
    super.init()
    center.delegate = self
  }

  func authorizationStatus() async -> UNAuthorizationStatus {
    await center.notificationSettings().authorizationStatus
  }

  func requestAuthorization() async -> Bool {
    (try? await center.requestAuthorization(options: [.alert, .badge, .sound])) ?? false
  }

  func deliver(
    alertID: String,
    situation: AlertSituation,
    title: String,
    playSound: Bool
  ) async {
    let settings = await center.notificationSettings()
    guard
      settings.authorizationStatus == .authorized
        || settings.authorizationStatus == .provisional
    else {
      return
    }
    guard !Task.isCancelled else { return }
    let content = Self.notificationContent(
      alertID: alertID,
      situation: situation,
      title: title,
      playSound: playSound
    )
    let request = UNNotificationRequest(
      identifier: Self.notificationIdentifier(alertID: alertID),
      content: content,
      trigger: nil
    )
    try? await center.add(request)
  }

  func remove(alertIDs: Set<String>) {
    guard !alertIDs.isEmpty else { return }
    let identifiers = alertIDs.map(Self.notificationIdentifier(alertID:))
    center.removePendingNotificationRequests(withIdentifiers: identifiers)
    center.removeDeliveredNotifications(withIdentifiers: identifiers)
  }

  static func notificationContent(
    alertID: String,
    situation: AlertSituation,
    title: String? = nil,
    playSound: Bool
  ) -> UNMutableNotificationContent {
    let content = UNMutableNotificationContent()
    content.title = AlertHeadlineChannel.normalized(title) ?? situation.alertTitle
    content.body = situation.alertBody
    content.sound = playSound ? .default : nil
    content.userInfo = [
      "alertID": alertID,
      "situation": situation.rawValue,
    ]
    return content
  }

  static var foregroundPresentationOptions: UNNotificationPresentationOptions {
    [.banner, .list, .sound]
  }

  private static func notificationIdentifier(alertID: String) -> String {
    "codexdone.\(alertID)"
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler(Self.foregroundPresentationOptions)
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    if let alertID = response.notification.request.content.userInfo["alertID"] as? String {
      onNotificationOpened?(alertID)
    }
    completionHandler()
  }
}

extension SystemNotificationService: CompletionNotificationDriving {}
