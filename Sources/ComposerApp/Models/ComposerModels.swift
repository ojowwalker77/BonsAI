import Foundation

/// A headless coding-agent CLI used to refine a selection, refine a whole draft, and compile a
/// board. Today there is exactly one — Claude Code (`claude -p`) — but this enum is the deliberate
/// extension point: adding another engine (Codex, OpenCode, Pi, …) is a new `case` here plus the
/// handful of `switch`es the compiler will then flag for you. See docs/agent-engines.md.
enum HeadlessEngine: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
  case claude
  case codex

  var id: String { rawValue }
  var title: String {
    switch self {
    case .claude: "Claude"
    case .codex: "Codex"
    }
  }
  var systemImage: String {
    switch self {
    case .claude: "sparkles"
    case .codex: "terminal"
    }
  }
  var logoResourceName: String {
    switch self {
    case .claude: "ClaudeAI"
    case .codex: "Codex"
    }
  }
  var commandLabel: String {
    switch self {
    case .claude: "claude -p"
    case .codex: "codex exec"
    }
  }
}
