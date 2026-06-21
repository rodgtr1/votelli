import AppKit

/// Modifier keys Votelli can use as push-to-talk, with their virtual keycodes,
/// display names, and device-dependent CGEvent flag bits.
enum Keymap {
    struct Mod {
        let keyCode: Int
        let name: String
        let cgFlagMask: UInt64                 // general CGEventFlags bit for the family
        let generalFlag: NSEvent.ModifierFlags // NSEvent equivalent (for capture UI)
    }

    // CGEventFlags family masks (kCGEventFlagMask*). The keyCode already tells us
    // which physical key changed, so the family mask is enough to know up vs down.
    private static let optionMask: UInt64  = 0x80000
    private static let commandMask: UInt64 = 0x100000
    private static let controlMask: UInt64 = 0x40000
    private static let shiftMask: UInt64   = 0x20000
    private static let fnMask: UInt64      = 0x800000

    static let modifiers: [Mod] = [
        Mod(keyCode: 61, name: "Right Option (⌥)",  cgFlagMask: optionMask,  generalFlag: .option),
        Mod(keyCode: 58, name: "Left Option (⌥)",   cgFlagMask: optionMask,  generalFlag: .option),
        Mod(keyCode: 54, name: "Right Command (⌘)", cgFlagMask: commandMask, generalFlag: .command),
        Mod(keyCode: 55, name: "Left Command (⌘)",  cgFlagMask: commandMask, generalFlag: .command),
        Mod(keyCode: 62, name: "Right Control (⌃)", cgFlagMask: controlMask, generalFlag: .control),
        Mod(keyCode: 59, name: "Left Control (⌃)",  cgFlagMask: controlMask, generalFlag: .control),
        Mod(keyCode: 60, name: "Right Shift (⇧)",   cgFlagMask: shiftMask,   generalFlag: .shift),
        Mod(keyCode: 56, name: "Left Shift (⇧)",    cgFlagMask: shiftMask,   generalFlag: .shift),
        Mod(keyCode: 63, name: "Fn (Globe)",        cgFlagMask: fnMask,      generalFlag: .function)
    ]

    static func mod(for keyCode: Int) -> Mod? {
        modifiers.first { $0.keyCode == keyCode }
    }

    static func name(for keyCode: Int) -> String {
        mod(for: keyCode)?.name ?? "Key \(keyCode)"
    }

    static func cgFlagMask(for keyCode: Int) -> UInt64 {
        mod(for: keyCode)?.cgFlagMask ?? 0
    }
}
