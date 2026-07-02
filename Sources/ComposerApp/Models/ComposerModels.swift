import Foundation

/// A headless coding-agent CLI used to refine a selection, refine a whole draft, and compile a
/// board. This enum is the deliberate extension point: adding another engine (Pi, …) is a new
/// `case` here plus the handful of `switch`es the compiler will then flag for you. The order of the
/// cases is the preference order surfaces use when they auto-pick an engine (see `preferredEngine`).
/// See docs/agent-engines.md.
enum HeadlessEngine: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
  case claude
  case codex
  case opencode

  var id: String { rawValue }
  var title: String {
    switch self {
    case .claude: "Claude"
    case .codex: "Codex"
    case .opencode: "OpenCode"
    }
  }
  var systemImage: String {
    switch self {
    case .claude: "sparkles"
    case .codex: "terminal"
    case .opencode: "chevron.left.forwardslash.chevron.right"
    }
  }
  var logoResourceName: String {
    switch self {
    case .claude: "ClaudeAI"
    case .codex: "Codex"
    case .opencode: "OpenCode"
    }
  }
  var commandLabel: String {
    switch self {
    case .claude: "claude -p"
    case .codex: "codex exec"
    case .opencode: "opencode run"
    }
  }
}

/// A Claude model the headless `claude` CLI can target via `--model`. The rawValue is the CLI
/// *alias* (`opus` / `sonnet` / `haiku`), which the CLI resolves to the latest model in that tier —
/// so this never pins a dated snapshot and never ships its own model. The two surfaces that pick a
/// model default differently: the in-canvas chat agent defaults to Opus, describing the board
/// defaults to Sonnet. See [[ModelPreferences]] and docs/agent-engines.md.
enum ClaudeModel: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
  case opus
  case sonnet
  case haiku

  var id: String { rawValue }
  /// Passed verbatim as the value of `claude --model`.
  var cliAlias: String { rawValue }
  var title: String {
    switch self {
    case .opus: "Opus"
    case .sonnet: "Sonnet"
    case .haiku: "Haiku"
    }
  }
  /// A one-line tier hint shown beneath the name in a picker.
  var tagline: String {
    switch self {
    case .opus: "Most capable"
    case .sonnet: "Balanced"
    case .haiku: "Fastest"
    }
  }
}
