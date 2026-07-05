import Combine
import Sparkle

/// The app's auto-updater, wrapping Sparkle's standard controller.
///
/// Sparkle handles the whole flow — a periodic background check (started on launch), download, install,
/// and relaunch — plus the on-demand "Check for Updates…" command. The feed (`SUFeedURL`) and EdDSA
/// public key (`SUPublicEDKey`) are written into the app's Info.plist by `script/build_and_run.sh`;
/// releases are Developer ID-signed + notarized in CI so updates install without Gatekeeper friction.
///
/// Scheduled checks use Sparkle's "gentle reminders": instead of a surprise modal, a found update
/// publishes `availableUpdateVersion`, which the chrome (top-right Update pill, Settings ▸ About)
/// observes. Clicking through calls `checkForUpdates()`, which brings up Sparkle's full UI in
/// user-initiated mode. Manual checks are unaffected and always show Sparkle's UI directly.
///
/// Sparkle types are kept internal to this type so the rest of the app needn't import Sparkle — callers
/// use `checkForUpdates()`, the two `automatically…` bools, and observe `availableUpdateVersion`.
@MainActor
final class UpdaterController: NSObject, ObservableObject {
  static let shared = UpdaterController()

  /// The display version of an update found by a scheduled check, while it awaits the user — nil when
  /// the app is current or the update session ended. Drives the update pill and the Settings badge.
  @Published private(set) var availableUpdateVersion: String?

  private var controller: SPUStandardUpdaterController!

  private override init() {
    super.init()
    // `startingUpdater: true` immediately starts Sparkle's scheduled (periodic) checks. The cadence
    // and opt-in defaults come from SUScheduledCheckInterval / SUEnableAutomaticChecks /
    // SUAutomaticallyUpdate in Info.plist.
    controller = SPUStandardUpdaterController(
      startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)

    // Debug escape: seed a fake pending update to review the reminder chrome without shipping a
    // release — `defaults write dev.jow.BonsAI BonsaiFakeUpdateVersion 9.9.9`, delete to clear.
    // Display-only: the pill/Settings click-through still runs a real check, which will report
    // the app as current.
    if let fake = UserDefaults.standard.string(forKey: "BonsaiFakeUpdateVersion"), !fake.isEmpty {
      availableUpdateVersion = fake
    }
  }

  /// Show Sparkle's update UI now (the manual "Check for Updates…" path, and the click-through
  /// target for the gentle-reminder pill).
  func checkForUpdates() { controller.checkForUpdates(nil) }

  /// True when the updater has a valid feed + key and isn't mid-check — useful for gating UI.
  var canCheckForUpdates: Bool { controller.updater.canCheckForUpdates }

  /// Whether Sparkle checks for updates on its own schedule. Backed by user defaults; safe to bind to
  /// a Settings toggle.
  var automaticallyChecksForUpdates: Bool {
    get { controller.updater.automaticallyChecksForUpdates }
    set {
      objectWillChange.send()
      controller.updater.automaticallyChecksForUpdates = newValue
    }
  }

  /// Whether Sparkle downloads and installs updates on its own once a scheduled check finds one
  /// (the install completes on quit/relaunch). Backed by user defaults; safe to bind to a
  /// Settings toggle.
  var automaticallyDownloadsUpdates: Bool {
    get { controller.updater.automaticallyDownloadsUpdates }
    set {
      objectWillChange.send()
      controller.updater.automaticallyDownloadsUpdates = newValue
    }
  }
}

// MARK: - Gentle scheduled-update reminders

/// Sparkle calls the standard user driver delegate on the main thread; each hook re-asserts that
/// with `MainActor.assumeIsolated` and just moves the update's version in/out of the published state.
extension UpdaterController: SPUStandardUserDriverDelegate {
  nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

  /// Scheduled checks never pop Sparkle's modal on their own — the delegate surfaces the update
  /// through the chrome instead. (User-initiated checks bypass this and always show the UI.)
  nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
    _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
  ) -> Bool {
    false
  }

  nonisolated func standardUserDriverWillHandleShowingUpdate(
    _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
  ) {
    let version = update.displayVersionString
    MainActor.assumeIsolated {
      if !state.userInitiated { availableUpdateVersion = version }
    }
  }

  /// The user opened Sparkle's update alert (or acted on it) — the reminder did its job.
  nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
    MainActor.assumeIsolated { availableUpdateVersion = nil }
  }

  /// Update session over (installed, dismissed, skipped, or errored) — nothing left to remind about.
  nonisolated func standardUserDriverWillFinishUpdateSession() {
    MainActor.assumeIsolated { availableUpdateVersion = nil }
  }
}
