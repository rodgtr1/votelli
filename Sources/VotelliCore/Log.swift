import Foundation

/// Verbose diagnostics (per-keystroke events, transcription text) are only written
/// when VOTELLI_DEBUG=1 is set in the environment.
let votelliDebugEnabled = ProcessInfo.processInfo.environment["VOTELLI_DEBUG"] == "1"

/// All file writes are serialized here so concurrent callers (main thread, the
/// transcription work queue, timers) can't interleave or race on the file handle.
private let logQueue = DispatchQueue(label: "media.travis.votelli.log")

private let logFileURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Logs/Votelli.log")

/// Keep the log from growing without bound; truncate once it passes this size.
private let logMaxBytes = 1_000_000

/// Confined to `logQueue`, so it's safe to reuse despite DateFormatter not being
/// thread-safe.
private let logFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f
}()

/// Appends a line to ~/Library/Logs/Votelli.log (and NSLog). Used for lifecycle
/// diagnostics since GUI apps launched via LaunchServices don't surface stderr.
public func mlog(_ message: String) {
    NSLog("Votelli: \(message)")
    let now = Date()
    logQueue.async {
        let line = "\(logFormatter.string(from: now)) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        rotateIfNeeded()
        if let handle = try? FileHandle(forWritingTo: logFileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: logFileURL)
        }
    }
}

/// Like `mlog`, but only when VOTELLI_DEBUG=1. Use for noisy or sensitive output.
public func mdebug(_ message: @autoclosure () -> String) {
    guard votelliDebugEnabled else { return }
    mlog(message())
}

/// Truncate the log if it has grown past the cap. Runs on `logQueue`.
private func rotateIfNeeded() {
    let attrs = try? FileManager.default.attributesOfItem(atPath: logFileURL.path)
    let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
    guard size > logMaxBytes else { return }
    try? FileManager.default.removeItem(at: logFileURL)
}
