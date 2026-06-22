import Foundation

/// Minimal MCP (Model Context Protocol) server over the local HTTP transport, so a headless
/// `claude` agent — pointed at http://127.0.0.1:<port>/mcp — can read and drive the canvas with
/// real tools. Stateless JSON-RPC: each POST is one request, answered with one JSON response.
/// Tools surface to the agent as `mcp__canvas__<name>`.
@MainActor
enum CanvasMCP {
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
        "serverInfo": ["name": "composer-canvas", "version": "0.1.0"],
      ])

    case "ping":
      return reply(id, [:])

    case "tools/list":
      return reply(id, ["tools": toolSpecs])

    case "tools/call":
      let params = message["params"] as? [String: Any] ?? [:]
      return reply(id, callTool(params["name"] as? String ?? "",
                                arguments: params["arguments"] as? [String: Any] ?? [:]))

    case let m where m.hasPrefix("notifications/"):
      return nil

    default:
      return errorReply(id, code: -32601, message: "method not found: \(method)")
    }
  }

  // MARK: Tools

  /// Tool name → the `CanvasBridge.apply` op it maps to (get_canvas is handled directly).
  private static let opForTool: [String: String] = [
    "draw_diagram": "create_diagram", "tidy": "relayout",
    "add_text": "add_text", "add_shape": "add_shape", "set_text": "update_text",
    "move_node": "move", "resize_node": "resize", "delete_node": "delete", "connect": "connect",
    "archive": "set_archived", "supersede": "supersede",
  ]

  private static func callTool(_ name: String, arguments: [String: Any]) -> [String: Any] {
    if name == "get_canvas" {
      let graph = CanvasBridge.shared.snapshot()
      do {
        let data = try JSONEncoder().encode(graph)
        guard let text = String(data: data, encoding: .utf8) else {
          return content("Composer encoded the canvas graph into non-UTF-8 data.", isError: true)
        }
        return content(text)
      } catch {
        return content(UserFacingError.message(for: error, while: "Encoding the canvas graph"), isError: true)
      }
    }
    guard let op = opForTool[name] else {
      return content("unknown tool: \(name)", isError: true)
    }
    var payload = arguments
    payload["op"] = op
    let result = CanvasBridge.shared.apply(payload)
    do {
      let data = try JSONSerialization.data(withJSONObject: result)
      guard let text = String(data: data, encoding: .utf8) else {
        return content("Composer encoded the canvas-tool result into non-UTF-8 data.", isError: true)
      }
      return content(text, isError: (result["ok"] as? Bool) == false)
    } catch {
      return content(UserFacingError.message(for: error, while: "Encoding the canvas-tool result"), isError: true)
    }
  }

  private static func content(_ text: String, isError: Bool = false) -> [String: Any] {
    ["content": [["type": "text", "text": text]], "isError": isError]
  }

  private static let toolSpecs: [[String: Any]] = [
    tool("get_canvas", "Read the entire board as a graph: nodes (cards/shapes with id, kind, text, x/y/w/h, and whoWrote: 1 = the human wrote/edited it, 2 = you drew it, 0 = unknown), edges (bound arrows/lines), and reading order. Positions are auto-managed — prefer draw_diagram/tidy over moving cards by hand. Re-read before acting on a board you've touched before; nodes with whoWrote=1 are what the human added or changed.", [:], []),
    tool("draw_diagram",
         "PREFERRED for any structure (architecture, flow, tree, comparison): declare the nodes and how they connect in ONE call and the board lays them out cleanly — layered, evenly spaced, no overlaps, few crossings. Each node is drawn as a LABELED BOX so arrows land on its edge; keep each label a short title or phrase (not a paragraph). Do NOT invent x/y yourself; you can't track overlaps in your head and it comes out tangled. Returns a map of your node keys → created ids.",
         ["nodes": ["type": "array", "description": "The boxes to create.",
                    "items": ["type": "object",
                              "properties": ["key": str("A short unique handle you choose (e.g. \"api\"), referenced by edges"),
                                             "text": str("Short label — a name or phrase that fits in a box"),
                                             "shape": str("Box shape: \"rectangle\" (default), \"ellipse\" (stores/data), or \"diamond\" (decisions)")],
                              "required": ["key", "text"]]],
          "edges": ["type": "array", "description": "Directed links between nodes by key; each becomes a labeled arrow.",
                    "items": ["type": "object",
                              "properties": ["from": str("Source node key"), "to": str("Target node key"),
                                             "reason": str("Optional label — how/why they relate")],
                              "required": ["from", "to"]]],
          "direction": str("Flow: \"down\" (top-to-bottom, for hierarchies/architecture — default) or \"right\" (left-to-right, for pipelines/flows)")],
         ["nodes"]),
    tool("tidy",
         "Re-flow everything currently on the board into a clean layered layout (no overlaps, aligned ranks, edges following the flow). Use after adding/changing cards incrementally, or whenever the board looks messy.",
         ["direction": str("\"down\" (default) or \"right\"")], []),
    tool("add_text", "Add ONE text card. For several related cards use draw_diagram instead. Omit x/y to let the board place it without overlap; pass them only for a deliberate spot. Text may contain @-connector tokens.",
         ["text": str("Card text"), "x": num("Optional board x"), "y": num("Optional board y")], ["text"]),
    tool("add_shape", "Add a shape sized by a bounding box. Omit x/y to auto-place.",
         ["kind": str("rectangle | ellipse | diamond | line | arrow"),
          "x": num("Optional top-left x"), "y": num("Optional top-left y"), "w": num("Width"), "h": num("Height")],
         ["kind", "w", "h"]),
    tool("set_text", "Replace a node's text by id.",
         ["id": str("Node id"), "text": str("New text")], ["id", "text"]),
    tool("move_node", "Move a node to a board point.",
         ["id": str("Node id"), "x": num("New x"), "y": num("New y")], ["id", "x", "y"]),
    tool("resize_node", "Resize a node.",
         ["id": str("Node id"), "w": num("New width"), "h": num("New height")], ["id", "w", "h"]),
    tool("delete_node", "Delete a node by id.", ["id": str("Node id")], ["id"]),
    tool("connect", "Draw an arrow from one node to another, optionally labeled with the reason.",
         ["from": str("Source node id"), "to": str("Target node id"), "reason": str("Why they're linked (becomes the arrow label)")],
         ["from", "to"]),
    tool("archive", "Fade a node as superseded (or revive it) without deleting it — keeps lineage.",
         ["id": str("Node id"), "archived": ["type": "boolean", "description": "true to supersede, false to revive"]], ["id"]),
    tool("supersede", "Evolve an idea: fade the old card, add the new one below it, and link them with the reason. Use this whenever an approach changes.",
         ["id": str("Old node id"), "text": str("The new idea's text"), "reason": str("Why it changed")],
         ["id", "text", "reason"]),
  ]

  private static func tool(_ name: String, _ description: String,
                           _ properties: [String: Any], _ required: [String]) -> [String: Any] {
    ["name": name, "description": description,
     "inputSchema": ["type": "object", "properties": properties, "required": required]]
  }
  private static func str(_ description: String) -> [String: Any] { ["type": "string", "description": description] }
  private static func num(_ description: String) -> [String: Any] { ["type": "number", "description": description] }

  // MARK: JSON-RPC envelope

  private static func reply(_ id: Any?, _ result: [String: Any]) -> [String: Any] {
    ["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result]
  }
  private static func errorReply(_ id: Any?, code: Int, message: String) -> [String: Any] {
    ["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]]
  }
}
