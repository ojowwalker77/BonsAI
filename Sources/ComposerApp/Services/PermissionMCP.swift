import Foundation

/// A one-tool MCP server that backs the agent's `--permission-prompt-tool`.
///
/// The headless `claude` calls its `approve` tool whenever the model reaches for a tool that has no
/// static allow rule - an account-level connector (Craft, Notion, etc.) or a built-in. We turn that
/// JSON-RPC call into a real allow/deny dialog via `AgentPermissionBroker` (issue #28), then hand
/// back the `PermissionResult` the CLI expects.
///
/// Mounted on the canvas HTTP server at `/permission` and exposed to the CLI as
/// `mcp__composer__approve`. It is deliberately kept OFF the agent's `--allowedTools`, so the model
/// can't invoke it as a normal tool - the CLI reserves it for permission prompts.
@MainActor
enum PermissionMCP {
  /// Must match the server key the agent registers in `--mcp-config` and the
  /// `--permission-prompt-tool mcp__<serverName>__<toolName>` it passes. `nonisolated` so the engine
  /// adapters (which build the invocation off the MainActor) can name it.
  nonisolated static let serverName = "composer"
  nonisolated static let toolName = "approve"
  private static let fallbackProtocol = "2025-06-18"

  /// Returns the JSON-RPC response, or nil for notifications (which get a 202 with no body).
  static func handle(_ message: [String: Any]) -> [String: Any]? {
    let id = message["id"]
    guard let method = message["method"] as? String else { return nil }

    switch method {
    case "initialize":
      let version = ((message["params"] as? [String: Any])?["protocolVersion"] as? String) ?? fallbackProtocol
      return reply(id, [
        "protocolVersion": version,
        "capabilities": ["tools": [String: Any]()],
        "serverInfo": ["name": "composer-permission", "version": "0.1.0"],
      ])

    case "ping":
      return reply(id, [:])

    case "tools/list":
      return reply(id, ["tools": [toolSpec]])

    case "tools/call":
      let params = message["params"] as? [String: Any] ?? [:]
      // The CLI hands us the call awaiting a decision under `tool_name` / `input`.
      let arguments = params["arguments"] as? [String: Any] ?? [:]
      let pendingTool = arguments["tool_name"] as? String ?? ""
      let pendingInput = arguments["input"] as? [String: Any] ?? [:]
      let decision = AgentPermissionBroker.resolve(toolName: pendingTool, input: pendingInput)
      // `isError` stays false: a deny is a *successful* decision, not a tool failure.
      return reply(id, ["content": [["type": "text", "text": decision]], "isError": false])

    case let m where m.hasPrefix("notifications/"):
      return nil

    default:
      return errorReply(id, code: -32601, message: "method not found: \(method)")
    }
  }

  private static let toolSpec: [String: Any] = [
    "name": toolName,
    "description": "Internal permission arbiter for the Composer host app. The CLI invokes this automatically to ask the user before running a tool that isn't pre-approved - do not call it yourself.",
    "inputSchema": [
      "type": "object",
      "properties": [
        "tool_name": ["type": "string", "description": "The tool awaiting a permission decision."],
        "input": ["type": "object", "description": "The arguments that tool would run with."],
      ],
      "required": ["tool_name", "input"],
    ],
  ]

  // MARK: JSON-RPC envelope

  private static func reply(_ id: Any?, _ result: [String: Any]) -> [String: Any] {
    ["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result]
  }
  private static func errorReply(_ id: Any?, code: Int, message: String) -> [String: Any] {
    ["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]]
  }
}
