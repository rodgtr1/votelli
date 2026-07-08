import Foundation
import CWhisper

/// Wraps the whisper.cpp model. Loading is expensive; do it once off the main thread.
///
/// Public so a downstream Pro build can load a different whisper model (e.g.
/// large-v3-turbo) through the exact same code path — see `TranscriptionEngine`.
public final class Transcriber: TranscriptionEngine {
    private let ctx: OpaquePointer
    private let threads: Int32

    /// Optional provider of a whisper `initial_prompt` to bias decoding toward
    /// domain vocabulary (names, jargon). Evaluated fresh on every `transcribe`
    /// call, so the biasing can change between dictations without reloading the
    /// model. Returns nil/"" for the default, unbiased behavior.
    ///
    /// It's a closure rather than a stored string so a Pro build can wire it to a
    /// live vocabulary store (via `AppExtensionPoints.vocabularyPrompt`) and have
    /// edits take effect immediately. Called on the transcription queue — any
    /// implementation must be safe to read off the main thread.
    public var initialPrompt: (() -> String?)?

    public init?(modelPath: String, useGPU: Bool = true, initialPrompt: (() -> String?)? = nil) {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        threads = Int32(min(max(cores - 2, 2), 8))
        guard let ctx = votelli_whisper_init(modelPath, useGPU ? 1 : 0) else { return nil }
        self.ctx = ctx
        self.initialPrompt = initialPrompt
    }

    /// Transcribe 16kHz mono samples. Returns nil on failure or empty input.
    public func transcribe(_ samples: [Float]) -> String? {
        guard !samples.isEmpty else { return nil }
        let prompt = initialPrompt?()
        let raw = samples.withUnsafeBufferPointer { buf -> UnsafeMutablePointer<CChar>? in
            // `withCString` keeps the prompt alive only within its closure, which is
            // exactly whisper's requirement (it reads initial_prompt during the call).
            if let prompt = prompt, !prompt.isEmpty {
                return prompt.withCString { cPrompt in
                    votelli_whisper_transcribe(ctx, buf.baseAddress, Int32(buf.count), threads, cPrompt)
                }
            }
            return votelli_whisper_transcribe(ctx, buf.baseAddress, Int32(buf.count), threads, nil)
        }
        guard let raw = raw else { return nil }
        defer { votelli_whisper_free_string(raw) }
        return String(cString: raw)
    }

    deinit {
        votelli_whisper_free(ctx)
    }
}
