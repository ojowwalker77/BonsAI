import Foundation
import AppKit

struct AgentMessage: Identifiable, Equatable {
  enum Role { case user, assistant, tool, error }
  let id = UUID()
  let role: Role
  var text: String
}

/// Drives a headless coding agent that lives *inside* the canvas: each turn spawns the selected
/// engine's CLI in a streaming JSON mode with the canvas MCP server attached, and a `CanvasChatEngine`
/// adapter parses the stream into a chat transcript. Session continuity is kept per engine (Claude
/// `--resume`, Codex `exec resume`, OpenCode `--session`), so it's one ongoing conversation. The
/// agent's edits land on the board live via MCP → CanvasBridge. See docs/agent-engines.md.
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
  private let processSupervisor: AgentProcessSupervisor
  private var activeProcess: ManagedAgentProcess?
  private var runTask: Task<Void, Never>?
  private var didRequestStop = false
  private var isShuttingDown = false
  private var turnGeneration = AgentTurnGeneration()
  private static let groundingKey = "agent.groundingDirectory"

  init(processSupervisor: AgentProcessSupervisor = AgentProcessSupervisor()) {
    self.processSupervisor = processSupervisor
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
    panel.prompt = "Ground".localizedUI
    panel.message = "Pick a folder the agent can read to ground its suggestions in real files.".localizedUI
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
    guard !prompt.isEmpty, !isRunning, !isShuttingDown else { return }
    transcript.append(AgentMessage(role: .user, text: prompt))
    guard let engine = Self.resolvedEngine() else {
      transcript.append(AgentMessage(
        role: .error,
        text: "No coding-agent engine is enabled and installed for chat. Enable one in Settings → Runtime.".localizedUI))
      return
    }
    didRequestStop = false
    isRunning = true
    let token = turnGeneration.begin()
    let resume = sessionID
    let model = ModelPreferences.chatModel
    runTask = Task { await run(engine: engine, prompt: prompt, resume: resume, token: token, model: model) }
  }

  /// The engine this chat will run on: the user's explicit pick (Agent dock / Settings) when it's
  /// enabled and installed, otherwise the first enabled + installed engine in preference order.
  static func resolvedEngine() -> HeadlessEngine? {
    EnginePreferences.resolvedEngine(for: .chat, isAvailable: EngineCapabilityStore.shared.isAvailable)
  }

  func stop() {
    let process = invalidateCurrentTurn()
    guard let process else { return }
    let supervisor = processSupervisor
    Task { _ = await supervisor.stop(process) }
  }

  /// Invalidate the UI-owned turn synchronously on the main actor, then hand the thread-safe
  /// supervisor to AppDelegate so it can wait outside AppKit's modal termination run loop.
  func beginShutdown() -> AgentProcessSupervisor {
    isShuttingDown = true
    _ = invalidateCurrentTurn()
    return processSupervisor
  }

  func reset() {
    stop()
    sessionID = nil
    transcript.removeAll()
  }

  private func invalidateCurrentTurn() -> ManagedAgentProcess? {
    didRequestStop = true
    turnGeneration.invalidate()
    runTask?.cancel()
    runTask = nil
    isRunning = false
    let process = activeProcess
    activeProcess = nil
    return process
  }

  // MARK: Run one turn

  private func run(engine: HeadlessEngine, prompt: String, resume: String?, token: Int, model: ClaudeModel) async {
    // Write back coarse state only while this turn is still the current one — a stop() or a newer
    // send() bumps the generation, after which this turn must leave shared state alone.
    func finish(_ work: () -> Void) {
      guard turnGeneration.accepts(token) else { return }
      work()
      isRunning = false
      activeProcess = nil
      runTask = nil
    }

    let adapter = CanvasChatEngines.adapter(for: engine)
    guard let executable = adapter.executableURL else {
      transcript.append(AgentMessage(
        role: .error,
        text: "Couldn't find the `%@` CLI. Install %@, then reopen BonsAI.".localizedUI(engine.rawValue, engine.title)))
      finish {}
      return
    }
    let capability: String
    do {
      capability = try CanvasServer.shared.capabilityForClient()
    } catch {
      transcript.append(AgentMessage(
        role: .error,
        text: UserFacingError.message(
          for: error,
          while: "Preparing %@ to connect to the board securely".localizedUI(engine.title)
        )
      ))
      finish {}
      return
    }
    // Each engine reaches the same board over the loopback MCP server; the adapter builds its own
    // dialect of the invocation (Claude stream-json + --mcp-config, Codex exec --json + -c
    // mcp_servers.*, OpenCode run --format json + an inline config).
    let launch = adapter.launch(prompt: prompt, resume: resume, grounding: groundingDirectory,
                                model: model, port: CanvasServer.port, capability: capability,
                                workdir: Self.workdir)
    do {
      for configuration in launch.configurationFiles {
        try configuration.data.write(to: configuration.url, options: [.atomic])
        try FileManager.default.setAttributes(
          [.posixPermissions: 0o600],
          ofItemAtPath: configuration.url.path
        )
      }
    } catch {
      transcript.append(AgentMessage(
        role: .error,
        text: UserFacingError.message(
          for: error,
          while: "Preparing %@'s secure canvas configuration".localizedUI(engine.title)
        )
      ))
      finish {}
      return
    }

    let process = Process()
    process.executableURL = executable
    process.arguments = launch.arguments
    process.currentDirectoryURL = launch.workingDirectory
    var env = ProcessInfo.processInfo.environment
    env["PATH"] = Self.augmentedPATH(env["PATH"])
    for (key, value) in launch.extraEnvironment { env[key] = value }
    process.environment = env
    let stdout = Pipe(), stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    // Close stdin (EOF) so a CLI that reads it — Codex prints "Reading additional input from
    // stdin…" — doesn't block waiting for input that never comes.
    process.standardInput = FileHandle.nullDevice

    // A stop() between this turn being queued and reaching here already invalidated the generation.
    guard turnGeneration.accepts(token) else { return }

    let managedProcess: ManagedAgentProcess
    do {
      managedProcess = try processSupervisor.launch(process)
    } catch {
      transcript.append(AgentMessage(role: .error, text: UserFacingError.message(for: error, while: "Starting %@".localizedUI(engine.title))))
      finish {}
      return
    }
    activeProcess = managedProcess

    // The CLI may put diagnostics on either stream. Drain stderr while the JSON stream is consumed
    // from stdout so an unusually verbose failure cannot block the process, and retain non-protocol
    // stdout for a CLI that reports a preflight failure before its JSON stream starts.
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
        if Task.isCancelled || !turnGeneration.accepts(token) { break }
        let events = adapter.parse(line)
        if events.isEmpty {
          nonProtocolOutput.append(line)
          continue
        }
        for event in events {
          guard turnGeneration.accepts(token) else { break }
          switch event {
          case let .session(id): if !id.isEmpty { sessionID = id }
          case let .assistantText(text):
            transcript.append(AgentMessage(role: .assistant, text: text)); sawOutput = true
          case let .toolSummary(summary):
            transcript.append(AgentMessage(role: .tool, text: summary)); sawOutput = true
          }
        }
      }
    } catch { /* stream closed */ }

    let termination = await managedProcess.termination()
    let stderrText: String
    switch await stderrReader.value {
    case let .success(text):
      stderrText = text
    case let .failure(error):
      stderrText = UserFacingError.message(for: error, while: "Reading %@'s error output".localizedUI(engine.title))
    }
    finish {
      if termination.status != 0, !didRequestStop {
        transcript.append(AgentMessage(
          role: .error,
          text: UserFacingError.commandFailure(
            command: engine.title,
            status: termination.status,
            stdout: nonProtocolOutput.joined(separator: "\n"),
            stderr: stderrText)))
      } else if !sawOutput {
        let diagnostic = UserFacingError.commandOutput(
          stdout: nonProtocolOutput.joined(separator: "\n"), stderr: stderrText)
        if !diagnostic.isEmpty {
          transcript.append(AgentMessage(role: .error, text: "%@ returned output BonsAI could not read: %@".localizedUI(engine.title, diagnostic)))
        }
      }
    }
  }

  // MARK: Environment

  nonisolated static let systemPrompt = """
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
  it). Use `add_sticky` for a visually distinct reminder, `add_checklist` for actionable items \
  (then `set_checklist` or `toggle_checklist_item` as work changes), and `add_table` for compact \
  row/column comparisons (use `set_table` to revise it). For math — a derivation step, a governing equation, a formula worth staring at — use \
  `add_equation` with raw LaTeX math-mode source (no $ delimiters); it renders typeset on the \
  board, so never dump LaTeX into add_text where it would sit as raw markup. If you've added \
  cards incrementally and the board looks messy, call `tidy` to straighten everything. Treat the \
  layout as the board's job, not yours.

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

  nonisolated static let groundingAddendum = """
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
      UserFacingError.report(error, while: "Creating Claude's Composer workspace".localizedUI)
    }
    return dir
  }()

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
