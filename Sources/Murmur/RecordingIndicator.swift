import AppKit

/// A small floating HUD shown while recording: a rolling waveform driven by the
/// live microphone level. Click-through and visible over all spaces/fullscreen.
final class RecordingIndicator {
    private let panel: NSPanel
    private let waveform: WaveformView
    private var timer: Timer?
    private var currentLevel: CGFloat = 0

    private static let size = NSSize(width: 220, height: 64)

    init() {
        let frame = NSRect(origin: .zero, size: Self.size)
        panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false

        let background = NSVisualEffectView(frame: frame)
        background.material = .hudWindow
        background.state = .active
        background.blendingMode = .behindWindow
        background.wantsLayer = true
        background.layer?.cornerRadius = 16
        background.layer?.masksToBounds = true

        waveform = WaveformView(frame: frame.insetBy(dx: 16, dy: 14))
        waveform.autoresizingMask = [.width, .height]
        background.addSubview(waveform)

        panel.contentView = background
    }

    func show() {
        currentLevel = 0
        waveform.reset()
        reposition()
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 1
        }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    func hide() {
        timer?.invalidate()
        timer = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.panel.orderOut(nil)
        })
    }

    /// Called from AudioRecorder.onLevel on the main thread.
    func setLevel(_ level: Float) {
        currentLevel = max(currentLevel, CGFloat(level))
    }

    private func tick() {
        waveform.push(currentLevel)
        // Decay so the waveform settles during silence and stays lively while speaking.
        currentLevel *= 0.82
    }

    private func reposition() {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let x = visible.midX - Self.size.width / 2
        let y = visible.minY + 120
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

/// Draws a rolling row of rounded bars whose heights track recent levels.
private final class WaveformView: NSView {
    private let barCount = 42
    private var levels: [CGFloat]

    override init(frame frameRect: NSRect) {
        levels = Array(repeating: 0, count: barCount)
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        levels = Array(repeating: 0, count: barCount)
        super.init(coder: coder)
    }

    func reset() {
        levels = Array(repeating: 0, count: barCount)
        needsDisplay = true
    }

    func push(_ level: CGFloat) {
        levels.removeFirst()
        levels.append(min(max(level, 0), 1))
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let bounds = self.bounds
        let spacing: CGFloat = 3
        let totalSpacing = spacing * CGFloat(barCount - 1)
        let barWidth = (bounds.width - totalSpacing) / CGFloat(barCount)
        let midY = bounds.midY
        let maxHalf = bounds.height / 2

        NSColor.white.withAlphaComponent(0.95).setFill()

        for (i, level) in levels.enumerated() {
            let half = max(barWidth / 2, level * maxHalf)
            let x = CGFloat(i) * (barWidth + spacing)
            let rect = NSRect(x: x, y: midY - half, width: barWidth, height: half * 2)
            let path = NSBezierPath(roundedRect: rect, xRadius: barWidth / 2, yRadius: barWidth / 2)
            path.fill()
        }
    }
}
