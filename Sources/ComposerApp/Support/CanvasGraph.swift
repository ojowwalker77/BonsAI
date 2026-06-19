import Foundation

/// A serializable, agent-readable view of the whole board: cards as nodes, bound arrows/lines as
/// edges, plus spatial reading order. This is the contract the local API (and thus the CLI / MCP
/// server) exposes so an external agent can read — and manipulate — the canvas live.
struct CanvasGraph: Codable {
  struct Node: Codable {
    var id: String
    /// text, rectangle, ellipse, diamond, line, arrow, freehand, image
    var kind: String
    /// Serialized plain text with mention tokens preserved (e.g. "@github:…"). Empty for shapes.
    var text: String
    var x: Double
    var y: Double
    var w: Double
    var h: Double
    var z: Int
    var group: String?
    var locked: Bool
    /// A superseded idea, kept for lineage — faded on the board.
    var archived: Bool
    /// Who last authored this node: 1 = human, 2 = agent, 0 = unknown. Lets the agent tell its own
    /// work from what the human wrote or changed.
    var whoWrote: Int
  }

  /// A directional relationship between two nodes, realized by a bound arrow/line node.
  struct Edge: Codable {
    var id: String
    var from: String
    var to: String
    var kind: String
  }

  var nodes: [Node]
  var edges: [Edge]
  /// Node ids top→bottom, then left→right — the order Compile/Copy read the board in.
  var readingOrder: [String]
}
