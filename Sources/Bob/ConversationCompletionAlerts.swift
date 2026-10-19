import AppKit
import UserNotifications
import BobCore

/// Shared across project windows so foreground notification presentation has one delegate.
@MainActor final class ConversationCompletionAlerts: NSObject, UNUserNotificationCenterDelegate {
    static let shared = ConversationCompletionAlerts()

    func post(session: Session, runID: UUID) {
        // UNUserNotificationCenter requires an app bundle. Keep swift run and test
        // hosts working without attempting to register them for notifications.
        guard Bundle.main.bundleURL.pathExtension == "app",
              Bundle.main.bundleIdentifier == "com.bob.native" else { return }
        NSSound(named: "Glass")?.play()

        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let content = UNMutableNotificationContent()
        content.title = "Conversation complete"
        content.subtitle = session.title
        content.body = "Bob has finished responding."
        content.threadIdentifier = session.id.uuidString
        // The chime above also works when notification permission is denied.
        // Do not attach a notification sound, which would play a second chime.
        Task {
            do {
                guard try await center.requestAuthorization(options: [.alert]) else { return }
                try await center.add(UNNotificationRequest(identifier: runID.uuidString, content: content, trigger: nil))
            } catch {
                // Notification delivery must never turn a successful run into a failure.
                NSLog("Bob could not deliver a conversation completion notification: %@", error.localizedDescription)
            }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }
}
