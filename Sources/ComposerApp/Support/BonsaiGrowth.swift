import AppKit
import Combine
import Foundation

/// The bonsai's growth clock: accumulates the app's total open time across launches and maps it
/// onto a 0…1 maturity progress that `BonsaiTreeOverlay` renders in the canvas corner.
///
/// Accrual runs at `ComposerPreferences.bonsaiDevSpeedKey`× (1/2/5, dev-facing) read live each
/// tick, so the Settings dev control takes effect without restarting. Sleep pauses the clock so
/// overnight idle time does not age the tree. Persistence uses
/// `ComposerPreferences.bonsaiGrownSecondsKey`; `flush()` is wired to `applicationWillTerminate`
/// (SIGTERM-safe - dev relaunches still land the partial session).
@MainActor
final class BonsaiGrowth: ObservableObject {
  static let shared = BonsaiGrowth()

  /// Hours of (multiplied) open time at which the tree reaches full maturity.
  static let maturityHours: Double = 80

  /// Total effective grown time in seconds, persisted across launches.
  @Published private(set) var grownSeconds: TimeInterval

  /// 0…1 progress toward maturity. Square-root eased so the first hours are visibly alive.
  var progress: Double {
    min(1, (max(0, grownSeconds) / (Self.maturityHours * 3600)).squareRoot())
  }

  /// Growth speed multiplier (1, 2, or 5). Dev-facing; the UI is #if DEBUG-gated.
  var devSpeedMultiplier: Double {
    get {
      let stored = UserDefaults.standard.double(forKey: ComposerPreferences.bonsaiDevSpeedKey)
      return Self.validatedDevSpeedMultiplier(stored)
    }
    set {
      UserDefaults.standard.set(
        Self.validatedDevSpeedMultiplier(newValue),
        forKey: ComposerPreferences.bonsaiDevSpeedKey
      )
    }
  }

  private static let tickInterval: TimeInterval = 30
  private static let maximumAccrualInterval: TimeInterval = tickInterval * 2
  private static let validDevSpeedMultipliers: Set<Double> = [1.0, 2.0, 5.0]

  private var lastTick: Date?
  private var tickScheduled = false
  private var hasStarted = false
  private var pausedForSleep = false
  private var willSleepObserver: NSObjectProtocol?
  private var didWakeObserver: NSObjectProtocol?

  private init() {
    grownSeconds = Self.sanitizedGrownSeconds(
      UserDefaults.standard.double(forKey: ComposerPreferences.bonsaiGrownSecondsKey)
    )
    observeSleepWake()
  }

  /// Begin accruing open time. Called from `applicationDidFinishLaunching`.
  func start() {
    guard !hasStarted else { return }
    hasStarted = true
    pausedForSleep = false
    lastTick = Date()
    scheduleTick()
  }

  /// Land any un-persisted session time now. Called from `applicationWillTerminate`.
  func flush() {
    accrue()
    persist()
  }

  /// Dev scrub: jump the tree to an absolute age. Persists immediately.
  func setGrownSeconds(_ seconds: TimeInterval) {
    grownSeconds = Self.sanitizedGrownSeconds(seconds)
    if hasStarted, !pausedForSleep {
      lastTick = Date()
    }
    persist()
  }

  /// Dev reset: back to a fresh sprout.
  func resetGrowth() {
    setGrownSeconds(0)
  }

  private func scheduleTick() {
    guard !tickScheduled else { return }
    tickScheduled = true
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.tickInterval) { [weak self] in
      guard let self else { return }
      tickScheduled = false
      accrue()
      persist()
      scheduleTick()
    }
  }

  private func accrue() {
    guard let last = lastTick else { return }
    let now = Date()
    let rawElapsed = now.timeIntervalSince(last)
    let elapsed = rawElapsed.isFinite ? min(max(0, rawElapsed), Self.maximumAccrualInterval) : 0
    grownSeconds = Self.sanitizedGrownSeconds(grownSeconds + elapsed * devSpeedMultiplier)
    lastTick = now
  }

  private func persist() {
    grownSeconds = Self.sanitizedGrownSeconds(grownSeconds)
    UserDefaults.standard.set(grownSeconds, forKey: ComposerPreferences.bonsaiGrownSecondsKey)
  }

  private func observeSleepWake() {
    let notificationCenter = NSWorkspace.shared.notificationCenter
    willSleepObserver = notificationCenter.addObserver(
      forName: NSWorkspace.willSleepNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor in
        self?.pauseForSleep()
      }
    }
    didWakeObserver = notificationCenter.addObserver(
      forName: NSWorkspace.didWakeNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor in
        self?.resumeAfterWake()
      }
    }
  }

  private func pauseForSleep() {
    guard hasStarted, !pausedForSleep else { return }
    accrue()
    persist()
    lastTick = nil
    pausedForSleep = true
  }

  private func resumeAfterWake() {
    guard hasStarted else { return }
    pausedForSleep = false
    lastTick = Date()
    scheduleTick()
  }

  private static func sanitizedGrownSeconds(_ seconds: TimeInterval) -> TimeInterval {
    seconds.isFinite ? max(0, seconds) : 0
  }

  private static func validatedDevSpeedMultiplier(_ multiplier: Double) -> Double {
    validDevSpeedMultipliers.contains(multiplier) ? multiplier : 1.0
  }
}
