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

    // MARK: History persistence

    /// Set by the core at launch. A Pro build calls this after changing
    /// `Settings.saveHistoryToDisk` so the switch takes effect on the history that already
    /// exists: turning it on writes the current buffer out, turning it off removes the file.
    /// Without this the setting would only govern the *next* dictation, which is not what
    /// either checkbox claims. nil until the core wires it up.
    public var setHistoryPersistenceEnabled: ((Bool) -> Void)?

    // MARK: History capacity

    /// Set by the core at launch. A Pro build calls this when the user picks a new history
    /// size, instead of writing `HistorySettings.capacity` itself: the core owns the buffer,
    /// so only the core can re-trim what's already in memory, persist the result, and refresh
    /// an open history window. Writing the static alone would leave the choice governing only
    /// the *next* dictation — and the retention floor would hold the old size indefinitely,
    /// so a lowered capacity would never take effect at all.
    ///
    /// Calling this is also what lifts the floor: an explicit choice is the consent the floor
    /// exists to require, so entries beyond the new size are deleted. A build that never calls
    /// it (the free build has no capacity UI) keeps the floor and its inherited archive.
    /// nil until the core wires it up.
    public var applyHistoryCapacity: ((Int) -> Void)?

    // MARK: Recording lifecycle

    /// Fired when audio capture actually begins — after the recorder starts, not when the
    /// hotkey is merely pressed, so it never fires for a refused start (no mic, no
    /// permission). A Pro build uses it to warm up work that would otherwise be paid for
    /// on the transcription queue while the user waits for their text: today, loading the
    /// on-device language model used for AI cleanup, which takes long enough to matter and
    /// overlaps neatly with the user still speaking.
    ///
    /// Main-thread only, like the hooks above. nil (free build) is a no-op.
    public var recordingDidStart: (() -> Void)?

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

    /// The same Pro vocabulary as raw terms rather than a prose prompt, for
    /// engines with a native contextual-biasing hook (the Apple Speech engine
    /// feeds these to `AnalysisContext.contextualStrings`). A Pro build should
    /// set both this and `vocabularyPrompt` so every engine benefits.
    ///
    /// Invoked on the transcription queue, so it must be safe to read off-main.
    public var vocabularyTerms: (() -> [String])?

    /// A Pro-contributed pure transform applied to each transcript after the core's
    /// `TextProcessing.clean` and before delivery — the seam for user replacement
    /// rules and for on-device AI cleanup, which a Pro build composes into a single
    /// chain. Kept a simple `String -> String` so both can share it. nil (free build)
    /// is the identity.
    ///
    /// Invoked on the transcription queue, so it must be safe to run off-main.
    public var transformTranscript: ((String) -> String)?
}
