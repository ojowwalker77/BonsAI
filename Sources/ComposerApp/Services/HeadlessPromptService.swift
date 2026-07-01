import Foundation

/// Runs `claude -p` headlessly to refine a selection in-place, always passing the whole note as
/// context for better answers.
struct HeadlessPromptService {
  func refineSelection(whole: String, selection: String, engine: HeadlessEngine) async throws -> String {
    let prompt = """
    You are refining one part of a draft prompt that will be handed to a coding agent.
    Rewrite ONLY the SELECTED TEXT so it is clearer, more concrete, and more useful — \
    preserve the author's intent and voice, resolve ambiguity, and keep it tight. \
    Do not add commentary. Return ONLY the rewritten selection: no preamble, no quotes, no markdown fences.

    ===== FULL DRAFT (context — do not rewrite this) =====
    \(whole)

    ===== SELECTED TEXT TO REWRITE =====
    \(selection)
    """
    return try await run(prompt: prompt, engine: engine)
  }

  /// Rewrite the ENTIRE draft per a chosen intent (Tighten / Concise / Spec / Checklist).
  /// `@mention` tokens are preserved verbatim so the prompt stays valid.
  func refineDraft(text: String, intent: RefineIntent, engine: HeadlessEngine) async throws -> String {
    let prompt = """
    \(intent.instruction)

    ===== DRAFT =====
    \(text)
    """
    return try await run(prompt: prompt, engine: engine)
  }

  /// Merge a board's cards (already joined in reading order) into one ordered, paste-ready
  /// prompt. `@mention` tokens are preserved verbatim so the result stays valid.
  func compileBoard(source: String, engine: HeadlessEngine) async throws -> String {
    let prompt = """
    \(BoardCompile.instruction)

    ===== CARDS (in reading order) =====
    \(source)
    """
    return try await run(prompt: prompt, engine: engine)
  }

  /// Describe the WHOLE board — text cards, shapes, diagrams, and how they connect — as one
  /// self-contained, paste-ready brief. `state` is the board graph JSON (the same snapshot the
  /// canvas MCP `get_canvas` exposes); unlike `compileBoard` (which merges card prose) this reads
  /// the full graph, so the description covers everything the board holds.
  func describeBoard(state: String, engine: HeadlessEngine, model: ClaudeModel) async throws -> String {
    let prompt = """
    \(BoardDescribe.instruction)

    ===== BOARD STATE (JSON graph: nodes, edges, reading order) =====
    \(state)
    """
    // Describe references image cards by absolute path; allow the read-only Read tool so `claude -p`
    // can open those images non-interactively (otherwise the permission prompt auto-denies and the
    // model never sees them). Read can't mutate anything, so this is safe for a describe pass.
    return try await run(prompt: prompt, engine: engine, model: model, allowReadTool: true)
  }

  /// `model` is optional: when nil the CLI picks its own default (used by Refine / Compile);
  /// Describe passes the user's chosen `ClaudeModel` so it can run on a different tier.
  private func run(prompt: String, engine: HeadlessEngine, model: ClaudeModel? = nil, allowReadTool: Bool = false) async throws -> String {
    guard let executable = CommandLineToolLocator.executableURL(for: engine) else {
      throw HeadlessPromptError.failed("\(engine.title) CLI is not installed. Check Settings to install or re-detect it.")
    }
    var arguments: [String]
    switch engine {
    case .claude:
      arguments = [executable.path, "-p", prompt]
      if let model { arguments += ["--model", model.cliAlias] }
      // Non-interactive `-p` auto-denies any tool needing permission, so opt Read in explicitly when
      // the prompt asks the model to open local files (e.g. Describe reading image cards by path).
      if allowReadTool { arguments += ["--allowedTools", "Read"] }
    case .codex:
      // Read-only sandbox: one-shot refine/compile must not mutate the user's repo. Codex already
      // runs read-only, so it can open referenced files without an extra flag; `model` and the Read
      // opt-in are Claude-only, so Codex ignores them.
      arguments = [executable.path, "exec", "--sandbox", "read-only", "--ephemeral", prompt]
    }
    let result: Shell.Result
    do {
      result = try await Shell.run(arguments)
    } catch {
      throw HeadlessPromptError.failed(UserFacingError.message(for: error, while: "Composer could not start \(engine.title)"))
    }
    let out = result.stdout.trimmed
    guard result.status == 0 else {
      throw HeadlessPromptError.failed(UserFacingError.commandFailure(command: engine.title, result: result))
    }
    guard !out.isEmpty else {
      throw HeadlessPromptError.failed("\(engine.title) exited successfully but returned no text.")
    }
    return out
  }
}

enum HeadlessPromptError: LocalizedError {
  case failed(String)
  var errorDescription: String? {
    switch self {
    case .failed(let message): message
    }
  }
}
