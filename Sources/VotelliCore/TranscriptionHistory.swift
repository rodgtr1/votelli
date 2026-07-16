import AppKit

/// One delivered transcription, kept so the user can recover recent dictation.
public struct HistoryEntry: Codable {
    public let text: String
    public let date: Date

    public init(text: String, date: Date) {
        self.text = text
        self.date = date
    }
}

/// How many transcriptions the history retains. Split out of `TranscriptionHistory` so a
/// Pro build can raise the ceiling before `VotelliMain()`, in the same spirit as
/// `AppExtensionPoints` — the core owns the buffer, the Pro build owns the policy.
///
/// Main-thread only; set before `VotelliMain()`. Left at the free default, behavior is
/// exactly what it was when the capacity was a hardcoded constant.
public enum HistorySettings {
    /// Retain at most this many entries; oldest drop off the front. `unlimited` (0) keeps
    /// everything, which only makes sense for a build that gives the user a real history
    /// window to search — the free build's 5-item Recent menu doesn't need the memory.
    public static var capacity: Int = 50

    /// Sentinel for "never trim". Zero is the one value meaningless as a real capacity — a
    /// history that retains nothing can't back even the Recent menu — so it's free to carry
    /// this meaning instead of stealing a plausible setting.
    public static let unlimited = 0

    /// Drop the oldest entries beyond `capacity`. Pure and total: `unlimited` returns the
    /// input untouched, and a shorter-than-capacity list is already fine.
    ///
    /// The single place trimming happens, so `load()` and `record()` can't drift apart —
    /// they enforced the same rule via two different expressions before.
    public static func trimmed(_ entries: [HistoryEntry]) -> [HistoryEntry] {
        trimmed(entries, preservingAtLeast: 0)
    }

    /// Trim to `capacity`, but never below `floor` — the retention floor.
    ///
    /// Why this exists: free and Pro share a bundle id and one `history.json`. A Pro build
    /// may have persisted thousands of entries; any build where Pro features are off (a free
    /// install over Pro, or a license check that stops passing) leaves `capacity` at the free
    /// 50. Without a floor, `load()` would trim 5000 entries to 50 in memory and the very next
    /// `record()` would write that back — silently destroying an archive the user paid for.
    /// Callers pass the number of entries they loaded from disk, so what was already on disk
    /// survives a build that wouldn't have created it.
    ///
    /// The consequence, deliberate: a free build holding a 5000-entry Pro file retains all
    /// 5000 and rolls (a new entry pushes the oldest out; the buffer never shrinks below the
    /// floor) while the Recent menu still shows only 5. Memory the free build wouldn't have
    /// chosen, in exchange for not destroying data it didn't create.
    ///
    /// The floor protects only builds that never call `AppExtensionPoints.applyHistoryCapacity`
    /// — which is exactly the builds with no capacity UI to call it from. A Pro user picking a
    /// smaller size goes through that hook, which drops the floor to 0 first: an explicit
    /// choice is the consent the floor exists to require, and a floor that outlived it would
    /// pin the capacity at whatever the file happened to hold, forever.
    ///
    /// `unlimited` still bypasses trimming entirely, and `floor: 0` is the floor-less rule
    /// unchanged.
    public static func trimmed(_ entries: [HistoryEntry], preservingAtLeast floor: Int) -> [HistoryEntry] {
        guard capacity != unlimited else { return entries }
        let effective = max(capacity, floor)
        guard entries.count > effective else { return entries }
        return Array(entries.suffix(effective))
    }
}

/// In-memory ring buffer of recent transcriptions — the final data-loss backstop.
/// Every transcript that reaches `AppDelegate.deliver()` is recorded here, whether
/// it was typed or fell back to the clipboard.
///
/// Privacy: memory-only by default, so history vanishes on quit. Persistence to
/// disk is strictly opt-in (`Settings.saveHistoryToDisk`) because dictation is
/// sensitive; when enabled it's written as plain JSON with 0600 permissions.
///
/// All access is confined to the main thread; only the disk I/O hops to `ioQueue`.
final class TranscriptionHistory: HistoryReading {
    /// Newest last.
    private var _entries: [HistoryEntry] = []

    /// How many entries `load()` read from disk this session — the retention floor passed to
    /// `HistorySettings.trimmed(_:preservingAtLeast:)`. A build with a capacity lower than the
    /// file it inherited (free running over a Pro archive) must not trim the buffer and then
    /// persist the loss. Main-thread only, like `_entries`.
    private var loadedFromDiskCount = 0

    /// Handlers fired on the main thread whenever the entries change, so a Pro
    /// history window can refresh live. Registered via `addChangeObserver`.
    private var changeObservers: [() -> Void] = []

    /// Serializes file reads/writes so overlapping saves can't corrupt the file.
    private let ioQueue = DispatchQueue(label: "media.travis.votelli.history")

    private static let directoryURL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Votelli", isDirectory: true)

    private static let fileURL = directoryURL.appendingPathComponent("history.json")

    /// Load persisted history if the user has opted into saving it. Call once on launch.
    /// `completion` runs on the main thread after any entries are loaded.
    func load(completion: @escaping () -> Void) {
        guard Settings.shared.saveHistoryToDisk else { return }
        ioQueue.async {
            guard let data = try? Data(contentsOf: Self.fileURL) else { return }
            guard let loaded = try? JSONDecoder().decode([HistoryEntry].self, from: data) else {
                mlog("history: failed to decode \(Self.fileURL.lastPathComponent)")
                return
            }
            DispatchQueue.main.async {
                // What was on disk sets the floor: this build keeps everything it found,
                // whether or not its own capacity would have retained that much.
                self.loadedFromDiskCount = loaded.count
                // Prepend loaded entries so anything recorded during launch stays newest.
                self._entries = HistorySettings.trimmed(
                    loaded + self._entries, preservingAtLeast: self.loadedFromDiskCount
                )
                mlog("history: loaded \(loaded.count) entr\(loaded.count == 1 ? "y" : "ies") from disk")
                self.notifyChange()
                completion()
            }
        }
    }

    /// Record a delivered transcript. Trims to `HistorySettings.capacity` — but never below
    /// what `load()` read from disk, so appending can't be what destroys an inherited archive
    /// — and persists if enabled.
    func record(_ text: String, date: Date) {
        _entries.append(HistoryEntry(text: text, date: date))
        _entries = HistorySettings.trimmed(_entries, preservingAtLeast: loadedFromDiskCount)
        persistIfEnabled()
        notifyChange()
    }

    /// The `n` most recent transcriptions, newest first.
    func recent(_ n: Int) -> [HistoryEntry] {
        Array(_entries.suffix(n).reversed())
    }

    /// Empty the buffer and remove any persisted file.
    ///
    /// Drops the retention floor too: the floor exists to stop trimming from destroying an
    /// archive behind the user's back, and this is the user asking for exactly that. After a
    /// clear the buffer refills under this build's own capacity.
    func clear() {
        _entries.removeAll()
        loadedFromDiskCount = 0
        deleteFile()
        mlog("history: cleared")
        notifyChange()
    }

    /// Apply a user-chosen history capacity: retain `capacity`, drop the rest, now.
    ///
    /// Only a build with capacity UI reaches this (via `AppExtensionPoints.applyHistoryCapacity`),
    /// which is why it's allowed to do what `record()` mustn't: it clears the retention floor.
    /// The floor stops a build from destroying an archive *behind the user's back*; this is the
    /// user in front of it, choosing. Leaving the floor up would make lowering the capacity a
    /// no-op — `max(newCapacity, loadedFromDiskCount)` is just the old size back — so the
    /// setting would silently never work.
    ///
    /// Trims and persists immediately rather than letting the next append do it, and notifies
    /// observers so an open history window shows the result while the user is still looking at
    /// the picker. Main-thread only, like the rest of this class.
    func applyCapacity(_ capacity: Int) {
        HistorySettings.capacity = capacity
        loadedFromDiskCount = 0
        _entries = HistorySettings.trimmed(_entries)
        mlog("history: capacity set to \(capacity) — \(_entries.count) entr\(_entries.count == 1 ? "y" : "ies") retained")
        persistIfEnabled()
        notifyChange()
    }

    // MARK: - HistoryReading

    /// All retained entries, newest last. Exposed to a Pro history window.
    var entries: [HistoryEntry] { _entries }

    func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        mlog("history: copied \(text.count) chars to clipboard")
    }

    func addChangeObserver(_ handler: @escaping () -> Void) {
        changeObservers.append(handler)
    }

    private func notifyChange() {
        for observer in changeObservers { observer() }
    }

    /// React to the "Save history to disk" setting changing. When turned on, write
    /// what we already have; when turned off, delete the file (memory copy stays).
    func setPersistenceEnabled(_ enabled: Bool) {
        if enabled {
            mlog("history: disk persistence enabled")
            persistIfEnabled()
        } else {
            mlog("history: disk persistence disabled — removing file")
            deleteFile()
        }
    }

    // MARK: - Disk

    private func persistIfEnabled() {
        guard Settings.shared.saveHistoryToDisk else { return }
        let snapshot = _entries
        ioQueue.async {
            do {
                try FileManager.default.createDirectory(
                    at: Self.directoryURL, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                let data = try JSONEncoder().encode(snapshot)
                try data.write(to: Self.fileURL, options: .atomic)
                // Enforce owner-only permissions even if the file already existed.
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600], ofItemAtPath: Self.fileURL.path
                )
            } catch {
                mlog("history: failed to save — \(error.localizedDescription)")
            }
        }
    }

    private func deleteFile() {
        ioQueue.async {
            try? FileManager.default.removeItem(at: Self.fileURL)
        }
    }
}
