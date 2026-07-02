import XCTest
@testable import ComposerApp

/// Locks in the per-engine stream parsers — the load-bearing, hard-to-eyeball half of the streaming
/// chat. The Codex lines are verbatim captures from `codex exec --json` against the canvas MCP
/// server; the Claude line is its `stream-json` shape; the OpenCode lines follow `run --format json`.
final class CanvasChatEngineTests: XCTestCase {

  // MARK: Codex (real captures)

  func testCodexThreadStartedYieldsSession() {
    let line = #"{"type":"thread.started","thread_id":"019f1e2f-667a-7040-a7eb-7e3f48f544dc"}"#
    XCTAssertEqual(CodexChatEngine().parse(line), [.session("019f1e2f-667a-7040-a7eb-7e3f48f544dc")])
  }

  func testCodexAgentMessageBecomesAssistantText() {
    let line = #"{"type":"item.completed","item":{"id":"item_2","type":"agent_message","text":"Node count: 1"}}"#
    XCTAssertEqual(CodexChatEngine().parse(line), [.assistantText("Node count: 1")])
  }

  func testCodexMcpToolCallBecomesCanvasSummary() {
    let line = #"{"type":"item.completed","item":{"id":"item_1","type":"mcp_tool_call","server":"canvas","tool":"get_canvas","arguments":{},"result":{"content":[]},"status":"completed"}}"#
    XCTAssertEqual(CodexChatEngine().parse(line), [.toolSummary("read the board")])
  }

  func testCodexDrawDiagramCountsNodes() {
    let line = #"{"type":"item.completed","item":{"type":"mcp_tool_call","server":"canvas","tool":"draw_diagram","arguments":{"nodes":[{"key":"a","text":"A"},{"key":"b","text":"B"}]},"status":"completed"}}"#
    XCTAssertEqual(CodexChatEngine().parse(line), [.toolSummary("drew a diagram · 2 cards")])
  }

  func testCodexCommandExecutionIsSurfacedCompactly() {
    let line = #"{"type":"item.completed","item":{"type":"command_execution","command":"/bin/zsh -lc ls","aggregated_output":"note.txt\n","exit_code":0,"status":"completed"}}"#
    XCTAssertEqual(CodexChatEngine().parse(line), [.toolSummary("ran /bin/zsh -lc ls")])
  }

  func testCodexFramingLinesAreRecognizedButSilent() {
    // Recognized protocol framing → a no-op session event, NOT diagnostic noise.
    XCTAssertEqual(CodexChatEngine().parse(#"{"type":"turn.started"}"#), [.session("")])
    XCTAssertEqual(CodexChatEngine().parse(#"{"type":"turn.completed","usage":{}}"#), [.session("")])
  }

  func testCodexNonJSONLineIsNotRecognized() {
    XCTAssertTrue(CodexChatEngine().parse("Reading additional input from stdin...").isEmpty)
  }

  // MARK: Claude (stream-json)

  func testClaudeInitCarriesSession() {
    let line = #"{"type":"system","subtype":"init","session_id":"abc-123"}"#
    XCTAssertEqual(ClaudeChatEngine().parse(line), [.session("abc-123")])
  }

  func testClaudeAssistantTextAndToolUse() {
    let line = #"{"type":"assistant","message":{"content":[{"type":"text","text":"Here you go."},{"type":"tool_use","name":"mcp__canvas__add_text","input":{"text":"a new card"}}]}}"#
    XCTAssertEqual(ClaudeChatEngine().parse(line),
                   [.assistantText("Here you go."), .toolSummary("added a card · a new card")])
  }

  // MARK: OpenCode (run --format json)

  func testOpenCodeTextPartBecomesAssistantText() {
    let line = #"{"type":"text","sessionID":"ses_abc","part":{"type":"text","text":"hello","sessionID":"ses_abc"}}"#
    XCTAssertEqual(OpenCodeChatEngine().parse(line), [.session("ses_abc"), .assistantText("hello")])
  }

  func testOpenCodeCanvasToolStripsServerPrefix() {
    let line = #"{"type":"tool_use","sessionID":"ses_abc","part":{"tool":"canvas_get_canvas","state":{"status":"completed","input":{}}}}"#
    XCTAssertEqual(OpenCodeChatEngine().parse(line), [.session("ses_abc"), .toolSummary("read the board")])
  }

  // MARK: Codex invocation (resume must drop fresh-only flags)

  func testCodexFreshTurnSetsSandboxAndCwd() {
    let launch = CodexChatEngine().launch(
      prompt: "hi", resume: nil, grounding: nil, model: .opus, port: 7337,
      workdir: URL(fileURLWithPath: "/tmp/scratch"))
    XCTAssertTrue(launch.arguments.contains("--sandbox"))
    XCTAssertTrue(launch.arguments.contains("--cd"))
    XCTAssertFalse(launch.arguments.contains("resume"))
  }

  func testCodexResumeTurnOmitsSandboxAndCwd() {
    // `codex exec resume` rejects --sandbox/--cd; a resumed session inherits them.
    let launch = CodexChatEngine().launch(
      prompt: "again", resume: "thread-123", grounding: nil, model: .opus, port: 7337,
      workdir: URL(fileURLWithPath: "/tmp/scratch"))
    XCTAssertEqual(Array(launch.arguments.prefix(3)), ["exec", "resume", "thread-123"])
    XCTAssertFalse(launch.arguments.contains("--sandbox"))
    XCTAssertFalse(launch.arguments.contains("--cd"))
    XCTAssertTrue(launch.arguments.contains("--json"))
    XCTAssertTrue(launch.arguments.contains("mcp_servers.canvas.default_tools_approval_mode=\"approve\""))
  }

  func testOpenCodeResumePassesSessionAndInlineMCPConfig() {
    let launch = OpenCodeChatEngine().launch(
      prompt: "again", resume: "ses_9", grounding: nil, model: .opus, port: 7337,
      workdir: URL(fileURLWithPath: "/tmp/scratch"))
    XCTAssertTrue(launch.arguments.contains("--session"))
    XCTAssertTrue(launch.arguments.contains("ses_9"))
    XCTAssertTrue(launch.arguments.contains("--dangerously-skip-permissions"))
    XCTAssertNotNil(launch.extraEnvironment["OPENCODE_CONFIG_CONTENT"])
    XCTAssertTrue((launch.extraEnvironment["OPENCODE_CONFIG_CONTENT"] ?? "").contains("\"canvas\""))
  }

  // MARK: OpenCode one-shot text extraction (real --format json shape)

  func testOpenCodeOneShotExtractionStripsChromeAndStitchesText() {
    // Verbatim shape from `opencode run --format json` (step_start / text / step_finish).
    let stdout = """
    {"type":"step_start","sessionID":"ses_1","part":{"type":"step-start"}}
    {"type":"text","sessionID":"ses_1","part":{"type":"text","text":"Add a caching layer.","time":{"start":1,"end":2}}}
    {"type":"step_finish","sessionID":"ses_1","part":{"reason":"stop","type":"step-finish"}}
    """
    XCTAssertEqual(HeadlessPromptService.openCodeText(from: stdout), "Add a caching layer.")
  }

  func testOpenCodeOneShotJoinsMultipleTextParts() {
    let stdout = """
    {"type":"text","sessionID":"ses_1","part":{"type":"text","text":"line one"}}
    {"type":"text","sessionID":"ses_1","part":{"type":"text","text":"line two"}}
    """
    XCTAssertEqual(HeadlessPromptService.openCodeText(from: stdout), "line one\nline two")
  }

  // MARK: Codex config model parsing

  func testCodexConfigModelParsesTopLevel() {
    XCTAssertEqual(CodexConfig.model(fromTOML: "model = \"gpt-5.5\"\napproval_policy = \"never\""), "gpt-5.5")
  }

  func testCodexConfigModelIgnoresModelProviderAndProfiles() {
    let toml = """
    model_provider = "openai"
    model = "o3"
    [profiles.fast]
    model = "should-not-win"
    """
    XCTAssertEqual(CodexConfig.model(fromTOML: toml), "o3")
  }

  func testCodexConfigModelNilWhenOnlyUnderTable() {
    let toml = "[profiles.fast]\nmodel = \"gpt-5\""
    XCTAssertNil(CodexConfig.model(fromTOML: toml))
  }

  // MARK: OpenCode model grouping

  func testOpenCodeModelsGroupByProvider() {
    let groups = ChatModelCatalog.groupByProvider(
      ["opencode/big-pickle", "opencode/deepseek-v4-flash-free", "anthropic/claude-x"])
    XCTAssertEqual(groups.map(\.provider), ["opencode", "anthropic"])
    XCTAssertEqual(groups.first?.models.count, 2)
    XCTAssertEqual(groups.last?.models, ["anthropic/claude-x"])
  }

  // MARK: Shared summaries

  func testCanvasToolSummaryConnectAndUnknown() {
    XCTAssertEqual(CanvasToolSummary.summarize("connect", nil), "connected two cards")
    XCTAssertEqual(CanvasToolSummary.summarize("some_builtin", nil), "some_builtin")
    XCTAssertEqual(CanvasToolSummary.summarize("draw_diagram", ["nodes": [["x": 1]]]), "drew a diagram · 1 card")
  }
}
