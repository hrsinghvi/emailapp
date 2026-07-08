import UserNotifications

enum NotificationService {
    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    /// The Dock badge — via `UNUserNotificationCenter`, not
    /// `NSApplication.shared.dockTile.badgeLabel`. The latter is
    /// process-local: it's held in the running app's own memory, so the
    /// moment the app quits, the badge vanishes with it (even though the
    /// unread count it represented is still true). Setting it through the
    /// notification center instead makes macOS own the badge state, so it
    /// stays on the Dock icon regardless of whether the app is running.
    static func setBadgeCount(_ count: Int) {
        UNUserNotificationCenter.current().setBadgeCount(count)
    }

    /// Only ever called for genuinely new mail (see `handleRealtimeInsert`) —
    /// never for the initial sync of existing messages.
    static func notifyNewMail(_ message: Message) {
        guard message.folder == "inbox" else { return }
        let content = UNMutableNotificationContent()
        content.title = message.senderName
        content.subtitle = message.subject
        content.body = message.snippet
        content.sound = .default
        content.userInfo = ["messageId": message.id.uuidString]
        let request = UNNotificationRequest(identifier: message.id.uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
