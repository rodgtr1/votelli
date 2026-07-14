import Foundation
import AVFoundation
import Speech

/// Transcribes with Apple's on-device SpeechAnalyzer/SpeechTranscriber (macOS 26+).
///
/// On machines that have it, this engine is preferred over the bundled whisper
/// base.en model when the user hasn't explicitly picked an engine: it's markedly
/// more accurate on English, faster, and its model assets are downloaded and
/// updated by the OS rather than shipped in the app bundle.
///
/// Like `Transcriber`, this is a batch engine: the whole clip goes in at once and
/// one string comes out. `transcribe` bridges the framework's async API onto the
/// caller's queue with a semaphore (the same pattern the Pro AI-cleanup step uses),
/// which is safe because transcription always runs on the app's serial work queue,
/// never the main thread.
@available(macOS 26.0, *)
public final class AppleSpeechEngine: TranscriptionEngine {
    private let locale: Locale

    public init() {
        // The locale was resolved against SpeechTranscriber.supportedLocales during
        // asset preparation (see AppleSpeechAssets.prepare); en-US is the safety net.
        locale = Locale(identifier: Settings.shared.appleSpeechLocaleID ?? "en-US")
    }

    /// Transcribe 16kHz mono samples. Returns nil on failure or empty input.
    public func transcribe(_ samples: [Float]) -> String? {
        guard !samples.isEmpty else { return nil }
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox()
        let locale = self.locale
        Task.detached(priority: .userInitiated) {
            do {
                box.value = try await Self.run(samples, locale: locale)
            } catch {
                mlog("apple speech: transcription failed: \(error)")
            }
            semaphore.signal()
        }
        // The analyzer runs many times faster than real time; 2x real time plus a
        // fixed slack is a generous ceiling that still can't wedge the work queue.
        let timeout = DispatchTime.now() + .seconds(30 + samples.count / 8_000)
        guard semaphore.wait(timeout: timeout) == .success else {
            mlog("apple speech: transcription timed out")
            return nil
        }
        let text = box.value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (text?.isEmpty ?? true) ? nil : text
    }

    private static func run(_ samples: [Float], locale: Locale) async throws -> String? {
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        guard let analysisFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            mlog("apple speech: no compatible audio format for \(locale.identifier)")
            return nil
        }
        guard let source = buffer(from: samples),
              let converted = convert(source, to: analysisFormat) else { return nil }

        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        continuation.yield(AnalyzerInput(buffer: converted))
        continuation.finish()

        // Vocabulary biasing: where whisper engines take an initial_prompt string,
        // this engine feeds raw terms to the framework's contextual-strings hook.
        // Read fresh per clip so Pro vocabulary edits apply on the next dictation.
        let context = AnalysisContext()
        if let terms = AppExtensionPoints.shared.vocabularyTerms?(), !terms.isEmpty {
            context.contextualStrings[.general] = terms
        }

        // .lingering keeps the OS model warm between clips without pinning it for
        // the whole process lifetime, so back-to-back dictations stay fast.
        let analyzer = SpeechAnalyzer(
            inputSequence: stream,
            modules: [transcriber],
            options: .init(priority: .userInitiated, modelRetention: .lingering),
            analysisContext: context
        )
        async let text = collectResults(from: transcriber)
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        return try await text
    }

    private static func collectResults(from transcriber: SpeechTranscriber) async throws -> String {
        var text = ""
        for try await result in transcriber.results where result.isFinal {
            text += String(result.text.characters)
        }
        return text
    }

    // MARK: Audio plumbing

    private static let sourceFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
    )!

    private static func buffer(from samples: [Float]) -> AVAudioPCMBuffer? {
        guard let buf = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buf.floatChannelData else { return nil }
        buf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            channel[0].update(from: src.baseAddress!, count: samples.count)
        }
        return buf
    }

    /// Resample/reshape to the analyzer's preferred format. Identity when it
    /// already matches our 16kHz mono float capture format.
    private static func convert(_ source: AVAudioPCMBuffer, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        if source.format == format { return source }
        guard let converter = AVAudioConverter(from: source.format, to: format) else {
            mlog("apple speech: no converter from \(source.format) to \(format)")
            return nil
        }
        let ratio = format.sampleRate / source.format.sampleRate
        let capacity = AVAudioFrameCount(Double(source.frameLength) * ratio) + 4_096
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var provided = false
        var conversionError: NSError?
        let status = converter.convert(to: out, error: &conversionError) { _, inputStatus in
            if provided {
                inputStatus.pointee = .endOfStream
                return nil
            }
            provided = true
            inputStatus.pointee = .haveData
            return source
        }
        guard status != .error else {
            mlog("apple speech: audio conversion failed: \(String(describing: conversionError))")
            return nil
        }
        return out
    }
}

/// Crosses from the detached transcription task back to the waiting queue.
private final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?
    var value: String? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); defer { lock.unlock() }; stored = newValue }
    }
}

/// Model-asset lifecycle for the Apple Speech engine. The framework's checks are
/// all async, but `EngineDescriptor.isAvailable` must answer synchronously at
/// launch — so readiness is cached in Settings and re-verified (and repaired, by
/// downloading missing assets) in the background on every launch.
@available(macOS 26.0, *)
public enum AppleSpeechAssets {
    /// Resolve the locale, download assets if missing, and cache readiness.
    /// `completion` runs on the main thread with the final readiness.
    public static func prepare(_ completion: @escaping (Bool) -> Void) {
        Task.detached(priority: .utility) {
            let ready = await prepareAssets()
            Settings.shared.appleSpeechAssetsReady = ready
            DispatchQueue.main.async { completion(ready) }
        }
    }

    private static func prepareAssets() async -> Bool {
        guard SpeechTranscriber.isAvailable else {
            mlog("apple speech: SpeechTranscriber unavailable on this system")
            return false
        }
        // Dictate in the user's language when the system supports it; the app's
        // historical default (whisper base.en) is English-only, so en-US is the
        // fallback rather than a forced choice.
        var locale = await SpeechTranscriber.supportedLocale(equivalentTo: .current)
        if locale == nil {
            locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US"))
        }
        guard let locale else {
            mlog("apple speech: no supported locale for \(Locale.current.identifier) or en-US")
            return false
        }
        Settings.shared.appleSpeechLocaleID = locale.identifier(.bcp47)

        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        switch await AssetInventory.status(forModules: [transcriber]) {
        case .installed:
            return true
        case .unsupported:
            return false
        case .supported, .downloading:
            do {
                _ = try? await AssetInventory.reserve(locale: locale)
                if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                    mlog("apple speech: downloading model assets for \(locale.identifier)")
                    try await request.downloadAndInstall()
                }
                return await AssetInventory.status(forModules: [transcriber]) == .installed
            } catch {
                mlog("apple speech: asset install failed: \(error)")
                return false
            }
        @unknown default:
            return false
        }
    }
}
