import AppKit
import AVFoundation

/// A small preferences window: pick the push-to-talk key by clicking the button
/// and pressing the key you want, toggle behavior options, and see/grant the
/// three permissions Votelli needs.
final class PreferencesWindowController: NSObject, NSWindowDelegate {
    var onHotkeyChanged: ((Int) -> Void)?
    var onToggleLogin: ((Bool) -> Void)?

    private var window: NSWindow!
    private let inputDevicePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    /// Parallel to the popup's items: the device UID for each item (nil = system default).
    private var inputDeviceUIDs: [String?] = []
    private let captureButton = NSButton(title: "", target: nil, action: nil)
    private let trailingSpaceCheckbox = NSButton(checkboxWithTitle: "Add a space after each dictation", target: nil, action: nil)
    private let loginCheckbox = NSButton(checkboxWithTitle: "Start at login", target: nil, action: nil)
    private let micStatus = NSTextField(labelWithString: "")
    private let inputStatus = NSTextField(labelWithString: "")
    private let axStatus = NSTextField(labelWithString: "")
    private var monitor: Any?
    private var capturing = false

    override init() {
        super.init()
        buildWindow()
    }

    func show() {
        refresh()
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    private func buildWindow() {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 480))

        let inputTitle = label("Microphone input", size: 13, bold: true, frame: NSRect(x: 24, y: 444, width: 352, height: 22))
        content.addSubview(inputTitle)

        inputDevicePopup.frame = NSRect(x: 22, y: 414, width: 356, height: 26)
        inputDevicePopup.target = self
        inputDevicePopup.action = #selector(selectInputDevice)
        content.addSubview(inputDevicePopup)

        let inputHint = label("Votelli always records from this device, even if macOS changes the system default.",
                              size: 11, bold: false, frame: NSRect(x: 24, y: 392, width: 356, height: 18))
        inputHint.textColor = .secondaryLabelColor
        content.addSubview(inputHint)

        let title = label("Push-to-talk key", size: 13, bold: true, frame: NSRect(x: 24, y: 360, width: 352, height: 22))
        content.addSubview(title)

        captureButton.frame = NSRect(x: 24, y: 322, width: 352, height: 32)
        captureButton.bezelStyle = .rounded
        captureButton.target = self
        captureButton.action = #selector(beginCapture)
        content.addSubview(captureButton)

        let hint = label("Click the button, then press the modifier key you want to hold.",
                         size: 11, bold: false, frame: NSRect(x: 24, y: 298, width: 352, height: 18))
        hint.textColor = .secondaryLabelColor
        content.addSubview(hint)

        trailingSpaceCheckbox.frame = NSRect(x: 22, y: 264, width: 352, height: 22)
        trailingSpaceCheckbox.target = self
        trailingSpaceCheckbox.action = #selector(toggleTrailingSpace)
        content.addSubview(trailingSpaceCheckbox)

        loginCheckbox.frame = NSRect(x: 22, y: 238, width: 352, height: 22)
        loginCheckbox.target = self
        loginCheckbox.action = #selector(toggleLogin)
        content.addSubview(loginCheckbox)

        let permTitle = label("Permissions", size: 13, bold: true, frame: NSRect(x: 24, y: 196, width: 352, height: 22))
        content.addSubview(permTitle)

        addPermissionRow(in: content, y: 160, name: "Microphone", status: micStatus,
                         action: #selector(openMic))
        addPermissionRow(in: content, y: 124, name: "Input Monitoring", status: inputStatus,
                         action: #selector(openInput))
        addPermissionRow(in: content, y: 88, name: "Accessibility", status: axStatus,
                         action: #selector(openAccessibility))

        let footer = label("Microphone to hear you · Input Monitoring for the key · Accessibility to type.",
                           size: 11, bold: false, frame: NSRect(x: 24, y: 52, width: 352, height: 18))
        footer.textColor = .secondaryLabelColor
        content.addSubview(footer)

        window = NSWindow(
            contentRect: content.frame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Votelli Preferences"
        window.contentView = content
        window.isReleasedWhenClosed = false
        window.delegate = self
    }

    private func addPermissionRow(in parent: NSView, y: CGFloat, name: String, status: NSTextField, action: Selector) {
        let nameLabel = label(name, size: 12, bold: false, frame: NSRect(x: 24, y: y, width: 150, height: 20))
        parent.addSubview(nameLabel)

        status.frame = NSRect(x: 180, y: y, width: 120, height: 20)
        status.font = .systemFont(ofSize: 12)
        parent.addSubview(status)

        let button = NSButton(title: "Open…", target: self, action: action)
        button.bezelStyle = .rounded
        button.frame = NSRect(x: 300, y: y - 4, width: 76, height: 28)
        parent.addSubview(button)
    }

    private func refresh() {
        refreshInputDevices()
        captureButton.title = Keymap.name(for: Settings.shared.hotkeyKeyCode)
        trailingSpaceCheckbox.state = Settings.shared.addTrailingSpace ? .on : .off
        loginCheckbox.state = LoginItem.isEnabled ? .on : .off

        let micOK = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        setStatus(micStatus, granted: micOK)
        setStatus(inputStatus, granted: Permissions.inputMonitoringEnabled())
        setStatus(axStatus, granted: Permissions.accessibilityEnabled(prompt: false))
    }

    private func setStatus(_ field: NSTextField, granted: Bool) {
        field.stringValue = granted ? "✅ Granted" : "❌ Not granted"
        field.textColor = granted ? .systemGreen : .secondaryLabelColor
    }

    @objc private func beginCapture() {
        guard !capturing else { return }
        capturing = true
        captureButton.title = "Press a modifier key…"
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            guard let self = self else { return event }
            if event.type == .keyDown {
                self.captureButton.title = "Use a modifier: ⌥ ⌘ ⌃ ⇧ or Fn"
                return nil
            }
            if self.handle(event) { return nil }
            return event
        }
    }

    private func handle(_ event: NSEvent) -> Bool {
        let code = Int(event.keyCode)
        guard let mod = Keymap.mod(for: code) else { return false }
        let pressed = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .contains(mod.generalFlag)
        guard pressed else { return false }

        endCapture()
        Settings.shared.hotkeyKeyCode = code
        captureButton.title = mod.name
        onHotkeyChanged?(code)
        return true
    }

    private func endCapture() {
        capturing = false
        if let monitor = monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    /// Populate the device popup with "System Default" + each connected input
    /// device, selecting the saved one. If the saved device is disconnected, it's
    /// still shown (marked) so the choice is preserved.
    private func refreshInputDevices() {
        inputDevicePopup.removeAllItems()
        inputDeviceUIDs = [nil]
        inputDevicePopup.addItem(withTitle: "System Default")

        let saved = Settings.shared.inputDeviceUID

        for device in AudioDevices.inputDevices() {
            inputDevicePopup.addItem(withTitle: device.name)
            inputDeviceUIDs.append(device.uid)
        }

        if let saved = saved, let index = inputDeviceUIDs.firstIndex(of: saved) {
            inputDevicePopup.selectItem(at: index)
        } else if let saved = saved {
            // Saved device isn't currently connected — keep the choice visible.
            inputDevicePopup.addItem(withTitle: "Selected device (disconnected)")
            inputDeviceUIDs.append(saved)
            inputDevicePopup.selectItem(at: inputDevicePopup.numberOfItems - 1)
        } else {
            inputDevicePopup.selectItem(at: 0)
        }
    }

    @objc private func selectInputDevice() {
        let index = inputDevicePopup.indexOfSelectedItem
        guard index >= 0, index < inputDeviceUIDs.count else { return }
        Settings.shared.inputDeviceUID = inputDeviceUIDs[index]
    }

    @objc private func toggleTrailingSpace() {
        Settings.shared.addTrailingSpace = trailingSpaceCheckbox.state == .on
    }

    @objc private func toggleLogin() {
        onToggleLogin?(loginCheckbox.state == .on)
    }

    @objc private func openMic() { Permissions.openMicrophoneSettings() }
    @objc private func openInput() { Permissions.openInputMonitoringSettings() }
    @objc private func openAccessibility() { Permissions.openAccessibilitySettings() }

    func windowDidBecomeKey(_ notification: Notification) {
        refresh()  // reflect any permission changes made in System Settings
    }

    func windowWillClose(_ notification: Notification) {
        if capturing {
            endCapture()
            refresh()
        }
    }

    private func label(_ text: String, size: CGFloat, bold: Bool, frame: NSRect) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.frame = frame
        field.font = bold ? .systemFont(ofSize: size, weight: .semibold) : .systemFont(ofSize: size)
        return field
    }
}
