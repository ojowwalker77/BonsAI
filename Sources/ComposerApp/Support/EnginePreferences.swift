import Foundation

enum EnginePreferences {
  static let claudeEnabledKey = "engine.claude.enabled"

  static func isEnabled(_ engine: HeadlessEngine) -> Bool {
    switch engine {
    case .claude:
      UserDefaults.standard.object(forKey: claudeEnabledKey) as? Bool ?? true
    }
  }
}
