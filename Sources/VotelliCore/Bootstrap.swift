import AppKit

/// Keeps the app delegate alive for the process lifetime once `VotelliMain()`
/// hands control to the run loop.
private var retainedDelegate: AppDelegate?

/// Boot Votelli as a menu-bar-only accessory: no Dock icon, no main window.
///
/// A free build calls this directly. A Pro build registers its extensions
/// (engines via `EngineRegistry`, UI hooks via `AppExtensionPoints`) *before*
/// calling this, so they're in place by the time `AppDelegate` reads them in
/// `applicationDidFinishLaunching`.
public func VotelliMain() {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    retainedDelegate = delegate
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
