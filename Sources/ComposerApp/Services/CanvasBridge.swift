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

  /// Force any debounced board edit to disk right now. Call before the app actually exits —
  /// `DumpStore`'s autosave is debounced ~400ms, so an edit (including one from an external
  /// agent via the canvas API) made just before quit would otherwise never reach disk.
  func flush() {
    board?.flushSave()
  }

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
    guard let name = op["op"] as? String else { return fail("missing \"op\"") }

    if name == "capture" {
      guard let text = string(op["text"]),
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return fail("missing or empty \"text\"")
      }
      guard let id = board.captureExternalText(text) else { return fail("could not capture text") }
      return ok(["id": id.uuidString])
    }

    // Agent-driven mutations are tagged whoWrote = 2; user gestures stay human (1).
    board.nextAuthor = BoardViewModel.Author.agent
    defer { board.nextAuthor = BoardViewModel.Author.human }

    switch name {
    case "add_text":
      let text = string(op["text"]) ?? ""
      // Coordinates are optional: when omitted, the board auto-places without overlap.
      if let x = double(op["x"]), let y = double(op["y"]) {
        return ok(["id": board.insertText(text, at: CGPoint(x: x, y: y)).uuidString])
      }
      return ok(["id": board.insertTextAutoPlaced(text).uuidString])

    case "add_equation":
      guard let latex = string(op["latex"]).map(stripMathDelimiters),
            !latex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return fail("missing or empty \"latex\"")
      }
      // Coordinates are optional: when omitted, the board auto-places without overlap.
      if let x = double(op["x"]), let y = double(op["y"]) {
        return ok(["id": board.insertEquation(latex, at: CGPoint(x: x, y: y)).uuidString])
      }
      return ok(["id": board.insertEquationAutoPlaced(latex).uuidString])

    case "add_sticky":
      let title = string(op["title"])
      let text = string(op["text"]) ?? ""
      let point = placement(op, board: board, size: CardState.stickySize)
      return ok(["id": board.insertStructured(.sticky, title: title, text: text, at: point).uuidString])

    case "set_sticky":
      guard let id = uuid(op["id"]),
            board.setSticky(id, title: string(op["title"]) ?? "", body: string(op["text"]) ?? "")
      else { return fail("sticky note not found") }
      return ok()

    case "add_checklist":
      guard let rawItems = op["items"] as? [[String: Any]] else { return fail("missing \"items\"") }
      let items = rawItems.compactMap { value -> CardState.ChecklistItem? in
        guard let text = string(value["text"]) else { return nil }
        return CardState.ChecklistItem(text: text, isChecked: value["checked"] as? Bool ?? false)
      }
      let point = placement(op, board: board, size: CardState.checklistSize)
      return ok(["id": board.insertStructured(.checklist, checklist: items, at: point).uuidString])

    case "toggle_checklist_item":
      guard let id = uuid(op["id"]), let index = (op["index"] as? NSNumber)?.intValue else { return fail("bad \"id\"/\"index\"") }
      guard board.toggleChecklistItem(id, index: index) else { return fail("checklist not found or item index out of range") }
      return ok()

    case "set_checklist":
      guard let id = uuid(op["id"]), let rawItems = op["items"] as? [[String: Any]] else { return fail("bad \"id\"/\"items\"") }
      let items = rawItems.compactMap { value -> CardState.ChecklistItem? in
        guard let text = string(value["text"]) else { return nil }
        return CardState.ChecklistItem(text: text, isChecked: value["checked"] as? Bool ?? false)
      }
      guard board.setChecklist(id, items) else { return fail("checklist not found") }
      return ok()

    case "add_table":
      guard let columns = op["columns"] as? [String], let rows = op["rows"] as? [[String]] else { return fail("missing \"columns\"/\"rows\"") }
      let point = placement(op, board: board, size: CardState.tableSize)
      return ok(["id": board.insertStructured(.table, table: CardState.TableSpec(columns: columns, rows: rows), at: point).uuidString])

    case "set_table":
      guard let id = uuid(op["id"]), let columns = op["columns"] as? [String], let rows = op["rows"] as? [[String]] else { return fail("bad \"id\"/table") }
      guard board.setTable(id, CardState.TableSpec(columns: columns, rows: rows)) else { return fail("table not found") }
      return ok()

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
      let text = string(op["text"]) ?? ""
      if board.cards.first(where: { $0.id == id })?.elementKind == .equation {
        board.setText(id, stripMathDelimiters(text))
      } else {
        board.setText(id, text)
      }
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
  private func stripMathDelimiters(_ value: String) -> String {
    var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.hasPrefix("$$"), text.hasSuffix("$$"), text.count >= 4 {
      text.removeFirst(2)
      text.removeLast(2)
    } else if text.hasPrefix("$"), text.hasSuffix("$"), text.count >= 2 {
      text.removeFirst()
      text.removeLast()
    }
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
  }
  private func uuid(_ value: Any?) -> UUID? { (value as? String).flatMap(UUID.init(uuidString:)) }
  private func double(_ value: Any?) -> Double? {
    if let d = value as? Double { return d }
    if let n = value as? NSNumber { return n.doubleValue }
    if let i = value as? Int { return Double(i) }
    return nil
  }
  private func placement(_ op: [String: Any], board: BoardViewModel, size: CGSize) -> CGPoint {
    if let x = double(op["x"]), let y = double(op["y"]) { return CGPoint(x: x, y: y) }
    return board.autoPlacePoint(for: size)
  }
}
