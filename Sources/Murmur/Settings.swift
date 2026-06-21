import Foundation

/// Persistent, user-overridable settings backed by UserDefaults.
final class Settings {
    static let shared = Settings()

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let hotkeyKeyCode = "hotkeyKeyCode"
        static let didPromptAccessibility = "didPromptAccessibility"
    }

    /// Virtual keycode of the push-to-talk modifier. Default 61 = Right Option (⌥).
    var hotkeyKeyCode: Int {
        get { defaults.object(forKey: Keys.hotkeyKeyCode) as? Int ?? 61 }
        set { defaults.set(newValue, forKey: Keys.hotkeyKeyCode) }
    }

    /// Whether we've shown the system Accessibility dialog once (avoid nagging).
    var didPromptAccessibility: Bool {
        get { defaults.bool(forKey: Keys.didPromptAccessibility) }
        set { defaults.set(newValue, forKey: Keys.didPromptAccessibility) }
    }
}
