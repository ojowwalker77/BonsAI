import Foundation

/// A headless coding-agent CLI used to refine a selection, refine a whole draft, and compile a
/// board. Today there is exactly one — Claude Code (`claude -p`) — but this enum is the deliberate
/// extension point: adding another engine (Codex, OpenCode, Pi, …) is a new `case` here plus the
/// handful of `switch`es the compiler will then flag for you. See docs/agent-engines.md.
enum HeadlessEngine: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
  case claude

  var id: String { rawValue }
  var title: String { rawValue.capitalized }
  var systemImage: String {
    switch self {
    case .claude: "sparkles"
    }
  }
  var logoResourceName: String {
    switch self {
    case .claude: "ClaudeAI"
    }
  }
  var commandLabel: String {
    switch self {
    case .claude: "claude -p"
    }
  }
}
