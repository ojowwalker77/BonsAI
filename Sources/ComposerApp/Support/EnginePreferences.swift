import Foundation

enum EnginePreferences {
  static let claudeEnabledKey = "engine.claude.enabled"
  static let codexEnabledKey = "engine.codex.enabled"

  static func isEnabled(_ engine: HeadlessEngine) -> Bool {
    switch engine {
    case .claude:
      UserDefaults.standard.object(forKey: claudeEnabledKey) as? Bool ?? true
    case .codex:
      UserDefaults.standard.object(forKey: codexEnabledKey) as? Bool ?? true
    }
  }
}
