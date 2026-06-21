import CoreGraphics
import Foundation

/// Types text into whatever app currently has keyboard focus by synthesizing
/// Unicode key events. This preserves the clipboard (unlike a paste approach).
/// Requires Accessibility permission to post events to other apps.
enum TextInjector {
    static func type(_ text: String) {
        guard !text.isEmpty else { return }
        let source = CGEventSource(stateID: .combinedSessionState)

        // keyboardSetUnicodeString is reliable in small chunks; split the string.
        let units = Array(text.utf16)
        let chunkSize = 16
        var index = 0
        while index < units.count {
            let end = min(index + chunkSize, units.count)
            postUnicode(Array(units[index..<end]), source: source)
            index = end
        }
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
