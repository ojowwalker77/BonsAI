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

  /// `model` is an optional CLI model id: Claude's alias (`opus`/`sonnet`/`haiku`) via `--model`,
  /// Codex/OpenCode's `provider/model` via `-m`. nil ⇒ the CLI's own default (used by Refine/Compile).
  private func run(prompt: String, engine: HeadlessEngine, model: String? = nil) async throws -> String {
    guard let executable = CommandLineToolLocator.executableURL(for: engine) else {
      throw HeadlessPromptError.failed("\(engine.title) CLI is not installed. Check Settings to install or re-detect it.")
    }
    var arguments: [String]
    switch engine {
    case .claude:
      arguments = [executable.path, "-p", prompt]
      if let model { arguments += ["--model", model] }
    case .codex:
      // Read-only sandbox: one-shot refine/compile/describe must not mutate the user's repo. Codex
      // already runs read-only. `--ephemeral` skips session files (one-shot, no continuity), and
      // `--skip-git-repo-check` lets it run from any cwd (else it refuses outside a trusted git dir).
      arguments = [executable.path, "exec", "--sandbox", "read-only", "--ephemeral", "--skip-git-repo-check"]
      if let model { arguments += ["-m", model] }
      arguments.append(prompt)
    case .opencode:
      // `opencode run` (default format) prints a `> agent · model` header and ANSI codes around the
      // reply, so its raw stdout isn't paste-ready. Ask for `--format json` and stitch the assistant
      // text back together below.
      arguments = [executable.path, "run", "--format", "json"]
      if let model { arguments += ["-m", model] }
      arguments.append(prompt)
    }
    let result: Shell.Result
    do {
      result = try await Shell.run(arguments)
    } catch {
      throw HeadlessPromptError.failed(UserFacingError.message(for: error, while: "Composer could not start \(engine.title)"))
    }
    guard result.status == 0 else {
      throw HeadlessPromptError.failed(UserFacingError.commandFailure(command: engine.title, result: result))
    }
    let out = engine == .opencode ? Self.openCodeText(from: result.stdout) : result.stdout.trimmed
    guard !out.isEmpty else {
      throw HeadlessPromptError.failed("\(engine.title) exited successfully but returned no text.")
    }
    return out
  }

  /// Stitch the assistant text out of `opencode run --format json` output (JSONL). Reuses the same
  /// parser the streaming chat uses, so the one-shot and streaming paths agree on what "the text" is.
  static func openCodeText(from stdout: String) -> String {
    let engine = OpenCodeChatEngine()
    var pieces: [String] = []
    for line in stdout.split(separator: "\n", omittingEmptySubsequences: true) {
      for case let .assistantText(text) in engine.parse(String(line)) { pieces.append(text) }
    }
    return pieces.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
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
