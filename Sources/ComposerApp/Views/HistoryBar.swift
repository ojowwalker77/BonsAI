import SwiftUI

/// Compact relative time — "now", "5m", "2h", "3d", then a date.
func relativeDumpTime(_ date: Date) -> String {
  let seconds = Date().timeIntervalSince(date)
  if seconds < 60 { return "now".localizedUI }
  if seconds < 3600 { return "%dm".localizedUI(Int(seconds / 60)) }
  if seconds < 86_400 { return "%dh".localizedUI(Int(seconds / 3600)) }
  let days = Int(seconds / 86_400)
  if days < 7 { return "%dd".localizedUI(days) }
  let formatter = DateFormatter()
  formatter.dateFormat = "MMM d"
  return formatter.string(from: date)
}
