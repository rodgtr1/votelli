import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// Types text into whatever app currently has keyboard focus by synthesizing
/// Unicode key events. This preserves the clipboard (unlike a paste approach).
/// Requires Accessibility permission to post events to other apps.
enum TextInjector {
    /// Electron- and Java-based apps (VS Code, Slack, IntelliJ) drop synthesized
    /// keystrokes when events arrive back-to-back with no gap. A small pause
    /// between chunks lets their event loops keep up. Tune up if drops persist.
    private static let interChunkDelay: useconds_t = 1_500  // microseconds

    /// Attempts to type `text` into the focused app. Returns false if typing is
    /// blocked — Accessibility not granted, or secure input active (e.g. a
    /// password field) — so the caller can fall back to the clipboard instead of
    /// losing the words.
    @discardableResult
    static func type(_ text: String) -> Bool {
        guard !text.isEmpty else { return true }

        // Secure input (password fields, some lock screens) swallows synthetic
        // key events system-wide; posting would silently drop every character.
        guard !IsSecureEventInputEnabled() else {
            mlog("typing blocked: secure event input active (password field?)")
            return false
        }
        // Without Accessibility, posted events never reach other apps.
        guard Permissions.accessibilityEnabled(prompt: false) else {
            mlog("typing blocked: Accessibility not granted")
            return false
        }

        let source = CGEventSource(stateID: .combinedSessionState)

        // keyboardSetUnicodeString is reliable in small chunks; split the string.
        let units = Array(text.utf16)
        let chunkSize = 16
        var index = 0
        while index < units.count {
            let end = min(index + chunkSize, units.count)
            postUnicode(Array(units[index..<end]), source: source)
            index = end
            if index < units.count { usleep(interChunkDelay) }
        }
        return true
    }

    private static func postUnicode(_ utf16: [UniChar], source: CGEventSource?) {
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
            return
        }
        var chars = utf16
        down.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: &chars)
        up.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: &chars)
        down.post(tap: .cgAnnotatedSessionEventTap)
        up.post(tap: .cgAnnotatedSessionEventTap)
    }
}
