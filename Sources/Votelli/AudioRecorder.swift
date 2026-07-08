import AVFoundation
import AudioToolbox
import CoreAudio

/// Captures microphone audio and resamples it to the 16kHz mono float format
/// whisper expects. Accumulates samples while recording; `stop()` returns them.
final class AudioRecorder {
    /// Called on the main thread with a normalized 0...1 loudness level per buffer.
    var onLevel: ((Float) -> Void)?

    /// Called on the main thread when the input device changes mid-recording.
    /// The Bool is true if capture resumed on the new device, false if the engine
    /// couldn't restart and the clip ended early.
    var onConfigurationChange: ((Bool) -> Void)?

    private let engine = AVAudioEngine()
    private let targetFormat: AVAudioFormat
    private var converter: AVAudioConverter?
    private var samples: [Float] = []
    private let lock = NSLock()
    private(set) var isRecording = false
    private var configObserver: NSObjectProtocol?
    /// Guards against re-entrant restarts while we tear down and rebuild the tap.
    private var isReconfiguring = false

    /// Loudest per-buffer RMS seen during the current clip. Read after `stop()`
    /// to decide whether the clip was silence.
    private(set) var peakRMS: Float = 0

    /// Clips whose loudest buffer never exceeds this raw RMS are treated as
    /// silence and skipped — whisper otherwise hallucinates phrases like
    /// "Thank you." on near-silent input. Deliberately low so real (even quiet)
    /// speech is never dropped; raise only if silence still slips through.
    static let silenceRMSThreshold: Float = 0.005

    /// Whether the just-recorded clip was too quiet to be real speech.
    var lastClipWasSilent: Bool { peakRMS < Self.silenceRMSThreshold }

    /// Reserve enough for a minute of 16kHz mono up front so the audio thread
    /// doesn't reallocate `samples` mid-recording (allocation there can glitch).
    private static let reservedSamples = 16_000 * 60

    init() {
        targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        )!
        // The engine stops when the active input device is added/removed. Rather
        // than let the clip truncate silently, rebuild the tap on the new device
        // so recording continues, and tell the user what happened.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            self?.handleConfigurationChange()
        }
    }

    deinit {
        if let configObserver = configObserver {
            NotificationCenter.default.removeObserver(configObserver)
        }
    }

    /// Returns true once the engine is actually capturing. On false the caller
    /// should not show a recording UI — nothing is being captured.
    @discardableResult
    func start() -> Bool {
        guard !isRecording else { return true }
        lock.lock()
        samples.removeAll(keepingCapacity: true)
        samples.reserveCapacity(Self.reservedSamples)
        peakRMS = 0
        lock.unlock()

        guard beginCapture() else { return false }
        isRecording = true
        return true
    }

    /// Install the tap on the current input device and start the engine. Shared by
    /// `start()` and the mid-recording restart. Does not clear accumulated samples,
    /// so a device swap keeps the audio captured so far.
    private func beginCapture() -> Bool {
        let input = engine.inputNode
        applyPreferredDevice(to: input)
        let inputFormat = input.inputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else {
            mlog("no input format available (mic permission or device?)")
            return false
        }
        converter = AVAudioConverter(from: inputFormat, to: targetFormat)

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.append(buffer)
        }

        do {
            engine.prepare()
            try engine.start()
            return true
        } catch {
            mlog("audio engine failed to start: \(error)")
            input.removeTap(onBus: 0)
            return false
        }
    }

    /// The active input device changed while recording. Rebuild the tap on the new
    /// device so the clip continues, keeping the audio captured so far, and report
    /// whether capture resumed.
    private func handleConfigurationChange() {
        guard isRecording, !isReconfiguring else { return }
        isReconfiguring = true
        defer { isReconfiguring = false }

        mlog("audio configuration changed mid-recording (input device added/removed) — restarting engine")
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        let resumed = beginCapture()
        if !resumed {
            mlog("could not resume capture after device change; ending clip")
            isRecording = false
        }
        onConfigurationChange?(resumed)
    }

    func stop() -> [Float] {
        guard isRecording else { return [] }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
        lock.lock(); let result = samples; lock.unlock()
        return result
    }

    /// Pin the engine's input to the user-chosen device so recording doesn't
    /// follow the system default. No-op (uses default) if none is set or the
    /// saved device is disconnected.
    private func applyPreferredDevice(to input: AVAudioInputNode) {
        guard let uid = Settings.shared.inputDeviceUID else { return }
        guard let deviceID = AudioDevices.deviceID(forUID: uid) else {
            mlog("pinned input device not connected (\(uid)); using system default")
            return
        }
        guard let unit = input.audioUnit else { return }
        var dev = deviceID
        let status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &dev,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if status != noErr {
            mlog("failed to pin input device (status \(status)); using system default")
        }
    }

    private func append(_ buffer: AVAudioPCMBuffer) {
        guard let converter = converter else { return }

        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var provided = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            if provided {
                outStatus.pointee = .noDataNow
                return nil
            }
            provided = true
            outStatus.pointee = .haveData
            return buffer
        }

        guard status != .error, let channel = out.floatChannelData else { return }
        let count = Int(out.frameLength)
        guard count > 0 else { return }

        let frame = UnsafeBufferPointer(start: channel[0], count: count)
        let rms = Self.rms(of: frame)

        lock.lock()
        samples.append(contentsOf: frame)
        if rms > peakRMS { peakRMS = rms }
        lock.unlock()

        if let onLevel = onLevel {
            let level = Self.perceptualLevel(fromRMS: rms)
            DispatchQueue.main.async { onLevel(level) }
        }
    }

    /// Controls how strongly mic loudness drives the waveform height.
    private static let levelGain: Float = 9

    /// Raw root-mean-square amplitude of a buffer. Used both for the silence gate
    /// and (mapped) for the waveform display.
    private static func rms(of frame: UnsafeBufferPointer<Float>) -> Float {
        guard !frame.isEmpty else { return 0 }
        var sum: Float = 0
        for s in frame { sum += s * s }
        return (sum / Float(frame.count)).squareRoot()
    }

    /// RMS mapped to a perceptual 0...1 range for the waveform display.
    private static func perceptualLevel(fromRMS rms: Float) -> Float {
        // Voice RMS is small; boost and soft-clip to 0...1.
        let scaled = (rms * levelGain).squareRoot()
        return min(max(scaled, 0), 1)
    }
}
