import Foundation

/// The AI surface that picks a provider + model: the streaming chat agent. (It's an enum, not a bare
/// constant, so the key-namespacing stays uniform — Describe was a second surface until the toolbar
/// refactor removed it.) Stores its own engine + per-engine model.
enum ModelSurface: String { case chat }

/// The model a surface runs on, **per engine**. Codex and OpenCode store a free provider/model string
/// (empty ⇒ the engine's own default), passed as `-m`. Claude reuses the short `model.chat` key
/// ([[ModelPreferences]]) holding a `ClaudeModel` alias — so this is the single place all of
/// chat × claude/codex/opencode model choices live.
enum EngineModelPreferences {
  /// `model.chat` for Claude (a `ClaudeModel` alias); `model.<surface>.<engine>` for the others.
  static func modelKey(_ surface: ModelSurface, _ engine: HeadlessEngine) -> String {
    engine == .claude ? "model.\(surface.rawValue)" : "model.\(surface.rawValue).\(engine.rawValue)"
  }

  static func selectedModel(_ surface: ModelSurface, _ engine: HeadlessEngine) -> String? {
    let raw = UserDefaults.standard.string(forKey: modelKey(surface, engine))?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return (raw?.isEmpty ?? true) ? nil : raw
  }

  static func setModel(_ model: String?, _ surface: ModelSurface, _ engine: HeadlessEngine) {
    let trimmed = model?.trimmingCharacters(in: .whitespacesAndNewlines)
    UserDefaults.standard.set((trimmed?.isEmpty ?? true) ? nil : trimmed, forKey: modelKey(surface, engine))
  }
}

/// Reads the user's Codex config once. The streaming chat runs `codex` with `--ignore-user-config`
/// (so the user's *other* MCP servers can't crowd out canvas during startup) — which also drops the
/// `model` they set in `~/.codex/config.toml`. Surfacing it here lets the chat honor that model by
/// default and offer it in the picker, so Codex isn't silently pinned to its built-in default.
enum CodexConfig {
  static let defaultModel: String? = {
    let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/config.toml")
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
    return model(fromTOML: text)
  }()

  /// The top-level `model = "..."` from a Codex config (before the first `[table]`; profile models
  /// live under their own tables and don't apply globally). Pure so it's unit-testable.
  static func model(fromTOML text: String) -> String? {
    for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      if line.hasPrefix("[") { break }
      guard line.hasPrefix("model"), let eq = line.firstIndex(of: "=") else { continue }
      // Guard against `model_provider = …` etc.: the key must be exactly `model`.
      guard line[..<eq].trimmingCharacters(in: .whitespaces) == "model" else { continue }
      let value = line[line.index(after: eq)...]
        .trimmingCharacters(in: .whitespaces)
        .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
      if !value.isEmpty { return value }
    }
    return nil
  }
}
