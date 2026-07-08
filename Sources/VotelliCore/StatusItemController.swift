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
    /// Called with the full (untruncated) text of a clicked Recent entry.
    var onCopyHistoryEntry: ((String) -> Void)?
    var onClearHistory: (() -> Void)?
    /// Invoked by the "History…" item, which only exists once
    /// `enableHistoryWindowItem()` has been called (a Pro build's history window).
    var onOpenHistory: (() -> Void)?

    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let stateItem = NSMenuItem(title: "Ready", action: nil, keyEquivalent: "")
    private let hintItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let recentItem = NSMenuItem(title: "Recent", action: nil, keyEquivalent: "")
    private let recentMenu = NSMenu()
    private let clearHistoryItem = NSMenuItem(title: "Clear History", action: nil, keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Start at Login", action: nil, keyEquivalent: "")

    init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = Self.icon(for: .idle)
        buildMenu()
        setState(.idle)
    }

    private func buildMenu() {
        // Manual enabling: Clear History toggles with history state, and auto-enable
        // would override the isEnabled we set on it.
        menu.autoenablesItems = false

        stateItem.isEnabled = false
        menu.addItem(stateItem)
        menu.addItem(.separator())

        hintItem.isEnabled = false
        menu.addItem(hintItem)
        menu.addItem(.separator())

        recentItem.submenu = recentMenu
        menu.addItem(recentItem)
        setRecentTranscriptions([])

        clearHistoryItem.target = self
        clearHistoryItem.action = #selector(clearHistory)
        menu.addItem(clearHistoryItem)
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

    /// Rebuild the Recent submenu from the newest-first entries. Long entries are
    /// truncated for display; clicking one copies its full text to the clipboard.
    func setRecentTranscriptions(_ entries: [HistoryEntry]) {
        DispatchQueue.main.async {
            self.recentMenu.removeAllItems()
            guard !entries.isEmpty else {
                let empty = NSMenuItem(title: "No transcriptions yet", action: nil, keyEquivalent: "")
                empty.isEnabled = false
                self.recentMenu.addItem(empty)
                self.clearHistoryItem.isEnabled = false
                return
            }
            for entry in entries {
                let item = NSMenuItem(title: Self.displayTitle(for: entry.text),
                                      action: #selector(self.copyHistoryEntry(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = entry.text
                item.toolTip = "Click to copy the full text"
                self.recentMenu.addItem(item)
            }
            self.clearHistoryItem.isEnabled = true
        }
    }

    /// Collapse whitespace to a single line and clip to a menu-friendly length.
    private static func displayTitle(for text: String) -> String {
        let collapsed = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
        let limit = 60
        if collapsed.count <= limit { return collapsed }
        return String(collapsed.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// Insert a "History…" item (opening a Pro history window) right after the
    /// Recent submenu. Only called when the history-window extension is present, so
    /// the free menu never shows it. Invokes `onOpenHistory`.
    func enableHistoryWindowItem() {
        guard menu.items.contains(recentItem) else { return }
        let historyItem = NSMenuItem(title: "History…", action: #selector(openHistory), keyEquivalent: "")
        historyItem.target = self
        let index = menu.index(of: recentItem) + 1
        menu.insertItem(historyItem, at: index)
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

    @objc private func copyHistoryEntry(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        onCopyHistoryEntry?(text)
    }

    @objc private func clearHistory() {
        onClearHistory?()
    }

    @objc private func openHistory() {
        onOpenHistory?()
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
