import Foundation
import AppKit

struct AgentMessage: Identifiable, Equatable {
  enum Role { case user, assistant, tool, error }
  let id = UUID()
  let role: Role
  var text: String
}

/// Drives a headless `claude` agent that lives *inside* the canvas: each turn spawns the CLI in
/// `stream-json` mode with the canvas MCP server auto-attached (canvas tools only), and parses the
/// stream into a chat transcript. Session continuity is kept with `--resume`, so it's one ongoing
/// conversation. The agent's edits land on the board live via MCP → CanvasBridge.
/// The streaming chat transcript, split out of `CanvasAgent` so its high-frequency updates (one
/// per assistant token / tool call) re-render only the dock's message list — not every surface
/// that observes the agent's coarse status. The agent dock observes this; the canvas never does.
@MainActor
final class AgentTranscript: ObservableObject {
  @Published private(set) var messages: [AgentMessage] = []
  func append(_ message: AgentMessage) { messages.append(message) }
  func removeAll() { messages.removeAll() }
}

@MainActor
final class CanvasAgent: ObservableObject {
  /// One agent for the app's one window — a singleton so the conversation survives canvas
  /// rebuilds (e.g. a theme switch).
  static let shared = CanvasAgent()

  /// Streaming messages live in their own observable so the board, toolbar, and ⌘K palette can
  /// observe the agent for *coarse* state (below) without re-rendering on every streamed token.
  let transcript = AgentTranscript()
  /// Coarse, low-frequency state — safe for the canvas / toolbar / palette to observe directly.
  @Published private(set) var isRunning = false
  /// A folder the agent may read (repo or not) to ground its suggestions in real files. When set,
  /// the agent runs there with read-only file tools; otherwise it's canvas-only.
  @Published private(set) var groundingDirectory: URL?

  private var sessionID: String?
  private var process: Process?
  private var didRequestStop = false
  /// Bumped on every `send` and `stop`. A `run` only writes back coarse state / appends a failure
  /// while its captured token is still current, so a stopped-or-superseded turn that's still
  /// draining can't clobber the next turn's `isRunning`/`process` or inject a late error message.
  private var runToken = 0
  private static let groundingKey = "agent.groundingDirectory"

  init() {
    if let path = UserDefaults.standard.string(forKey: Self.groundingKey) {
      var isDir: ObjCBool = false
      if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
        groundingDirectory = URL(fileURLWithPath: path)
      }
    }
  }

  /// Pick (or clear) the folder the agent can read.
  func chooseDirectory() {
    // Suppress the panel's click-away dismissal while the picker is up.
    NotificationCenter.default.post(name: .composerBusyChanged, object: nil, userInfo: ["busy": true])
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.prompt = "Ground"
    panel.message = "Pick a folder the agent can read to ground its suggestions in real files."
    if let dir = groundingDirectory { panel.directoryURL = dir }
    let apply: (NSApplication.ModalResponse) -> Void = { [weak self] response in
      if response == .OK, let url = panel.url { self?.setGroundingDirectory(url) }
      NotificationCenter.default.post(name: .composerBusyChanged, object: nil, userInfo: ["busy": false])
    }
    if let window = NSApp.keyWindow {
      panel.beginSheetModal(for: window, completionHandler: apply)
    } else {
      apply(panel.runModal())
    }
  }

  func setGroundingDirectory(_ url: URL?) {
    groundingDirectory = url
    UserDefaults.standard.set(url?.path, forKey: Self.groundingKey)
  }

  func send(_ text: String) {
    let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !prompt.isEmpty, !isRunning else { return }
    transcript.append(AgentMessage(role: .user, text: prompt))
    didRequestStop = false
    isRunning = true
    runToken &+= 1
    let token = runToken
    let resume = sessionID
    let model = ModelPreferences.chatModel
    Task { await run(prompt: prompt, resume: resume, token: token, model: model) }
  }

  func stop() {
    didRequestStop = true
    process?.terminate()
    process = nil
    isRunning = false
    // Invalidate the in-flight turn so its still-draining tail can't write back over a later one.
    runToken &+= 1
  }

  func reset() {
    stop()
    sessionID = nil
    transcript.removeAll()
  }

  // MARK: Run one turn

  private func run(prompt: String, resume: String?, token: Int, model: ClaudeModel) async {
    // Write back coarse state only while this turn is still the current one — a stop() or a newer
    // send() bumps `runToken`, after which this (now superseded) turn must leave shared state alone.
    func finish(_ work: () -> Void) {
      guard token == runToken else { return }
      work()
      isRunning = false
      self.process = nil
    }

    guard let claude = Self.claudePath else {
      transcript.append(AgentMessage(role: .error, text: "Couldn't find the `claude` CLI. Install Claude Code, then reopen Composer."))
      finish {}
      return
    }
    // Two in-process MCP servers: `canvas` exposes the board tools the agent drives; `composer`
    // exposes only the permission arbiter that backs `--permission-prompt-tool` (see below).
    let port = CanvasServer.port
    let mcp = #"{"mcpServers":{"canvas":{"type":"http","url":"http://127.0.0.1:\#(port)/mcp"},"\#(PermissionMCP.serverName)":{"type":"http","url":"http://127.0.0.1:\#(port)/permission"}}}"#
    // Grounded: run in the chosen folder with read-only file tools so the agent can argue from
    // real files. Otherwise: canvas-only, in a neutral scratch dir.
    let grounded = groundingDirectory
    let tools = grounded != nil ? "mcp__canvas__*,Read,Grep,Glob" : "mcp__canvas__*"
    let systemPrompt = grounded != nil ? Self.systemPrompt + "\n\n" + Self.groundingAddendum : Self.systemPrompt
    // Anything the model reaches for beyond `tools` (an account connector like Craft, a built-in)
    // routes to our permission arbiter, which shows a real allow/deny dialog instead of letting the
    // CLI hit a silent wall in `-p` mode - the model used to invent a non-existent "approve in the
    // app" popup (issue #28). The arbiter tool is intentionally not in `--allowedTools`.
    var args = ["-p", prompt,
                "--model", model.cliAlias,
                "--output-format", "stream-json", "--verbose",
                "--mcp-config", mcp,
                "--allowedTools", tools,
                "--permission-prompt-tool", "mcp__\(PermissionMCP.serverName)__\(PermissionMCP.toolName)",
                "--append-system-prompt", systemPrompt]
    if let resume { args += ["--resume", resume] }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: claude)
    process.arguments = args
    process.currentDirectoryURL = grounded ?? Self.workdir
    var env = ProcessInfo.processInfo.environment
    env["PATH"] = Self.augmentedPATH(env["PATH"])
    process.environment = env
    let stdout = Pipe(), stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr

    // A stop() between this turn being queued and reaching here already invalidated the token —
    // don't launch a process that nobody can see in `self.process` (and so nobody could stop).
    guard token == runToken else { return }
    self.process = process

    do {
      try process.run()
    } catch {
      transcript.append(AgentMessage(role: .error, text: UserFacingError.message(for: error, while: "Starting Claude")))
      finish {}
      return
    }

    // Claude may put diagnostics on either stream. Drain stderr while stream-json is consumed from
    // stdout so an unusually verbose failure cannot block the process, and retain non-JSON stdout
    // for tools such as Claude Code that report a preflight failure before stream-json starts.
    let stderrReader = Task.detached { () -> Result<String, Error> in
      do {
        let data = try stderr.fileHandleForReading.readToEnd()
        return .success(data.flatMap { String(data: $0, encoding: .utf8) } ?? "")
      } catch {
        return .failure(error)
      }
    }
    var sawOutput = false
    var nonProtocolOutput: [String] = []
    do {
      for try await line in stdout.fileHandleForReading.bytes.lines {
        // Stop consuming (and appending) a superseded turn's stream the moment it's invalidated.
        if Task.isCancelled || token != runToken { break }
        if handleLine(line) {
          sawOutput = true
        } else {
          nonProtocolOutput.append(line)
        }
      }
    } catch { /* stream closed */ }

    process.waitUntilExit()
    let stderrText: String
    switch await stderrReader.value {
    case let .success(text):
      stderrText = text
    case let .failure(error):
      stderrText = UserFacingError.message(for: error, while: "Reading Claude’s error output")
    }
    finish {
      if process.terminationStatus != 0, !didRequestStop {
        transcript.append(AgentMessage(
          role: .error,
          text: UserFacingError.commandFailure(
            command: "Claude",
            status: process.terminationStatus,
            stdout: nonProtocolOutput.joined(separator: "\n"),
            stderr: stderrText)))
      } else if !sawOutput {
        let diagnostic = UserFacingError.commandOutput(
          stdout: nonProtocolOutput.joined(separator: "\n"), stderr: stderrText)
        if !diagnostic.isEmpty {
          transcript.append(AgentMessage(role: .error, text: "Claude returned output Composer could not read: \(diagnostic)"))
        }
      }
    }
  }

  /// Parse one stream-json line into transcript updates. Returns true if it produced output.
  @discardableResult
  private func handleLine(_ line: String) -> Bool {
    guard let data = line.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
    switch obj["type"] as? String {
    case "system":
      if (obj["subtype"] as? String) == "init", let sid = obj["session_id"] as? String { sessionID = sid }
      return false
    case "assistant":
      guard let message = obj["message"] as? [String: Any],
            let content = message["content"] as? [[String: Any]] else { return false }
      var produced = false
      for item in content {
        switch item["type"] as? String {
        case "text":
          let t = (item["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
          if !t.isEmpty { transcript.append(AgentMessage(role: .assistant, text: t)); produced = true }
        case "tool_use":
          let name = (item["name"] as? String ?? "").replacingOccurrences(of: "mcp__canvas__", with: "")
          transcript.append(AgentMessage(role: .tool, text: toolSummary(name, item["input"] as? [String: Any])))
          produced = true
        default: break
        }
      }
      return produced
    case "result":
      if let sid = obj["session_id"] as? String { sessionID = sid }
      return true
    default:
      return false
    }
  }

  private func toolSummary(_ name: String, _ input: [String: Any]?) -> String {
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
    default: return name
    }
  }
  private func snippet(_ value: Any?) -> String {
    // Collapse whitespace (including newlines) so a card's multi-line text stays on one
    // transcript line; the bubble itself also clamps to a single line.
    let collapsed = ((value as? String) ?? "")
      .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    return collapsed.count > 44 ? String(collapsed.prefix(44)) + "…" : collapsed
  }

  // MARK: Environment

  static let systemPrompt = """
  You are a thinking partner working ON a spatial idea canvas with the user. Use the canvas tools \
  (mcp__canvas__*) to read and shape the board directly — start by calling get_canvas. As you talk, \
  evolve the board: add concise cards for new ideas, sharpen vague ones with set_text, connect \
  related cards (use connect's reason to label WHY they relate).

  LAYOUT — this matters a lot. Never invent x/y coordinates to place cards yourself; you cannot \
  track overlaps or crossing lines in your head, and hand-placed boards come out tangled and ugly. \
  Instead, when you're laying out any STRUCTURE (an architecture, a flow, a tree, a comparison, a \
  decision graph), call `draw_diagram` ONCE: declare the nodes and the edges between them and the \
  board computes a clean layered layout for you. Each node is drawn as a LABELED BOX — so arrows \
  land on its edge instead of stabbing through floating text — which means each node's label must \
  be SHORT (a name or a few words, not a sentence or paragraph); keep any longer explanation for \
  the chat or a separate note card. Use a node "shape" of "diamond" for decision points and \
  "ellipse" for data/stores when it adds clarity. Use direction "down" for hierarchies/architecture \
  and "right" for pipelines/flows. For one-off prose use add_text and omit x/y (the board places \
  it). If you've added cards incrementally and the board looks messy, call `tidy` to straighten \
  everything. Treat the layout as the board's job, not yours.

  AUTHORSHIP — every node reports `whoWrote`: 1 = the human wrote or edited it, 2 = you drew it, \
  0 = unknown. When you re-read a board you've worked on, scan for whoWrote=1 nodes first: those \
  are exactly what the human added or changed since you last looked. A human-authored card that \
  reads like a question or a note ("is this right?", "what about X?") is a prompt aimed at you — \
  answer it (grounding in real files if relevant) rather than treating it as just another idea.

  Crucial — capture how ideas evolve: when an approach changes or you talk the user out of \
  something, call `supersede` (it fades the old card, adds the new one, and links them with your \
  reason). Never silently overwrite or delete an idea that's being replaced — the board should read \
  as a history of decisions and the "why" behind them, not just the latest state. Prefer many small \
  surgical cards over walls of text. Keep chat replies short — let the canvas hold the detail.
  """

  static let groundingAddendum = """
  You're running inside a folder you can READ (its files and code) with Read/Grep/Glob. Ground your \
  suggestions in what's actually there — open the relevant files before asserting how something \
  works. You cannot modify files; your thinking goes onto the canvas.
  """

  static let workdir: URL = {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    let dir = base.appendingPathComponent("Composer/agent", isDirectory: true)
    do {
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    } catch {
      UserFacingError.report(error, while: "Creating Claude’s Composer workspace")
    }
    return dir
  }()

  static let claudePath: String? = CommandLineToolLocator.executableURL(for: .claude)?.path

  static func augmentedPATH(_ existing: String?) -> String {
    let extra = ["/opt/homebrew/bin", "/opt/homebrew/sbin", NSHomeDirectory() + "/.local/bin",
                 "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
    var seen = Set<String>(); var ordered: [String] = []
    for path in extra + (existing?.split(separator: ":").map(String.init) ?? []) where seen.insert(path).inserted {
      ordered.append(path)
    }
    return ordered.joined(separator: ":")
  }
}
