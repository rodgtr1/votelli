import Foundation
import CWhisper

/// Wraps the whisper.cpp model. Loading is expensive; do it once off the main thread.
final class Transcriber {
    private let ctx: OpaquePointer
    private let threads: Int32

    init?(modelPath: String, useGPU: Bool = true) {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        threads = Int32(min(max(cores - 2, 2), 8))
        guard let ctx = murmur_whisper_init(modelPath, useGPU ? 1 : 0) else { return nil }
        self.ctx = ctx
    }

    /// Transcribe 16kHz mono samples. Returns nil on failure or empty input.
    func transcribe(_ samples: [Float]) -> String? {
        guard !samples.isEmpty else { return nil }
        let raw = samples.withUnsafeBufferPointer { buf in
            murmur_whisper_transcribe(ctx, buf.baseAddress, Int32(buf.count), threads)
        }
        guard let raw = raw else { return nil }
        defer { murmur_whisper_free_string(raw) }
        return String(cString: raw)
    }

    deinit {
        murmur_whisper_free(ctx)
    }
}
