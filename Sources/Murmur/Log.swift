import Foundation

/// Verbose diagnostics (per-keystroke events, transcription text) are only written
/// when MURMUR_DEBUG=1 is set in the environment.
let murmurDebugEnabled = ProcessInfo.processInfo.environment["MURMUR_DEBUG"] == "1"

/// Appends a line to ~/Library/Logs/Murmur.log (and NSLog). Used for lifecycle
/// diagnostics since GUI apps launched via LaunchServices don't surface stderr.
func mlog(_ message: String) {
    NSLog("Murmur: \(message)")
    let line = "\(logTimestamp()) \(message)\n"
    let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Murmur.log")
    guard let data = line.data(using: .utf8) else { return }
    if let handle = try? FileHandle(forWritingTo: url) {
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    } else {
        try? data.write(to: url)
    }
}

/// Like `mlog`, but only when MURMUR_DEBUG=1. Use for noisy or sensitive output.
func mdebug(_ message: @autoclosure () -> String) {
    guard murmurDebugEnabled else { return }
    mlog(message())
}

private func logTimestamp() -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f.string(from: Date())
}
