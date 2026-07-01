import SwiftUI

/// Compact relative time — "now", "5m", "2h", "3d", then a date.
func relativeDumpTime(_ date: Date) -> String {
  let seconds = Date().timeIntervalSince(date)
  if seconds < 60 { return "now" }
  if seconds < 3600 { return "\(Int(seconds / 60))m" }
  if seconds < 86_400 { return "\(Int(seconds / 3600))h" }
  let days = Int(seconds / 86_400)
  if days < 7 { return "\(days)d" }
  let formatter = DateFormatter()
  formatter.dateFormat = "MMM d"
  return formatter.string(from: date)
}
