import AppKit

/// Trackpad haptics for direct-manipulation moments. macOS only renders these while fingers are
/// on the trackpad, so every call is a safe no-op from a mouse.
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
}
