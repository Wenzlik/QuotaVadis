import AppKit
import UserNotifications
import QuotaCore

/// Owns the notification categories and the delegate: "Snooze 1 h" action, clicks activate the app,
/// banners show even while QuotaVadis is frontmost.
@MainActor
final class NotificationCoordinator: NSObject, UNUserNotificationCenterDelegate {
    static let category = "quota"
    static let snoozeAction = "snooze"
    var onSnooze: ((String) -> Void)?

    override init() {
        super.init()
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let snooze = UNNotificationAction(identifier: Self.snoozeAction, title: "Snooze 1 hour")
        center.setNotificationCategories([UNNotificationCategory(identifier: Self.category, actions: [snooze], intentIdentifiers: [])])
    }

    func deliver(_ alerts: [QuotaAlert]) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            for alert in alerts {
                let content = UNMutableNotificationContent()
                content.title = alert.title
                content.body = alert.body
                content.categoryIdentifier = Self.category
                content.userInfo = ["key": alert.key]
                content.sound = alert.kind == .threshold ? .default : nil
                content.threadIdentifier = alert.key.split(separator: "/").first.map(String.init) ?? "quota"
                center.add(UNNotificationRequest(identifier: alert.id + "/" + UUID().uuidString, content: content, trigger: nil))
            }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let key = response.notification.request.content.userInfo["key"] as? String
        let action = response.actionIdentifier
        await MainActor.run {
            if action == Self.snoozeAction, let key { onSnooze?(key) }
            else { NSApp.activate(ignoringOtherApps: true) }
        }
    }
}
