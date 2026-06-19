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
        text: board.interaction(for: card.id).plainText,
        x: card.x, y: card.y, w: card.w, h: card.h, z: card.z,
        group: card.groupID?.uuidString,
        locked: card.locked,
        archived: card.isArchived)
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
    guard let name = op["op"] as? String else { return fail("missing \"op\"") }

    switch name {
    case "add_text":
      let id = board.insertText(string(op["text"]) ?? "",
                                at: CGPoint(x: double(op["x"]) ?? 0, y: double(op["y"]) ?? 0))
      return ok(["id": id.uuidString])

    case "add_shape":
      guard let kind = string(op["kind"]).flatMap(CanvasElementKind.init(rawValue:)) else {
        return fail("bad \"kind\"")
      }
      let x = double(op["x"]) ?? 0, y = double(op["y"]) ?? 0
      let w = double(op["w"]) ?? 180, h = double(op["h"]) ?? 120
      guard let id = board.addDrawnElement(kind, from: CGPoint(x: x, y: y), to: CGPoint(x: x + w, y: y + h)) else {
        return fail("could not add \(kind.rawValue)")
      }
      return ok(["id": id.uuidString])

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

  private func string(_ value: Any?) -> String? { value as? String }
  private func uuid(_ value: Any?) -> UUID? { (value as? String).flatMap(UUID.init(uuidString:)) }
  private func double(_ value: Any?) -> Double? {
    if let d = value as? Double { return d }
    if let n = value as? NSNumber { return n.doubleValue }
    if let i = value as? Int { return Double(i) }
    return nil
  }
}
