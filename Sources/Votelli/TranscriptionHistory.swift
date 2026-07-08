import Foundation

/// One delivered transcription, kept so the user can recover recent dictation.
struct HistoryEntry: Codable {
    let text: String
    let date: Date
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
final class TranscriptionHistory {
    /// Keep at most this many entries; oldest drop off the front.
    private static let capacity = 50

    /// Newest last.
    private var entries: [HistoryEntry] = []

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
                // Prepend loaded entries so anything recorded during launch stays newest.
                self.entries = (loaded + self.entries).suffix(Self.capacity).map { $0 }
                mlog("history: loaded \(loaded.count) entr\(loaded.count == 1 ? "y" : "ies") from disk")
                completion()
            }
        }
    }

    /// Record a delivered transcript. Trims to `capacity` and persists if enabled.
    func record(_ text: String, date: Date) {
        entries.append(HistoryEntry(text: text, date: date))
        if entries.count > Self.capacity {
            entries.removeFirst(entries.count - Self.capacity)
        }
        persistIfEnabled()
    }

    /// The `n` most recent transcriptions, newest first.
    func recent(_ n: Int) -> [HistoryEntry] {
        Array(entries.suffix(n).reversed())
    }

    /// Empty the buffer and remove any persisted file.
    func clear() {
        entries.removeAll()
        deleteFile()
        mlog("history: cleared")
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
        let snapshot = entries
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
