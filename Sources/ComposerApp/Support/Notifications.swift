import Foundation

extension Notification.Name {
  static let composerToggleWindow = Notification.Name("composerToggleWindow")
  static let composerDismiss = Notification.Name("composerDismiss")
  static let composerCopy = Notification.Name("composerCopy")
  /// Fires when MentionStyleCache gains a favicon/brand color (e.g. for the Settings Apps list).
  static let composerStyleCacheUpdated = Notification.Name("composerStyleCacheUpdated")
}
