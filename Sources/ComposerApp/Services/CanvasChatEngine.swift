import Foundation

/// One parsed unit from an engine's streaming stdout, normalized across Claude / Codex / OpenCode so
/// `CanvasAgent` can drive one transcript regardless of which CLI is running.
enum AgentStreamEvent: Equatable {
  /// A chunk of assistant prose to show as a reply bubble.
  case assistantText(String)
  /// A one-line "did something to the board" summary (a tool call).
  case toolSummary(String)
  /// The engine's session id, stashed to resume the conversation next turn.
  case session(String)
}

/// Everything `CanvasAgent` needs to launch one streaming turn for a given engine. The executable
/// itself is resolved separately (via `CanvasChatEngine.executableURL`) so the launch builder stays
/// a pure function of the turn's inputs.
struct AgentLaunch {
  var arguments: [String]
  /// Extra environment entries merged over the process environment (OpenCode ships its MCP config
  /// this way). Empty for engines that pass everything on the command line.
  var extraEnvironment: [String: String] = [:]
  var workingDirectory: URL
}

/// Adapts one coding-agent CLI to the in-canvas streaming chat: how to launch a turn, and how to
/// turn its streaming stdout into normalized transcript events. Each engine reaches the same canvas
/// over the loopback MCP server but speaks its own dialect — Claude: `stream-json` + `--mcp-config`;
/// Codex: `exec --json` + `-c mcp_servers.*`; OpenCode: `run --format json` + an inline config.
/// See docs/agent-engines.md.
protocol CanvasChatEngine {
  var engine: HeadlessEngine { get }

  /// Build the invocation for one turn. `resume` is the prior session id (nil on the first turn);
  /// `grounding` is a folder the agent may read (nil ⇒ canvas-only, run in `workdir`).
  func launch(prompt: String, resume: String?, grounding: URL?, model: ClaudeModel,
              port: UInt16, workdir: URL) -> AgentLaunch

  /// Parse one line of streaming stdout into zero or more normalized events. An empty result means
  /// "not a protocol line" — the caller keeps it as diagnostic output for a failed run.
  func parse(_ line: String) -> [AgentStreamEvent]
}

extension CanvasChatEngine {
  /// The CLI binary, resolved without a login shell, or nil if it isn't installed on this Mac.
  var executableURL: URL? { CommandLineToolLocator.executableURL(for: engine) }
}

/// Factory for the streaming-chat adapter of a given engine.
enum CanvasChatEngines {
  static func adapter(for engine: HeadlessEngine) -> CanvasChatEngine {
    switch engine {
    case .claude: ClaudeChatEngine()
    case .codex: CodexChatEngine()
    case .opencode: OpenCodeChatEngine()
    }
  }
}

// MARK: - Claude (stream-json + MCP over --mcp-config)

/// The original streaming path: `claude -p … --output-format stream-json` with the canvas MCP server
/// and the permission arbiter attached, session continuity via `--resume`.
struct ClaudeChatEngine: CanvasChatEngine {
  let engine = HeadlessEngine.claude

  func launch(prompt: String, resume: String?, grounding: URL?, model: ClaudeModel,
              port: UInt16, workdir: URL) -> AgentLaunch {
    // Two in-process MCP servers: `canvas` exposes the board tools; `composer` exposes only the
    // permission arbiter that backs `--permission-prompt-tool`.
    let mcp = #"{"mcpServers":{"canvas":{"type":"http","url":"http://127.0.0.1:\#(port)/mcp"},"\#(PermissionMCP.serverName)":{"type":"http","url":"http://127.0.0.1:\#(port)/permission"}}}"#
    let grounded = grounding != nil
    // Grounded: read-only file tools so the agent can argue from real files. Otherwise canvas-only.
    let tools = grounded ? "mcp__canvas__*,Read,Grep,Glob" : "mcp__canvas__*"
    let systemPrompt = grounded ? CanvasAgent.systemPrompt + "\n\n" + CanvasAgent.groundingAddendum
                                : CanvasAgent.systemPrompt
    var args = ["-p", prompt,
                "--model", model.cliAlias,
                "--output-format", "stream-json", "--verbose",
                "--mcp-config", mcp,
                "--allowedTools", tools,
                "--permission-prompt-tool", "mcp__\(PermissionMCP.serverName)__\(PermissionMCP.toolName)",
                "--append-system-prompt", systemPrompt]
    if let resume { args += ["--resume", resume] }
    return AgentLaunch(arguments: args, workingDirectory: grounding ?? workdir)
  }

  /// Parse one stream-json line: `system`/`result` carry the session id; `assistant` carries text and
  /// `tool_use` blocks. Returns `[]` for lines we don't recognize (kept as diagnostics).
  func parse(_ line: String) -> [AgentStreamEvent] {
    guard let data = line.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
    switch obj["type"] as? String {
    case "system":
      if (obj["subtype"] as? String) == "init", let sid = obj["session_id"] as? String {
        return [.session(sid)]
      }
      return [.session("")]   // recognized protocol line, no id — not diagnostic noise
    case "assistant":
      guard let message = obj["message"] as? [String: Any],
            let content = message["content"] as? [[String: Any]] else { return [] }
      var events: [AgentStreamEvent] = []
      for item in content {
        switch item["type"] as? String {
        case "text":
          let t = (item["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
          if !t.isEmpty { events.append(.assistantText(t)) }
        case "tool_use":
          let name = (item["name"] as? String ?? "").replacingOccurrences(of: "mcp__canvas__", with: "")
          events.append(.toolSummary(CanvasToolSummary.summarize(name, item["input"] as? [String: Any])))
        default: break
        }
      }
      return events
    case "result":
      if let sid = obj["session_id"] as? String { return [.session(sid)] }
      return [.session("")]
    default:
      return []
    }
  }
}

// MARK: - Codex (exec --json + MCP over -c mcp_servers.*)

/// `codex exec --json` streaming. The canvas MCP server is attached with a per-server
/// `default_tools_approval_mode = "approve"` so its (board-only) tools run without an approval prompt
/// that headless `exec` could never answer; a read-only sandbox keeps Codex off the user's disk while
/// still letting it read grounded files. Continuity is `codex exec resume <thread_id>`. The user's
/// global config is skipped (`--ignore-user-config`) so unrelated MCP servers can't crowd out canvas —
/// auth still comes from `$CODEX_HOME`.
struct CodexChatEngine: CanvasChatEngine {
  let engine = HeadlessEngine.codex

  func launch(prompt: String, resume: String?, grounding: URL?, model: ClaudeModel,
              port: UInt16, workdir: URL) -> AgentLaunch {
    let cwd = grounding ?? workdir
    // Codex has no `--append-system-prompt`; give it the canvas rules once, on the first turn (later
    // turns resume the same thread and keep the context). Grounded turns add the file-reading note.
    let firstTurn = resume == nil
    let system = grounding != nil ? CanvasAgent.systemPrompt + "\n\n" + CanvasAgent.groundingAddendum
                                  : CanvasAgent.systemPrompt
    let fullPrompt = firstTurn ? system + "\n\n=====\n\n" + prompt : prompt

    var args = ["exec"]
    if let resume { args += ["resume", resume] }
    args += ["--json", "--skip-git-repo-check", "--ignore-user-config"]
    // `--sandbox` / `--cd` are only valid on a fresh `exec`; a resumed session inherits both from the
    // turn that created it, and `codex exec resume` rejects them outright.
    if resume == nil { args += ["--sandbox", "read-only", "--cd", cwd.path] }
    args += ["-c", "approval_policy=\"never\"",
             "-c", "mcp_servers.canvas.url=\"http://127.0.0.1:\(port)/mcp\"",
             "-c", "mcp_servers.canvas.default_tools_approval_mode=\"approve\""]
    // `--ignore-user-config` drops the user's `~/.codex/config.toml` model, so pass it (or their pick
    // in BonsAI) explicitly — otherwise Codex silently falls back to its built-in default.
    if let model = EngineModelPreferences.selectedModel(.chat, .codex) ?? CodexConfig.defaultModel {
      args += ["-m", model]
    }
    args.append(fullPrompt)
    return AgentLaunch(arguments: args, workingDirectory: cwd)
  }

  /// Codex emits one JSON object per line. The session id rides `thread.started`; finished items
  /// (`item.completed`) carry the assistant message, MCP tool calls, and shell commands.
  func parse(_ line: String) -> [AgentStreamEvent] {
    guard let data = line.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
    switch obj["type"] as? String {
    case "thread.started":
      if let id = obj["thread_id"] as? String { return [.session(id)] }
      return [.session("")]
    case "turn.started", "turn.completed":
      return [.session("")]   // recognized framing, nothing to show
    case "item.completed":
      guard let item = obj["item"] as? [String: Any] else { return [] }
      switch item["type"] as? String {
      case "agent_message":
        let t = (item["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? [] : [.assistantText(t)]
      case "mcp_tool_call":
        // Canvas tools come through as their bare name (server == "canvas").
        let tool = item["tool"] as? String ?? ""
        return [.toolSummary(CanvasToolSummary.summarize(tool, item["arguments"] as? [String: Any]))]
      case "command_execution":
        // Grounded reads run as shell commands; show a compact line so the work is visible.
        let command = (item["command"] as? String ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let short = command.count > 44 ? String(command.prefix(44)) + "…" : command
        return short.isEmpty ? [] : [.toolSummary("ran \(short)")]
      default:
        // reasoning / error / web_search / etc. — recognized framing, nothing to surface.
        return [.session("")]
      }
    default:
      return []
    }
  }
}

// MARK: - OpenCode (run --format json + MCP over an inline config)

/// `opencode run --format json` streaming. OpenCode configures MCP through its config file, so the
/// canvas server is injected inline via `OPENCODE_CONFIG_CONTENT` (highest-priority source), together
/// with a permission policy that denies file edits and shell — the agent's writes belong on the board,
/// not on disk. `--dangerously-skip-permissions` auto-approves what's left (the canvas tools and file
/// reads). Continuity is `--session <id>`.
struct OpenCodeChatEngine: CanvasChatEngine {
  let engine = HeadlessEngine.opencode

  func launch(prompt: String, resume: String?, grounding: URL?, model: ClaudeModel,
              port: UInt16, workdir: URL) -> AgentLaunch {
    let cwd = grounding ?? workdir
    let firstTurn = resume == nil
    let system = grounding != nil ? CanvasAgent.systemPrompt + "\n\n" + CanvasAgent.groundingAddendum
                                  : CanvasAgent.systemPrompt
    let fullPrompt = firstTurn ? system + "\n\n=====\n\n" + prompt : prompt

    var args = ["run", "--format", "json", "--dangerously-skip-permissions", "--dir", cwd.path]
    if let resume { args += ["--session", resume] }
    // A `provider/model` from the dock picker (see `opencode models`); nil ⇒ OpenCode's own default.
    if let model = EngineModelPreferences.selectedModel(.chat, .opencode) { args += ["-m", model] }
    args.append(fullPrompt)

    // Inline config (precedence over project/global) so canvas MCP is always present and edits/bash
    // are denied regardless of what the grounded folder's own opencode.json might say.
    let config = #"{"mcp":{"canvas":{"type":"remote","url":"http://127.0.0.1:\#(port)/mcp","enabled":true}},"permission":{"edit":"deny","bash":"deny"}}"#
    return AgentLaunch(arguments: args, extraEnvironment: ["OPENCODE_CONFIG_CONTENT": config], workingDirectory: cwd)
  }

  /// OpenCode emits one JSON event per line. `text` parts carry assistant prose, `tool_use` parts
  /// carry tool calls, and `sessionID` rides every event. `step_finish` marks turn boundaries.
  func parse(_ line: String) -> [AgentStreamEvent] {
    guard let data = line.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
    // The part may sit at the top level (`run --format json`) or under `properties` (bus events).
    let part = (obj["part"] as? [String: Any]) ?? ((obj["properties"] as? [String: Any])?["part"] as? [String: Any])
    var events: [AgentStreamEvent] = []
    if let sid = (obj["sessionID"] as? String) ?? (part?["sessionID"] as? String), !sid.isEmpty {
      events.append(.session(sid))
    }
    let kind = (obj["type"] as? String) ?? ""
    switch kind {
    case "text":
      let t = ((part?["text"] as? String) ?? (obj["text"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      if !t.isEmpty { events.append(.assistantText(t)) }
    case "tool_use", "tool":
      let raw = (part?["tool"] as? String) ?? (obj["tool"] as? String) ?? ""
      // OpenCode names MCP tools `<server>_<tool>` (e.g. `canvas_get_canvas`); strip the prefix so
      // the canvas summarizer recognizes it, and leave built-ins (read/grep/glob) as their own name.
      let name = raw.hasPrefix("canvas_") ? String(raw.dropFirst("canvas_".count)) : raw
      let input = (part?["state"] as? [String: Any])?["input"] as? [String: Any]
      if !name.isEmpty { events.append(.toolSummary(CanvasToolSummary.summarize(name, input))) }
    default:
      break
    }
    return events
  }
}

// MARK: - Shared tool summaries

/// Maps a canvas tool call (name + input) to the one-line summary shown in the transcript. Shared by
/// every engine so "drew a diagram · 4 cards" reads the same whichever CLI made the call.
enum CanvasToolSummary {
  static func summarize(_ name: String, _ input: [String: Any]?) -> String {
    switch name {
    case "get_canvas": return "read the board"
    case "draw_diagram":
      let count = (input?["nodes"] as? [[String: Any]])?.count ?? 0
      return "drew a diagram · \(count) card\(count == 1 ? "" : "s")"
    case "tidy": return "tidied the layout"
    case "add_text": return "added a card · \(snippet(input?["text"]))"
    case "add_shape": return "drew a \(input?["kind"] as? String ?? "shape")"
    case "set_text": return "rewrote a card · \(snippet(input?["text"]))"
    case "move_node": return "moved a card"
    case "resize_node": return "resized a card"
    case "delete_node": return "removed a card"
    case "connect": return "connected two cards"
    case "archive": return "archived a card"
    case "supersede": return "evolved an idea · \(snippet(input?["text"]))"
    default: return name.isEmpty ? "used a tool" : name
    }
  }

  private static func snippet(_ value: Any?) -> String {
    // Collapse whitespace (including newlines) so a card's multi-line text stays on one transcript
    // line; the bubble itself also clamps to a single line.
    let collapsed = ((value as? String) ?? "")
      .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    return collapsed.count > 44 ? String(collapsed.prefix(44)) + "…" : collapsed
  }
}
