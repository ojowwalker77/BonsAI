import CoreGraphics
import Foundation

/// The seam between the local API server (any thread) and the live board (main actor). The
/// running canvas registers itself here; reads return the current graph and mutations are applied
/// to the real `BoardViewModel`, so an external agent's changes appear instantly on screen.
@MainActor
final class CanvasBridge {
  static let shared = CanvasBridge()
  private weak var board: BoardViewModel?

  func register(_ board: BoardViewModel) { self.board = board }

  // MARK: Read

  func snapshot() -> CanvasGraph {
    guard let board else { return CanvasGraph(nodes: [], edges: [], readingOrder: []) }
    let nodes = board.cards.map { card in
      CanvasGraph.Node(
        id: card.id.uuidString,
        kind: card.elementKind.rawValue,
        text: board.plainText(for: card),
        x: card.x, y: card.y, w: card.w, h: card.h, z: card.z,
        group: card.groupID?.uuidString,
        locked: card.locked,
        archived: card.isArchived,
        whoWrote: card.author)
    }
    let edges = board.cards.compactMap { card -> CanvasGraph.Edge? in
      guard card.elementKind == .arrow || card.elementKind == .line,
            let from = card.startBindingID?.uuidString, let to = card.endBindingID?.uuidString
      else { return nil }
      return CanvasGraph.Edge(id: card.id.uuidString, from: from, to: to, kind: card.elementKind.rawValue)
    }
    return CanvasGraph(
      nodes: nodes, edges: edges,
      readingOrder: board.readingOrder().map { $0.id.uuidString })
  }

  // MARK: Mutate (dispatched from the server's POST /canvas)

  /// Applies one `{ "op": …, … }` mutation; returns a JSON-serializable result.
  func apply(_ op: [String: Any]) -> [String: Any] {
    guard let board else { return fail("no active canvas") }
    // Everything the agent applies is tagged as agent-authored (whoWrote = 2); direct user
    // gestures stay human (1). This is how the agent later tells its own work from the user's.
    board.nextAuthor = BoardViewModel.Author.agent
    defer { board.nextAuthor = BoardViewModel.Author.human }
    guard let name = op["op"] as? String else { return fail("missing \"op\"") }

    switch name {
    case "add_text":
      let text = string(op["text"]) ?? ""
      // Coordinates are optional: when omitted, the board auto-places without overlap.
      if let x = double(op["x"]), let y = double(op["y"]) {
        return ok(["id": board.insertText(text, at: CGPoint(x: x, y: y)).uuidString])
      }
      return ok(["id": board.insertTextAutoPlaced(text).uuidString])

    case "add_shape":
      guard let kind = string(op["kind"]).flatMap(CanvasElementKind.init(rawValue:)) else {
        return fail("bad \"kind\"")
      }
      let w = double(op["w"]) ?? 180, h = double(op["h"]) ?? 120
      let origin: CGPoint
      if let x = double(op["x"]), let y = double(op["y"]) {
        origin = CGPoint(x: x, y: y)
      } else {
        origin = board.autoPlacePoint(for: CGSize(width: w, height: h))
      }
      guard let id = board.addDrawnElement(kind, from: origin, to: CGPoint(x: origin.x + w, y: origin.y + h)) else {
        return fail("could not add \(kind.rawValue)")
      }
      return ok(["id": id.uuidString])

    case "create_diagram":
      guard let rawNodes = op["nodes"] as? [[String: Any]] else { return fail("missing \"nodes\"") }
      var droppedNodeKeys: [String] = []
      var seenNodeKeys = Set<String>()
      let specs = rawNodes.compactMap { node -> BoardViewModel.DiagramNodeSpec? in
        guard let key = string(node["key"]) ?? string(node["id"]), let text = string(node["text"]), !key.isEmpty else {
          if let key = string(node["key"]) ?? string(node["id"]), !key.isEmpty { droppedNodeKeys.append(key) }
          return nil
        }
        guard seenNodeKeys.insert(key).inserted else {
          droppedNodeKeys.append(key)
          return nil
        }
        // Only box shapes are valid nodes; anything else falls back to a rectangle.
        let shape = string(node["shape"]).flatMap(CanvasElementKind.init(rawValue:))
          .flatMap { [.rectangle, .ellipse, .diamond].contains($0) ? $0 : nil } ?? .rectangle
        return BoardViewModel.DiagramNodeSpec(key: key, text: text, shape: shape)
      }
      guard !specs.isEmpty else { return fail("no valid nodes (each needs a \"key\" and \"text\")") }
      let rawEdges = op["edges"] as? [[String: Any]] ?? []
      let edgeSpecs = rawEdges.compactMap { edge -> BoardViewModel.DiagramEdgeSpec? in
        guard let from = string(edge["from"]), let to = string(edge["to"]) else { return nil }
        return BoardViewModel.DiagramEdgeSpec(from: from, to: to, reason: string(edge["reason"]) ?? "")
      }
      let map = board.createDiagram(nodes: specs, edges: edgeSpecs, direction: layoutDirection(op["direction"]))
      let createdEdgeCount = edgeSpecs.filter { map[$0.from] != nil && map[$0.to] != nil && $0.from != $0.to }.count
      frameBoard(all: false)   // the new diagram is selected — frame exactly it
      return ok([
        "nodes": map.mapValues { $0.uuidString },
        "count": map.count,
        "requestedNodeCount": rawNodes.count,
        "createdNodeCount": map.count,
        "droppedNodeCount": rawNodes.count - map.count,
        "droppedNodeKeys": droppedNodeKeys,
        "requestedEdgeCount": rawEdges.count,
        "createdEdgeCount": createdEdgeCount,
        "droppedEdgeCount": rawEdges.count - createdEdgeCount,
      ])

    case "relayout":
      board.relayout(direction: layoutDirection(op["direction"]))
      frameBoard(all: true)    // tidy reflows everything — frame the whole board, not a stray selection
      return ok()

    case "update_text":
      guard let id = uuid(op["id"]) else { return fail("bad \"id\"") }
      board.setText(id, string(op["text"]) ?? "")
      return ok()

    case "move":
      guard let id = uuid(op["id"]), let card = board.cards.first(where: { $0.id == id }) else { return fail("bad \"id\"") }
      board.setFrame(id, CGRect(x: double(op["x"]) ?? card.x, y: double(op["y"]) ?? card.y,
                                width: card.w, height: card.h))
      return ok()

    case "resize":
      guard let id = uuid(op["id"]), let card = board.cards.first(where: { $0.id == id }) else { return fail("bad \"id\"") }
      board.setFrame(id, CGRect(x: card.x, y: card.y,
                                width: double(op["w"]) ?? card.w, height: double(op["h"]) ?? card.h))
      return ok()

    case "delete":
      guard let id = uuid(op["id"]) else { return fail("bad \"id\"") }
      board.delete(id)
      return ok()

    case "connect":
      guard let from = uuid(op["from"]), let to = uuid(op["to"]) else { return fail("bad \"from\"/\"to\"") }
      guard let id = board.connectCards(from: from, to: to, reason: string(op["reason"]) ?? "") else { return fail("could not connect") }
      return ok(["id": id.uuidString])

    case "set_archived":
      guard let id = uuid(op["id"]) else { return fail("bad \"id\"") }
      board.setArchived(id, (op["archived"] as? Bool) ?? true)
      return ok()

    case "supersede":
      guard let old = uuid(op["id"]) else { return fail("bad \"id\"") }
      guard let id = board.supersede(oldID: old, newText: string(op["text"]) ?? "", reason: string(op["reason"]) ?? "")
      else { return fail("could not supersede") }
      return ok(["id": id.uuidString])

    default:
      return fail("unknown op \"\(name)\"")
    }
  }

  // MARK: Helpers

  private func ok(_ extra: [String: Any] = [:]) -> [String: Any] {
    var result: [String: Any] = ["ok": true]
    result.merge(extra) { _, new in new }
    return result
  }
  private func fail(_ message: String) -> [String: Any] { ["ok": false, "error": message] }

  private func layoutDirection(_ value: Any?) -> LayoutDirection {
    (value as? String) == "right" ? .right : .down
  }

  /// Re-frame the viewport after a layout pass, so the agent's work lands in view. `all` forces
  /// the whole board (tidy); otherwise it honors the current selection (a freshly drawn diagram).
  private func frameBoard(all: Bool) {
    NotificationCenter.default.post(name: .composerZoomFit, object: nil,
                                    userInfo: all ? ["scope": "all"] : [:])
  }

  private func string(_ value: Any?) -> String? { value as? String }
  private func uuid(_ value: Any?) -> UUID? { (value as? String).flatMap(UUID.init(uuidString:)) }
  private func double(_ value: Any?) -> Double? {
    if let d = value as? Double { return d }
    if let n = value as? NSNumber { return n.doubleValue }
    if let i = value as? Int { return Double(i) }
    return nil
  }
}
