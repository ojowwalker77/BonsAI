import Foundation

enum EnginePreferences {
  static let claudeEnabledKey = "engine.claude.enabled"
  static let codexEnabledKey = "engine.codex.enabled"
  static let opencodeEnabledKey = "engine.opencode.enabled"

  static func enabledKey(for engine: HeadlessEngine) -> String {
    switch engine {
    case .claude: claudeEnabledKey
    case .codex: codexEnabledKey
    case .opencode: opencodeEnabledKey
    }
  }

  static func isEnabled(_ engine: HeadlessEngine) -> Bool {
    UserDefaults.standard.object(forKey: enabledKey(for: engine)) as? Bool ?? true
  }

  /// The provider (engine) each surface runs on, stored as a rawValue string; empty/absent means "no
  /// explicit pick" so the surface falls back to the preference order. One choice per surface — the
  /// Agent dock and Settings both bind these.
  static func engineKey(for surface: ModelSurface) -> String { "engine.\(surface.rawValue).selected" }
  /// Kept for the existing Agent-dock binding; identical to `engineKey(for: .chat)`.
  static let chatEngineKey = "engine.chat.selected"

  static func selectedEngine(for surface: ModelSurface) -> HeadlessEngine? {
    guard let raw = UserDefaults.standard.string(forKey: engineKey(for: surface)), !raw.isEmpty else { return nil }
    return HeadlessEngine(rawValue: raw)
  }
  static func selectedChatEngine() -> HeadlessEngine? { selectedEngine(for: .chat) }

  /// The engine a surface will actually run on: the explicit pick when it's enabled + available, else
  /// the first enabled + available engine in preference order. `isAvailable` is injected so this stays
  /// off the MainActor-bound capability store.
  static func resolvedEngine(for surface: ModelSurface, isAvailable: (HeadlessEngine) -> Bool) -> HeadlessEngine? {
    if let picked = selectedEngine(for: surface), isEnabled(picked), isAvailable(picked) { return picked }
    return HeadlessEngine.allCases.first { isEnabled($0) && isAvailable($0) }
  }
}
