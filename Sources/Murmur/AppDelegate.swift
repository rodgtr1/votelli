import AppKit
import AVFoundation
import MurmurText

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var status: StatusItemController!
    private var hotkey: HotkeyMonitor!
    private let recorder = AudioRecorder()
    private let indicator = RecordingIndicator()
    private let preferences = PreferencesWindowController()
    private var transcriber: Transcriber?
    private let workQueue = DispatchQueue(label: "media.travis.murmur.transcribe", qos: .userInitiated)

    /// Mutated only on the main thread.
    private var state: MurmurState = .idle

    func applicationDidFinishLaunching(_ notification: Notification) {
        status = StatusItemController()
        status.setLoginChecked(LoginItem.isEnabled)
        status.setHotkeyName(Keymap.name(for: Settings.shared.hotkeyKeyCode))
        status.onToggleLogin = { [weak self] on in
            LoginItem.setEnabled(on)
            self?.status.setLoginChecked(LoginItem.isEnabled)
        }
        status.onQuit = { NSApp.terminate(nil) }
        status.onOpenAccessibility = { Permissions.openAccessibilitySettings() }
        status.onOpenInputMonitoring = { Permissions.openInputMonitoringSettings() }
        status.onOpenPreferences = { [weak self] in self?.preferences.show() }

        preferences.onHotkeyChanged = { [weak self] code in
            self?.hotkey.updateKeyCode(code)
            self?.status.setHotkeyName(Keymap.name(for: code))
        }
        preferences.onToggleLogin = { [weak self] on in
            LoginItem.setEnabled(on)
            self?.status.setLoginChecked(LoginItem.isEnabled)
        }

        recorder.onLevel = { [weak self] level in self?.indicator.setLevel(level) }

        loadModel()

        hotkey = HotkeyMonitor(keyCode: Settings.shared.hotkeyKeyCode)
        hotkey.onPress = { [weak self] in self?.startRecording() }
        hotkey.onRelease = { [weak self] in self?.stopRecording() }

        mlog("launch: mic=\(AVCaptureDevice.authorizationStatus(for: .audio).rawValue) inputMonitoring=\(Permissions.inputMonitoringEnabled()) accessibility=\(Permissions.accessibilityEnabled(prompt: false))")
        requestMissingPermissions()
        startHotkey()
    }

    /// Only prompt for permissions that aren't already granted.
    private func requestMissingPermissions() {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            Permissions.requestMicrophone { _ in }
        }
        if !Permissions.inputMonitoringEnabled() {
            Permissions.requestInputMonitoring()       // key tap
        }
        // Show the Accessibility system dialog only once, to avoid nagging on every
        // launch. After that, the menu's "Open Accessibility Settings…" is the path.
        if !Permissions.accessibilityEnabled(prompt: false) {
            if !Settings.shared.didPromptAccessibility {
                Settings.shared.didPromptAccessibility = true
                _ = Permissions.accessibilityEnabled(prompt: true)
            }
            pollAccessibility()
        }
    }

    /// Log when Accessibility flips on so we can confirm typing will work.
    private func pollAccessibility() {
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { timer in
            if Permissions.accessibilityEnabled(prompt: false) {
                mlog("accessibility granted — typing enabled")
                timer.invalidate()
            }
        }
    }

    /// Start the listening tap as soon as it can be created. tapCreate succeeds once
    /// Input Monitoring (or Accessibility) is granted; retry until then.
    private func startHotkey() {
        if hotkey.start() { return }
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            if self.hotkey.start() { timer.invalidate() }
        }
    }

    private func loadModel() {
        guard let path = Bundle.main.path(forResource: "ggml-base.en", ofType: "bin") else {
            NSLog("Murmur: bundled model ggml-base.en.bin not found")
            return
        }
        workQueue.async { [weak self] in
            let t = Transcriber(modelPath: path, useGPU: true)
            if t == nil { NSLog("Murmur: failed to load whisper model") }
            self?.transcriber = t
        }
    }

    private func startRecording() {
        guard state == .idle else { return }
        state = .recording
        status.setState(.recording)
        indicator.show()
        recorder.start()
    }

    private func stopRecording() {
        guard state == .recording else { return }
        let samples = recorder.stop()
        indicator.hide()
        state = .transcribing
        status.setState(.transcribing)

        workQueue.async { [weak self] in
            guard let self = self else { return }
            defer {
                DispatchQueue.main.async {
                    self.state = .idle
                    self.status.setState(.idle)
                }
            }

            // Ignore clips shorter than ~0.1s (accidental taps).
            guard samples.count > 1_600 else { mdebug("clip too short (\(samples.count) samples)"); return }
            guard let text = self.transcriber?.transcribe(samples) else { mlog("transcribe returned nil"); return }
            var cleaned = TextProcessing.clean(text)
            mlog("transcribed \(cleaned.count) chars from \(samples.count) samples")
            mdebug("text: \"\(cleaned)\"")
            guard !cleaned.isEmpty else { return }
            if Settings.shared.addTrailingSpace { cleaned += " " }

            DispatchQueue.main.async {
                let trusted = Permissions.accessibilityEnabled(prompt: false)
                mlog("typing \(cleaned.count) chars (accessibility=\(trusted))")
                TextInjector.type(cleaned)
            }
        }
    }
}
