import AppKit
import UserNotifications

/// Posts user-facing notifications for the rare cases where a clip can't be typed
/// or recording is disrupted, so words are never silently lost.
///
/// UNUserNotificationCenter requires a registered app bundle; calling
/// `.current()` from a bare `swift run` binary (no .app) throws. We only touch it
/// when running inside a real `.app`, and fall back to logging otherwise. The
/// clipboard recovery that accompanies these calls is what actually protects the
/// text — the notification just tells the user where it went.
enum Notifier {
    /// True when we're running inside a real .app bundle where notifications work.
    private static var isBundledApp: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    /// Ask once at launch so later notifications can actually display.
    static func requestAuthorization() {
        guard isBundledApp else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error = error {
                mlog("notification authorization error: \(error)")
            } else {
                mdebug("notification authorization granted=\(granted)")
            }
        }
    }

    static func notify(title: String, body: String) {
        mlog("notify: \(title) — \(body)")
        guard isBundledApp else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error { mlog("failed to post notification: \(error)") }
        }
    }
}
