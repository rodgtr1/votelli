import AVFoundation

/// Captures microphone audio and resamples it to the 16kHz mono float format
/// whisper expects. Accumulates samples while recording; `stop()` returns them.
final class AudioRecorder {
    /// Called on the main thread with a normalized 0...1 loudness level per buffer.
    var onLevel: ((Float) -> Void)?

    private let engine = AVAudioEngine()
    private let targetFormat: AVAudioFormat
    private var converter: AVAudioConverter?
    private var samples: [Float] = []
    private let lock = NSLock()
    private(set) var isRecording = false

    init() {
        targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        )!
    }

    func start() {
        guard !isRecording else { return }
        lock.lock(); samples.removeAll(keepingCapacity: true); lock.unlock()

        let input = engine.inputNode
        let inputFormat = input.inputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else {
            NSLog("Murmur: no input format available (mic permission?)")
            return
        }
        converter = AVAudioConverter(from: inputFormat, to: targetFormat)

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.append(buffer)
        }

        do {
            engine.prepare()
            try engine.start()
            isRecording = true
        } catch {
            NSLog("Murmur: audio engine failed to start: \(error)")
            input.removeTap(onBus: 0)
        }
    }

    func stop() -> [Float] {
        guard isRecording else { return [] }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
        lock.lock(); let result = samples; lock.unlock()
        return result
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

        lock.lock()
        samples.append(contentsOf: frame)
        lock.unlock()

        if let onLevel = onLevel {
            let level = Self.loudness(of: frame)
            DispatchQueue.main.async { onLevel(level) }
        }
    }

    /// Controls how strongly mic loudness drives the waveform height.
    private static let levelGain: Float = 9

    /// RMS mapped to a perceptual 0...1 range for the waveform display.
    private static func loudness(of frame: UnsafeBufferPointer<Float>) -> Float {
        guard !frame.isEmpty else { return 0 }
        var sum: Float = 0
        for s in frame { sum += s * s }
        let rms = (sum / Float(frame.count)).squareRoot()
        // Voice RMS is small; boost and soft-clip to 0...1.
        let scaled = (rms * levelGain).squareRoot()
        return min(max(scaled, 0), 1)
    }
}
