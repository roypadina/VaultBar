import Foundation
import UserNotifications

private let keepUnlockedAction = "keep-unlocked-15"
private let forceSoonCategory = "force-soon"

/// Lock notifications. Wording stays generic (no vault names): they can show on the lock screen. If notifications
/// are denied, everything here silently does nothing.
extension AppController: UNUserNotificationCenterDelegate {
    /// No bundle (`swift run`) means no notification center; `UNUserNotificationCenter.current()` would throw.
    private var canNotify: Bool { Bundle.main.bundleIdentifier != nil }

    func setUpNotifications() {
        guard canNotify else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let keep = UNNotificationAction(identifier: keepUnlockedAction, title: "Keep unlocked 15 min")
        center.setNotificationCategories([
            UNNotificationCategory(identifier: forceSoonCategory, actions: [keep], intentIdentifiers: []),
        ])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func notify(_ body: String, keepUnlockedAction offerKeep: Bool = false) {
        guard canNotify else { return }
        let content = UNMutableNotificationContent()
        content.title = "VaultBar"
        content.body = body
        if offerKeep { content.categoryIdentifier = forceSoonCategory }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.actionIdentifier == keepUnlockedAction {
            Task { @MainActor in self.keepUnlocked() }
        }
        completionHandler()
    }

    /// VaultBar is almost never the frontmost app, but show the banner if it is.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }
}
