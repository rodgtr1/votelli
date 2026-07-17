import AppKit
import Sparkle

/// Owns Sparkle and is the ONLY thing in Votelli that ever makes an
/// update-related network request — and only when the user explicitly clicks
/// "Check for Updates…". This is deliberate: Votelli's whole posture is that
/// nothing leaves your Mac unless you ask for it, and an updater that phones
/// home on a timer would quietly break that promise.
///
/// Pull-only is enforced two ways, belt and suspenders:
///   1. `SUEnableAutomaticChecks = false` in Info.plist. Besides disabling the
///      background scheduler this also suppresses Sparkle's first-run
///      "Check for updates automatically?" prompt, which would otherwise be the
///      user's first impression of the app.
///   2. `updater.automaticallyChecksForUpdates = false` here in code, so even if
///      the Info.plist key were ever dropped the scheduler stays off.
/// With automatic checks off, starting the updater schedules nothing — so
/// `startingUpdater: true` is safe and hands us a fully wired controller whose
/// `checkForUpdates(_:)` action the menu item can target directly.
///
/// Owned by `AppDelegate` for the process lifetime (see there). The updater must
/// outlive any in-progress check, and there's exactly one per app.
final class UpdaterManager: NSObject, SPUUpdaterDelegate {
    /// The appcast feed. Sourced here in code rather than via `SUFeedURL` in
    /// Info.plist so the URL sits next to the pull-only rationale and a
    /// downstream build can override `feedURLString(for:)` without editing the
    /// shared plist. Because we return it from the delegate below, `SUFeedURL` is
    /// intentionally absent from Info.plist. (`SUPublicEDKey` still has to live in
    /// Info.plist — Sparkle reads the update-signing key before any delegate
    /// exists, so there's no runtime API to inject it.)
    private static let feedURL = "https://rodgtr1.github.io/votelli/appcast.xml"

    /// The standard AppKit controller. Exposed so the menu item can target its
    /// `checkForUpdates(_:)` action directly (see StatusItemController wiring) —
    /// the least code that can go wrong. Implicitly unwrapped because
    /// SPUStandardUpdaterController takes its delegate at construction, so it can
    /// only be built after `super.init()` makes `self` available as the delegate.
    private(set) var controller: SPUStandardUpdaterController!

    override init() {
        super.init()
        // userDriverDelegate stays nil: the stock Sparkle UI (a small update
        // window with release notes) is exactly what a menu-bar app wants. We are
        // the updaterDelegate only to supply the feed URL from code.
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
        controller.updater.automaticallyChecksForUpdates = false
    }

    /// Whether a user-initiated check can start right now. Sparkle drives this
    /// (false only briefly, e.g. while a check is already running). Available for
    /// any build that manages the menu item's enabled state itself.
    var canCheckForUpdates: Bool {
        controller.updater.canCheckForUpdates
    }

    /// User-initiated check. The menu item targets the controller's own action
    /// directly, so this is a convenience seam for any programmatic trigger.
    @objc func checkForUpdates(_ sender: Any?) {
        controller.checkForUpdates(sender)
    }

    // MARK: SPUUpdaterDelegate

    /// Supply the appcast feed from code (see `feedURL` above for why here rather
    /// than Info.plist's `SUFeedURL`).
    func feedURLString(for updater: SPUUpdater) -> String? {
        Self.feedURL
    }
}
