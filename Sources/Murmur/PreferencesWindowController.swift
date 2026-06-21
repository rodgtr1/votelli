import AppKit

/// A small preferences window: pick the push-to-talk key by clicking the button
/// and pressing the key you want, plus a Start-at-Login toggle.
final class PreferencesWindowController: NSObject, NSWindowDelegate {
    var onHotkeyChanged: ((Int) -> Void)?
    var onToggleLogin: ((Bool) -> Void)?

    private var window: NSWindow!
    private let captureButton = NSButton(title: "", target: nil, action: nil)
    private let loginCheckbox = NSButton(checkboxWithTitle: "Start at login", target: nil, action: nil)
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
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 190))

        let title = label("Push-to-talk key", frame: NSRect(x: 24, y: 142, width: 332, height: 22))
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        content.addSubview(title)

        captureButton.frame = NSRect(x: 24, y: 104, width: 332, height: 32)
        captureButton.bezelStyle = .rounded
        captureButton.target = self
        captureButton.action = #selector(beginCapture)
        content.addSubview(captureButton)

        let hint = label("Click the button, then press the modifier key you want to hold.",
                         frame: NSRect(x: 24, y: 78, width: 332, height: 18))
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        content.addSubview(hint)

        loginCheckbox.frame = NSRect(x: 22, y: 36, width: 332, height: 22)
        loginCheckbox.target = self
        loginCheckbox.action = #selector(toggleLogin)
        content.addSubview(loginCheckbox)

        window = NSWindow(
            contentRect: content.frame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Murmur Preferences"
        window.contentView = content
        window.isReleasedWhenClosed = false
        window.delegate = self
    }

    private func refresh() {
        captureButton.title = Keymap.name(for: Settings.shared.hotkeyKeyCode)
        loginCheckbox.state = LoginItem.isEnabled ? .on : .off
    }

    @objc private func beginCapture() {
        guard !capturing else { return }
        capturing = true
        captureButton.title = "Press a modifier key…"
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            guard let self = self else { return event }
            if event.type == .keyDown {
                // A regular key can't be push-to-talk; nudge and swallow it.
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
        // A press sets the modifier's general flag; ignore the release event.
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

    @objc private func toggleLogin() {
        onToggleLogin?(loginCheckbox.state == .on)
    }

    func windowWillClose(_ notification: Notification) {
        if capturing {
            endCapture()
            refresh()
        }
    }

    private func label(_ text: String, frame: NSRect) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.frame = frame
        return field
    }
}
