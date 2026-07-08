import Foundation

/// Read-only access to the app's live transcription history, handed to a Pro
/// history window so it can list and re-copy past dictation without owning the
/// data. The free build never touches this — nothing reads it.
///
/// Main-thread only.
public protocol HistoryReading: AnyObject {
    /// All retained entries, newest last.
    var entries: [HistoryEntry] { get }
    /// Copy text to the clipboard (the same path the status menu uses).
    func copyToClipboard(_ text: String)
    /// Register a handler fired on the main thread whenever `entries` changes.
    func addChangeObserver(_ handler: @escaping () -> Void)
}

/// Generic hooks a Pro build fills at startup and the free build leaves empty.
/// The core queries these; when a hook is nil, the corresponding UI (menu item,
/// button) simply doesn't appear, so the free app is unchanged.
///
/// Engines are contributed separately, through `EngineRegistry`.
///
/// Main-thread only; set before `VotelliMain()`.
public final class AppExtensionPoints {
    public static let shared = AppExtensionPoints()
    private init() {}

    // MARK: Preferences

    /// A Pro-contributed preferences section. When set, the core Preferences
    /// window shows a button (titled `preferencesButtonTitle`) that invokes this —
    /// typically to open the Pro settings window (model download, engine picker).
    public var openProPreferences: (() -> Void)?

    /// Title of the button that opens the Pro preferences section.
    public var preferencesButtonTitle: String = "Pro Settings…"

    // MARK: History window

    /// A Pro-contributed history window. When set, the status menu shows a
    /// "History…" item that invokes this, passing read access to the history.
    public var openHistoryWindow: ((HistoryReading) -> Void)?

    // MARK: Engine reload

    /// Set by the core at launch. A Pro build calls this after changing
    /// `Settings.selectedEngineID` so the newly-selected engine loads without a
    /// restart. nil until the core wires it up.
    public var reloadEngine: (() -> Void)?

    // MARK: Vocabulary

    /// A Pro-contributed whisper `initial_prompt`: a short natural-language string
    /// of domain words/names that biases recognition. The core wires this into the
    /// base.en engine (and Pro engines read it too), evaluating it fresh per
    /// transcription so vocabulary edits apply on the next dictation without an
    /// engine reload. nil (free build) means no biasing — behavior is unchanged.
    ///
    /// Unlike the hooks above, this is *invoked* on the transcription queue (not the
    /// main thread), so an implementation must be safe to read off-main.
    public var vocabularyPrompt: (() -> String?)?

    /// A Pro-contributed pure transform applied to each transcript after the core's
    /// `TextProcessing.clean` and before delivery — the seam for user replacement
    /// rules today, and where Phase 4 AI cleanup will plug in. Kept a simple
    /// `String -> String` so both can share it. nil (free build) is the identity.
    ///
    /// Invoked on the transcription queue, so it must be safe to run off-main.
    public var transformTranscript: ((String) -> String)?
}
