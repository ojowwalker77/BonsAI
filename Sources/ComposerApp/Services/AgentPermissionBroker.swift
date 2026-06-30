import AppKit
import Foundation

/// Mediates tool-permission decisions for the in-canvas agent.
///
/// The headless `claude` runs with the canvas tools pre-allowed (`--allowedTools mcp__canvas__*`).
/// Anything *else* the model reaches for - an account-level MCP connector like Craft, or a built-in
/// tool - has no static allow rule, so in `-p` mode it used to hit a silent permission wall and the
/// model would invent a non-existent "approve it in the app" popup (issue #28). With
/// `--permission-prompt-tool` pointed at `PermissionMCP`, those calls now land here instead: the
/// host app shows a real allow/deny dialog and remembers "Always allow" choices.
@MainActor
enum AgentPermissionBroker {
  /// Full tool names the user chose to always allow, persisted so a connector isn't re-prompted on
  /// every call (and across launches). Keyed by the namespaced name the model used, e.g.
  /// `mcp__claude_ai_Craft__craft_read`.
  private static let alwaysAllowKey = "agent.permission.alwaysAllow"

  private static var alwaysAllowed: Set<String> {
    get { Set(UserDefaults.standard.stringArray(forKey: alwaysAllowKey) ?? []) }
    set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: alwaysAllowKey) }
  }

  /// Forget every remembered "Always allow" grant. Surfaced in Settings so a user can revoke the
  /// agent's standing permissions without editing defaults by hand.
  static func resetRememberedGrants() {
    UserDefaults.standard.removeObject(forKey: alwaysAllowKey)
  }

  /// Whether any tools are currently remembered - lets Settings hide the reset control when there's
  /// nothing to reset.
  static var hasRememberedGrants: Bool { !alwaysAllowed.isEmpty }

  /// Decide whether the agent may use `toolName` with `input`, returning the JSON-stringified
  /// `PermissionResult` the `--permission-prompt-tool` contract expects:
  ///   allow -> `{"behavior":"allow","updatedInput":<input>}`
  ///   deny  -> `{"behavior":"deny","message":<why>}`
  static func resolve(toolName: String, input: [String: Any]) -> String {
    guard !toolName.isEmpty else {
      return deny("Composer received a permission request with no tool name.")
    }
    if alwaysAllowed.contains(toolName) { return allow(input) }
    switch prompt(toolName: toolName, input: input) {
    case .allowOnce:
      return allow(input)
    case .allowAlways:
      alwaysAllowed.insert(toolName)
      return allow(input)
    case .deny:
      return deny("You declined to let the agent use \(friendlyName(toolName)).")
    }
  }

  // MARK: Dialog

  private enum Choice { case allowOnce, allowAlways, deny }

  private static func prompt(toolName: String, input: [String: Any]) -> Choice {
    // The agent is a background process; bring Composer forward so the dialog isn't lost behind it.
    NSApp.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "Allow the agent to use \(friendlyName(toolName))?"
    alert.informativeText = informative(toolName: toolName, input: input)
    alert.addButton(withTitle: "Allow Once")
    alert.addButton(withTitle: "Always Allow")
    alert.addButton(withTitle: "Deny")
    switch alert.runModal() {
    case .alertFirstButtonReturn: return .allowOnce
    case .alertSecondButtonReturn: return .allowAlways
    default: return .deny
    }
  }

  private static func informative(toolName: String, input: [String: Any]) -> String {
    var lines: [String] = []
    if let parts = mcpParts(toolName) {
      lines.append("\"\(parts.server)\" is a connected tool outside Composer's canvas. The agent wants to run its \(parts.tool) action.")
    } else {
      lines.append("The agent wants to run the built-in \(toolName) tool, which Composer doesn't grant by default.")
    }
    if let summary = inputSummary(input) {
      lines.append("\nRequest: \(summary)")
    }
    lines.append("\nAllow Once runs it just this time. Always Allow won't ask again for this tool.")
    return lines.joined(separator: "\n")
  }

  // MARK: Naming

  /// A readable label for a tool name. MCP tools arrive namespaced as `mcp__<server>__<tool>`;
  /// built-ins (Bash, Read, etc.) come through bare.
  private static func friendlyName(_ toolName: String) -> String {
    guard let parts = mcpParts(toolName) else { return toolName }
    return "\(parts.server) / \(parts.tool)"
  }

  /// Split `mcp__<server>__<tool>` into a display server + tool. Account connectors carry a
  /// `claude_ai_` prefix on the server segment; drop it and de-snake the rest so "claude_ai_Craft"
  /// reads as "Craft". Tool names may themselves contain underscores, so split on the first `__`.
  private static func mcpParts(_ toolName: String) -> (server: String, tool: String)? {
    let marker = "mcp__"
    guard toolName.hasPrefix(marker) else { return nil }
    let body = toolName.dropFirst(marker.count)
    guard let separator = body.range(of: "__") else { return nil }
    var server = String(body[..<separator.lowerBound])
    let tool = String(body[separator.upperBound...])
    if server.hasPrefix("claude_ai_") { server.removeFirst("claude_ai_".count) }
    server = server.replacingOccurrences(of: "_", with: " ")
    return (server.isEmpty ? "a connected app" : server, tool.isEmpty ? toolName : tool)
  }

  private static func inputSummary(_ input: [String: Any]) -> String? {
    guard !input.isEmpty,
          let data = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]),
          var text = String(data: data, encoding: .utf8) else { return nil }
    // Collapse whitespace so a multi-line argument stays compact in the dialog, then clamp.
    text = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    let limit = 280
    return text.count > limit ? String(text.prefix(limit)) + "..." : text
  }

  // MARK: PermissionResult encoding

  private static func allow(_ input: [String: Any]) -> String {
    encode(["behavior": "allow", "updatedInput": input])
  }

  private static func deny(_ message: String) -> String {
    encode(["behavior": "deny", "message": message])
  }

  private static func encode(_ object: [String: Any]) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: object),
          let text = String(data: data, encoding: .utf8) else {
      return #"{"behavior":"deny","message":"Composer could not encode the permission decision."}"#
    }
    return text
  }
}
