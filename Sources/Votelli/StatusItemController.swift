import AppKit

enum VotelliState {
    case idle
    case recording
    case transcribing
    /// Speech was captured before the whisper model finished loading; it's
    /// buffered and will transcribe as soon as the model is ready.
    case warmingUp
}

/// Owns the menu bar item, its icon, and its dropdown menu.
final class StatusItemController {
    var onToggleLogin: ((Bool) -> Void)?
    var onQuit: (() -> Void)?
    var onOpenAccessibility: (() -> Void)?
    var onOpenInputMonitoring: (() -> Void)?
    var onOpenPreferences: (() -> Void)?

    private let statusItem: NSStatusItem
    private let stateItem = NSMenuItem(title: "Ready", action: nil, keyEquivalent: "")
    private let hintItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Start at Login", action: nil, keyEquivalent: "")

    init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = Self.icon(for: .idle)
        buildMenu()
        setState(.idle)
    }

    private func buildMenu() {
        let menu = NSMenu()

        stateItem.isEnabled = false
        menu.addItem(stateItem)
        menu.addItem(.separator())

        hintItem.isEnabled = false
        menu.addItem(hintItem)
        menu.addItem(.separator())

        let prefs = NSMenuItem(title: "Preferences…", action: #selector(openPreferences), keyEquivalent: ",")
        prefs.target = self
        menu.addItem(prefs)

        loginItem.target = self
        loginItem.action = #selector(toggleLogin)
        menu.addItem(loginItem)

        let ax = NSMenuItem(title: "Open Accessibility Settings…", action: #selector(openAccessibility), keyEquivalent: "")
        ax.target = self
        menu.addItem(ax)

        let im = NSMenuItem(title: "Open Input Monitoring Settings…", action: #selector(openInputMonitoring), keyEquivalent: "")
        im.target = self
        menu.addItem(im)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Votelli", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    func setLoginChecked(_ on: Bool) {
        loginItem.state = on ? .on : .off
    }

    func setHotkeyName(_ name: String) {
        hintItem.title = "Hold \(name) to talk"
    }

    func setState(_ state: VotelliState) {
        DispatchQueue.main.async {
            self.statusItem.button?.image = Self.icon(for: state)
            switch state {
            case .idle: self.stateItem.title = "Ready"
            case .recording: self.stateItem.title = "Recording…"
            case .transcribing: self.stateItem.title = "Transcribing…"
            case .warmingUp: self.stateItem.title = "Warming up… (will transcribe when ready)"
            }
        }
    }

    @objc private func toggleLogin() {
        let newValue = loginItem.state != .on
        loginItem.state = newValue ? .on : .off
        onToggleLogin?(newValue)
    }

    @objc private func openAccessibility() {
        onOpenAccessibility?()
    }

    @objc private func openInputMonitoring() {
        onOpenInputMonitoring?()
    }

    @objc private func openPreferences() {
        onOpenPreferences?()
    }

    @objc private func quit() {
        onQuit?()
    }

    private static func icon(for state: VotelliState) -> NSImage? {
        switch state {
        case .idle:
            let img = NSImage(systemSymbolName: "mic", accessibilityDescription: "Votelli idle")
            img?.isTemplate = true
            return img
        case .transcribing:
            let img = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Votelli transcribing")
            img?.isTemplate = true
            return img
        case .warmingUp:
            let img = NSImage(systemSymbolName: "hourglass", accessibilityDescription: "Votelli warming up")
            img?.isTemplate = true
            return img
        case .recording:
            let config = NSImage.SymbolConfiguration(paletteColors: [.systemRed])
            let img = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Votelli recording")?
                .withSymbolConfiguration(config)
            img?.isTemplate = false
            return img
        }
    }
}
