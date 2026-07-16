import Foundation

/// Persistent, user-overridable settings backed by UserDefaults.
///
/// Public so a downstream Pro build can read/write the settings it shares with the
/// core (`selectedEngineID`, `saveHistoryToDisk`). Most properties remain internal.
public final class Settings {
    public static let shared = Settings()

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let hotkeyKeyCode = "hotkeyKeyCode"
        static let didPromptAccessibility = "didPromptAccessibility"
        static let addTrailingSpace = "addTrailingSpace"
        static let inputDeviceUID = "inputDeviceUID"
        static let saveHistoryToDisk = "saveHistoryToDisk"
        static let selectedEngineID = "selectedEngineID"
        static let appleSpeechAssetsReady = "appleSpeechAssetsReady"
        static let appleSpeechLocaleID = "appleSpeechLocaleID"
    }

    /// The default engine id every build ships with.
    public static let defaultEngineID = "base.en"

    /// Id of the Apple SpeechAnalyzer engine registered on macOS 26+. Preferred
    /// over `defaultEngineID` when available and the user hasn't picked an engine.
    public static let appleSpeechEngineID = "apple.speech"

    /// Id of the transcription engine to load, matched against `EngineRegistry`.
    /// Defaults to the built-in base.en engine, so a free build always resolves it.
    /// A Pro build's engine picker writes this and then calls
    /// `AppExtensionPoints.shared.reloadEngine`.
    public var selectedEngineID: String {
        get { defaults.string(forKey: Keys.selectedEngineID) ?? Self.defaultEngineID }
        set { defaults.set(newValue, forKey: Keys.selectedEngineID) }
    }

    /// Whether the user has ever explicitly chosen an engine. Until they do, the
    /// core is free to pick the best default for the machine (the Apple Speech
    /// engine on macOS 26+, base.en elsewhere).
    var hasExplicitEngineSelection: Bool {
        defaults.string(forKey: Keys.selectedEngineID) != nil
    }

    /// Cached result of the last Apple Speech asset check, so the engine can
    /// report availability synchronously at launch. Re-verified in the background
    /// on every launch by `AppleSpeechAssets.prepare`.
    var appleSpeechAssetsReady: Bool {
        get { defaults.bool(forKey: Keys.appleSpeechAssetsReady) }
        set { defaults.set(newValue, forKey: Keys.appleSpeechAssetsReady) }
    }

    /// BCP-47 identifier of the transcriber locale resolved during asset
    /// preparation (the user's locale when supported, else en-US).
    var appleSpeechLocaleID: String? {
        get { defaults.string(forKey: Keys.appleSpeechLocaleID) }
        set { defaults.set(newValue, forKey: Keys.appleSpeechLocaleID) }
    }

    /// UID of the microphone to record from. When set, Votelli always uses this
    /// device instead of following the system default input. nil = system default.
    var inputDeviceUID: String? {
        get { defaults.string(forKey: Keys.inputDeviceUID) }
        set {
            if let newValue = newValue {
                defaults.set(newValue, forKey: Keys.inputDeviceUID)
            } else {
                defaults.removeObject(forKey: Keys.inputDeviceUID)
            }
        }
    }

    /// Virtual keycode of the push-to-talk modifier. Default 61 = Right Option (⌥).
    var hotkeyKeyCode: Int {
        get { defaults.object(forKey: Keys.hotkeyKeyCode) as? Int ?? 61 }
        set { defaults.set(newValue, forKey: Keys.hotkeyKeyCode) }
    }

    /// Append a space after each dictation so consecutive dictations don't run
    /// together. Default true.
    var addTrailingSpace: Bool {
        get { defaults.object(forKey: Keys.addTrailingSpace) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.addTrailingSpace) }
    }

    /// Persist transcription history to disk so it survives quitting. Default false:
    /// dictation is sensitive, so history stays in memory only unless the user opts in.
    ///
    /// Public because a Pro build surfaces the same opt-in next to its history controls,
    /// where the choice actually costs the user something. Writing this alone only changes
    /// what future dictations do — call `AppExtensionPoints.shared.setHistoryPersistenceEnabled`
    /// after, as the core's own Preferences window does, so the existing buffer is written
    /// (or the file removed) to match.
    public var saveHistoryToDisk: Bool {
        get { defaults.bool(forKey: Keys.saveHistoryToDisk) }
        set { defaults.set(newValue, forKey: Keys.saveHistoryToDisk) }
    }

    /// Whether we've shown the system Accessibility dialog once (avoid nagging).
    var didPromptAccessibility: Bool {
        get { defaults.bool(forKey: Keys.didPromptAccessibility) }
        set { defaults.set(newValue, forKey: Keys.didPromptAccessibility) }
    }
}
