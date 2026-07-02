import AppKit

/// Trackpad haptics for direct-manipulation moments. macOS only renders these while fingers are
/// on the trackpad, so every call is a safe no-op from a mouse.
///
/// Design call (July 2026): haptics fire on HOVER, never on click — a click already has the
/// trackpad's own physical feedback, and stacking a synthetic tick on top reads as a glitch.
enum Haptics {
  /// A light tick — tool picks, rail buttons, small toggles.
  static func tap() {
    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
  }

  /// A firmer knock — switching context (boards, panels).
  static func level() {
    NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .default)
  }

  /// The default thud — creating something new.
  static func generic() {
    NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default)
  }

  /// A whisper tick on hover-enter. This IS the chrome's hover feedback — buttons and menu rows
  /// deliberately paint no hover background (design call, July 2026), the trackpad tick replaces it.
  static func hover() {
    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
  }
}
