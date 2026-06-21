import AppKit
import CoreGraphics

/// Detects press-and-hold of a single modifier key via a session-level event tap.
/// Fires `onPress` when the configured key goes down and `onRelease` when it comes up.
/// Requires Accessibility permission.
final class HotkeyMonitor {
    var onPress: () -> Void = {}
    var onRelease: () -> Void = {}

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isDown = false
    private var keyCode: Int

    init(keyCode: Int) {
        self.keyCode = keyCode
    }

    func updateKeyCode(_ code: Int) {
        keyCode = code
        isDown = false
    }

    @discardableResult
    func start() -> Bool {
        guard eventTap == nil else { return true }

        let mask = (1 << CGEventType.flagsChanged.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon!).takeUnretainedValue()
            monitor.handle(type: type, event: event)
            return Unmanaged.passUnretained(event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            mlog("event tap NOT created (need Input Monitoring or Accessibility)")
            return false
        }

        mlog("event tap created (watching keyCode \(keyCode))")
        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        guard type == .flagsChanged else { return }

        let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
        mdebug("flagsChanged keyCode=\(code) flags=0x\(String(event.flags.rawValue, radix: 16)) (watching \(keyCode))")
        guard code == keyCode else { return }

        let bit = Keymap.cgFlagMask(for: keyCode)
        let pressed = (event.flags.rawValue & bit) != 0

        if pressed && !isDown {
            isDown = true
            mdebug("hotkey DOWN")
            DispatchQueue.main.async { self.onPress() }
        } else if !pressed && isDown {
            isDown = false
            mdebug("hotkey UP")
            DispatchQueue.main.async { self.onRelease() }
        }
    }
}
