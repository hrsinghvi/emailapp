import AppKit
import UserNotifications

/// Handles the two things a plain SwiftUI `App` can't: requesting
/// notification permission at launch, and routing a clicked notification
/// back to the specific message it was about.
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    weak var vm: InboxViewModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        NotificationService.requestAuthorization()
    }

    /// Settings > General > "Quit fully when the last window closes" — the
    /// default SwiftUI behavior already keeps the app running (returning
    /// false here), so this only matters when the user opts into the
    /// non-default "quit fully" behavior.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        AppSettings.shared.quitBehavior == .quitFully
    }

    /// Show the banner even while the app is frontmost — otherwise new-mail
    /// notifications would silently do nothing if you happened to be
    /// looking at the app already.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        NSApp.activate(ignoringOtherApps: true)
        if let idString = response.notification.request.content.userInfo["messageId"] as? String,
           let id = UUID(uuidString: idString) {
            Task { @MainActor in self.vm?.openMessage(byId: id) }
        }
        completionHandler()
    }
}
