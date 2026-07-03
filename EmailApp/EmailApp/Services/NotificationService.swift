import UserNotifications

enum NotificationService {
    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
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
