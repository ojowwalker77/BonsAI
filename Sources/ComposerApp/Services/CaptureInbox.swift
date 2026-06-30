import Foundation

/// External capture entry points (menu bar, Services menu, URL scheme, loopback API) enqueue text
/// here; the live canvas drains it onto the current board.
@MainActor
final class CaptureInbox: ObservableObject {
  static let shared = CaptureInbox()

  private var pending: [String] = []

  func enqueue(_ text: String) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    pending.append(trimmed)
    NotificationCenter.default.post(name: .composerQuickCapture, object: trimmed)
  }

  /// Returns and clears everything waiting for the active canvas.
  func drainPending() -> [String] {
    defer { pending.removeAll() }
    return pending
  }
}
