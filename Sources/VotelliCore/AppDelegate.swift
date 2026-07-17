import AppKit
import AVFoundation
import Sparkle
import VotelliText

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var status: StatusItemController!
    private var hotkey: HotkeyMonitor!
    private let recorder = AudioRecorder()
    private let indicator = RecordingIndicator()
    private let preferences = PreferencesWindowController()
    /// Sparkle updater. Held here for the process lifetime because the updater
    /// must outlive any in-progress check and there's exactly one per app — the
    /// same reason the other long-lived collaborators above are stored properties.
    private let updater = UpdaterManager()
    private var engine: TranscriptionEngine?

    /// Id of the engine that is loaded or currently loading, nil if none. Lets the
    /// Apple Speech asset check tell whether a switch is actually a change.
    /// Mutated only on the main thread.
    private var activeEngineID: String?
    private let history = TranscriptionHistory()
    private let workQueue = DispatchQueue(label: "media.travis.votelli.transcribe", qos: .userInitiated)

    /// Mutated only on the main thread.
    private var state: VotelliState = .idle

    /// Clips recorded before the whisper model finished loading. Buffered here and
    /// transcribed once the model is ready, so early dictation isn't dropped.
    /// Mutated only on the main thread.
    private var pendingClips: [[Float]] = []

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
        // Hand the "Check for Updates…" item straight to Sparkle's controller.
        // Targeting the controller's own `checkForUpdates(_:)` action is the
        // wiring Sparkle documents; StatusItemController stays Sparkle-agnostic.
        status.wireCheckForUpdates(
            target: updater.controller,
            action: #selector(SPUStandardUpdaterController.checkForUpdates(_:))
        )
        status.onCopyHistoryEntry = { text in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            mlog("history: copied \(text.count) chars to clipboard")
        }
        status.onClearHistory = { [weak self] in
            self?.history.clear()
            self?.refreshRecentMenu()
        }

        // Load persisted history (if the user opted in) and reflect it in the menu.
        history.load { [weak self] in self?.refreshRecentMenu() }
        refreshRecentMenu()

        preferences.onHotkeyChanged = { [weak self] code in
            self?.hotkey.updateKeyCode(code)
            self?.status.setHotkeyName(Keymap.name(for: code))
        }
        preferences.onToggleLogin = { [weak self] on in
            LoginItem.setEnabled(on)
            self?.status.setLoginChecked(LoginItem.isEnabled)
        }
        preferences.onToggleSaveHistory = { [weak self] on in
            self?.history.setPersistenceEnabled(on)
        }

        recorder.onLevel = { [weak self] level in self?.indicator.setLevel(level) }
        recorder.onConfigurationChange = { [weak self] resumed in
            self?.handleInputDeviceChange(resumed: resumed)
        }

        // Engines: register the built-in base.en, then let a Pro build's already-
        // registered extras stand. Wire the hooks a Pro build fills in (history
        // window, engine reload). All no-ops in the free build.
        registerBuiltInEngines()
        AppExtensionPoints.shared.reloadEngine = { [weak self] in self?.reloadEngine() }
        AppExtensionPoints.shared.setHistoryPersistenceEnabled = { [weak self] on in
            self?.history.setPersistenceEnabled(on)
        }
        AppExtensionPoints.shared.applyHistoryCapacity = { [weak self] capacity in
            self?.history.applyCapacity(capacity)
        }
        if AppExtensionPoints.shared.openHistoryWindow != nil {
            status.onOpenHistory = { [weak self] in
                guard let self = self else { return }
                AppExtensionPoints.shared.openHistoryWindow?(self.history)
            }
            status.enableHistoryWindowItem()
        }

        Notifier.requestAuthorization()
        prepareAppleSpeechEngine()
        loadModel()

        hotkey = HotkeyMonitor(keyCode: Settings.shared.hotkeyKeyCode)
        hotkey.onPress = { [weak self] in self?.startRecording() }
        hotkey.onRelease = { [weak self] in self?.stopRecording() }

        mlog("launch: mic=\(AVCaptureDevice.authorizationStatus(for: .audio).rawValue) inputMonitoring=\(Permissions.inputMonitoringEnabled()) accessibility=\(Permissions.accessibilityEnabled(prompt: false))")
        requestMissingPermissions()
        startHotkey()

        // First-run onboarding: if any of the three required permissions is still
        // missing, open Preferences so the user sees exactly what's needed with
        // live status and "Open…" buttons. The system permission dialogs are easy
        // to miss (especially Accessibility, which never shows a reliable prompt),
        // so this is the dependable path. It stops appearing once all are granted.
        if !allPermissionsGranted {
            preferences.show()
        }
    }

    /// All three permissions Votelli needs to function end-to-end.
    private var allPermissionsGranted: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
            && Permissions.inputMonitoringEnabled()
            && Permissions.accessibilityEnabled(prompt: false)
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

    /// Register the engines every build ships with: the bundled whisper base.en
    /// model everywhere, plus Apple's SpeechAnalyzer engine on macOS 26+ (whose
    /// model assets the OS downloads and manages — see `AppleSpeechAssets`).
    /// A Pro build registers additional engines before `VotelliMain()`, so by the
    /// time this runs they already coexist.
    private func registerBuiltInEngines() {
        EngineRegistry.shared.register(
            EngineDescriptor(
                id: Settings.defaultEngineID,
                displayName: "Base English (built-in)",
                isAvailable: { Bundle.main.path(forResource: "ggml-base.en", ofType: "bin") != nil },
                makeEngine: {
                    guard let path = Bundle.main.path(forResource: "ggml-base.en", ofType: "bin") else {
                        NSLog("Votelli: bundled model ggml-base.en.bin not found")
                        return nil
                    }
                    // Read the Pro vocabulary prompt (if any) fresh per transcription;
                    // nil in the free build, so decoding is unbiased as before.
                    return Transcriber(
                        modelPath: path, useGPU: true,
                        initialPrompt: { AppExtensionPoints.shared.vocabularyPrompt?() }
                    )
                }
            )
        )
        if #available(macOS 26.0, *) {
            EngineRegistry.shared.register(
                EngineDescriptor(
                    id: Settings.appleSpeechEngineID,
                    displayName: "Apple Speech (built-in)",
                    isAvailable: { Settings.shared.appleSpeechAssetsReady },
                    makeEngine: { AppleSpeechEngine() }
                )
            )
        }
    }

    /// Verify (and if needed download) the Apple Speech model assets in the
    /// background, then switch to that engine if it just became the best choice —
    /// or away from it if its assets turn out to be gone.
    private func prepareAppleSpeechEngine() {
        guard #available(macOS 26.0, *) else { return }
        AppleSpeechAssets.prepare { [weak self] ready in
            guard let self = self else { return }
            if ready {
                // Only auto-switch when the user hasn't picked an engine themselves,
                // and never mid-recording/transcription (the next launch gets it).
                guard !Settings.shared.hasExplicitEngineSelection,
                      self.activeEngineID != Settings.appleSpeechEngineID,
                      self.state == .idle else { return }
                mlog("apple speech: assets ready — switching to the Apple Speech engine")
                self.reloadEngine()
            } else if self.activeEngineID == Settings.appleSpeechEngineID {
                mlog("apple speech: assets no longer available — falling back")
                self.reloadEngine()
            }
        }
    }

    /// Resolve the engine to load. An explicit user selection wins if available.
    /// Absent one, prefer the Apple Speech engine where it's ready (macOS 26+ —
    /// substantially more accurate than the bundled base.en model), then the
    /// default, then anything available (so a Pro user whose selected model isn't
    /// downloaded yet still gets a working engine).
    private func resolveEngineDescriptor() -> EngineDescriptor? {
        let registry = EngineRegistry.shared
        if Settings.shared.hasExplicitEngineSelection {
            if let selected = registry.descriptor(id: Settings.shared.selectedEngineID),
               selected.isAvailable() {
                return selected
            }
            mlog("engine: selected '\(Settings.shared.selectedEngineID)' unavailable — falling back")
        } else if let apple = registry.descriptor(id: Settings.appleSpeechEngineID),
                  apple.isAvailable() {
            return apple
        }
        if let fallback = registry.descriptor(id: Settings.defaultEngineID), fallback.isAvailable() {
            return fallback
        }
        return registry.firstAvailable ?? registry.descriptor(id: Settings.defaultEngineID)
    }

    private func loadModel() {
        guard let descriptor = resolveEngineDescriptor() else {
            NSLog("Votelli: no transcription engine available")
            return
        }
        // The safety net if the resolved engine fails to *load* (resolution only
        // checks availability): the default engine, captured here because the
        // registry is main-thread-only.
        let fallback = descriptor.id == Settings.defaultEngineID
            ? nil : EngineRegistry.shared.descriptor(id: Settings.defaultEngineID)
        mlog("engine: loading '\(descriptor.id)'")
        activeEngineID = descriptor.id
        workQueue.async { [weak self] in
            var e = descriptor.makeEngine()
            var loadedID: String? = descriptor.id
            if e == nil, let fallback = fallback, fallback.isAvailable() {
                mlog("engine: '\(descriptor.id)' failed to load — trying '\(fallback.id)'")
                e = fallback.makeEngine()
                loadedID = fallback.id
            }
            if e == nil {
                NSLog("Votelli: failed to load engine '\(descriptor.id)'")
                loadedID = nil
            }
            // Hand the engine off on the main thread — `engine` and the pending
            // clip buffer are main-thread state — and flush anything captured while
            // it was loading.
            DispatchQueue.main.async {
                self?.engine = e
                self?.activeEngineID = loadedID
                self?.modelDidLoad()
            }
        }
    }

    /// Re-load the transcription engine after the selected engine changed (a Pro
    /// build calls this via `AppExtensionPoints.reloadEngine`). Any in-flight clip
    /// keeps using whatever engine was live when it started.
    private func reloadEngine() {
        engine = nil
        loadModel()
    }

    /// The model finished loading (or failed). Transcribe anything buffered while
    /// it was warming up, unless the user is mid-recording — in that case the clip
    /// will flush when they release the key.
    private func modelDidLoad() {
        guard engine != nil else {
            // Model failed to load: we can't turn the buffered audio into text.
            if !pendingClips.isEmpty {
                pendingClips.removeAll()
                finishToIdle()
                Notifier.notify(
                    title: "Votelli couldn't start",
                    body: "The speech model failed to load, so buffered dictation couldn't be transcribed."
                )
            }
            return
        }
        guard state != .recording else { return }
        flushPending()
    }

    private func startRecording() {
        // Allow starting from idle, or while warming up (so speech during model
        // load keeps buffering instead of being refused).
        guard state == .idle || state == .warmingUp else { return }
        // Only show the recording UI if the engine actually starts capturing,
        // so we never display a red mic with no audio behind it.
        guard recorder.start() else {
            mlog("recording did not start (no microphone or permission?)")
            if AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
                preferences.show()
            }
            return
        }
        state = .recording
        status.setState(.recording)
        indicator.show()

        // Audio is flowing, so a Pro build can start warming whatever it needs by the
        // time the transcript lands (the on-device cleanup model). No-op in the free build.
        AppExtensionPoints.shared.recordingDidStart?()
    }

    private func stopRecording() {
        guard state == .recording else { return }
        let samples = recorder.stop()
        indicator.hide()

        // Ignore clips shorter than ~0.1s (accidental taps).
        guard samples.count > 1_600 else {
            mdebug("clip too short (\(samples.count) samples)")
            finishToIdle()
            return
        }

        // Silence gate: whisper hallucinates phrases like "Thank you." on
        // near-silent audio, so drop clips that never got loud enough to be speech.
        guard !recorder.lastClipWasSilent else {
            mlog("clip below loudness threshold (peakRMS \(recorder.peakRMS)); skipping as silence")
            finishToIdle()
            return
        }

        pendingClips.append(samples)
        flushPending()
    }

    /// Transcribe every buffered clip if the model is ready; otherwise show the
    /// warming-up state and keep them buffered until `modelDidLoad()`.
    private func flushPending() {
        guard let engine = engine else {
            mlog("model still loading — buffered \(pendingClips.count) clip(s), will transcribe when ready")
            state = .warmingUp
            status.setState(.warmingUp)
            return
        }
        let clips = pendingClips
        pendingClips.removeAll()
        guard !clips.isEmpty else { finishToIdle(); return }

        state = .transcribing
        status.setState(.transcribing)
        workQueue.async { [weak self] in
            guard let self = self else { return }
            defer { DispatchQueue.main.async { self.finishToIdle() } }
            for samples in clips {
                guard let text = engine.transcribe(samples) else { mlog("transcribe returned nil"); continue }
                var cleaned = TextProcessing.clean(text)
                // Pro transcript transform (user replacement rules today, AI cleanup
                // in Phase 4). Identity in the free build. Runs here so both history
                // and delivery see the transformed text.
                if let transform = AppExtensionPoints.shared.transformTranscript {
                    cleaned = transform(cleaned)
                }
                mlog("transcribed \(cleaned.count) chars from \(samples.count) samples")
                mdebug("text: \"\(cleaned)\"")
                guard !cleaned.isEmpty else { continue }
                if Settings.shared.addTrailingSpace { cleaned += " " }
                DispatchQueue.main.async { self.deliver(cleaned) }
            }
        }
    }

    /// Type the transcript into the focused app. If typing is blocked (no
    /// Accessibility, or secure input active), copy it to the clipboard and notify
    /// the user so the words are never lost.
    private func deliver(_ text: String) {
        // Record every transcript here — the single point every delivery passes
        // through — so history is the final backstop even when typing falls back
        // to the clipboard below.
        history.record(text, date: Date())
        refreshRecentMenu()

        mlog("typing \(text.count) chars")
        if TextInjector.type(text) { return }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        mlog("typing blocked; copied \(text.count) chars to clipboard")
        Notifier.notify(
            title: "Votelli couldn't type here",
            body: "Your dictation was copied to the clipboard — press ⌘V to paste it."
        )
    }

    /// Show the five most recent transcriptions in the status menu's Recent submenu.
    private func refreshRecentMenu() {
        status.setRecentTranscriptions(history.recent(5))
    }

    private func finishToIdle() {
        state = .idle
        status.setState(.idle)
    }

    /// The input device changed mid-recording. AudioRecorder already rebuilt the
    /// tap on the new device (or ended the clip if it couldn't); just tell the user.
    private func handleInputDeviceChange(resumed: Bool) {
        if resumed {
            Notifier.notify(
                title: "Microphone changed",
                body: "Votelli switched to the new input device and kept recording."
            )
        } else {
            Notifier.notify(
                title: "Recording interrupted",
                body: "The microphone changed and Votelli couldn't resume — please try again."
            )
        }
    }
}
