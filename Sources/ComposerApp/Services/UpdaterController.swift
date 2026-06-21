import Sparkle

/// The app's auto-updater, wrapping Sparkle's standard controller.
///
/// Sparkle handles the whole flow — a periodic background check (started on launch), download, install,
/// and relaunch — plus the on-demand "Check for Updates…" command. The feed (`SUFeedURL`) and EdDSA
/// public key (`SUPublicEDKey`) are written into the app's Info.plist by `script/build_and_run.sh`;
/// releases are Developer ID-signed + notarized in CI so updates install without Gatekeeper friction.
///
/// Sparkle types are kept internal to this type so the rest of the app needn't import Sparkle — callers
/// use `checkForUpdates()` and the `automaticallyChecksForUpdates` bool.
@MainActor
final class UpdaterController {
  static let shared = UpdaterController()

  private let controller: SPUStandardUpdaterController

  private init() {
    // `startingUpdater: true` immediately starts Sparkle's scheduled (periodic) checks. The cadence
    // and opt-in default come from SUScheduledCheckInterval / SUEnableAutomaticChecks in Info.plist.
    controller = SPUStandardUpdaterController(
      startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
  }

  /// Show Sparkle's update UI now (the manual "Check for Updates…" path).
  func checkForUpdates() { controller.checkForUpdates(nil) }

  /// True when the updater has a valid feed + key and isn't mid-check — useful for gating UI.
  var canCheckForUpdates: Bool { controller.updater.canCheckForUpdates }

  /// Whether Sparkle checks for updates on its own schedule. Backed by user defaults; safe to bind to
  /// a Settings toggle.
  var automaticallyChecksForUpdates: Bool {
    get { controller.updater.automaticallyChecksForUpdates }
    set { controller.updater.automaticallyChecksForUpdates = newValue }
  }
}
