import CoreGraphics
import Foundation

/// Per-kind element geometry in board space: the element's real extent and whether a point hits
/// what is actually drawn.
///
/// Hit testing used to be each card's bounding box, so the padded frame around a diagonal arrow,
/// the empty corners of an ellipse or diamond, and the air around a freehand stroke all swallowed
/// clicks meant for whatever sat underneath. Every pointer decision now comes from here.
enum ElementGeometry {
  /// Screen-space slop for the two kinds of target. Fills are generous enough to grab an edge;
  /// strokes are thin, so they get a wider band (Excalidraw uses ~10px for lines).
  struct Slop: Equatable {
    var fill: CGFloat
    var stroke: CGFloat

    static let pointer = Slop(fill: 4, stroke: 9)

    /// The same slop converted to board units at `scale`.
    func board(at scale: CGFloat) -> Slop {
      let s = max(scale, 0.01)
      return Slop(fill: fill / s, stroke: stroke / s)
    }
  }

  /// Half the rendered stroke of lines, arrows, freehand and pen paths (3pt).
  static let strokeHalfWidth: CGFloat = 1.5

  /// The element's real extent in board space. Connectors report their segment, not the padded
  /// frame they are stored in; strokes report their points. Everything else is its frame.
  static func bounds(of card: CardState) -> CGRect {
    switch card.elementKind {
    case .line, .arrow:
      guard let ends = ConnectorGeometry.endpoints(of: card) else { return card.frame }
      return rect(spanning: [ends.start, ends.end])
    case .freehand:
      let points = strokePoints(of: card)
      return points.isEmpty ? card.frame : rect(spanning: points)
    case .vectorPath:
      guard let path = vectorPath(of: card) else { return card.frame }
      let box = path.boundingBoxOfPath
      return box.isNull ? card.frame : box
    default:
      return card.frame
    }
  }

  /// Whether `point` (board space) lands on what this element draws.
  static func hits(_ card: CardState, at point: CGPoint, slop: Slop) -> Bool {
    let frame = card.frame
    // Cheap reject first: nothing an element draws reaches past its frame by more than the slop.
    guard frame.insetBy(dx: -max(slop.fill, slop.stroke) - 24, dy: -max(slop.fill, slop.stroke) - 24)
      .contains(point) else { return false }

    switch card.elementKind {
    case .rectangle:
      let inset = ShapeLabelGeometry.shapePathInset
      return frame.insetBy(dx: inset - slop.fill, dy: inset - slop.fill).contains(point)

    case .ellipse:
      let inset = ShapeLabelGeometry.shapePathInset
      let rx = frame.width / 2 - inset + slop.fill
      let ry = frame.height / 2 - inset + slop.fill
      guard rx > 0, ry > 0 else { return false }
      let dx = (point.x - frame.midX) / rx
      let dy = (point.y - frame.midY) / ry
      return dx * dx + dy * dy <= 1

    case .diamond:
      let inset = ShapeLabelGeometry.shapePathInset
      let rx = frame.width / 2 - inset + slop.fill
      let ry = frame.height / 2 - inset + slop.fill
      guard rx > 0, ry > 0 else { return false }
      return abs(point.x - frame.midX) / rx + abs(point.y - frame.midY) / ry <= 1

    case .line, .arrow:
      guard let ends = ConnectorGeometry.endpoints(of: card) else { return false }
      if distance(from: point, toSegment: ends.start, ends.end) <= slop.stroke + strokeHalfWidth {
        return true
      }
      return connectorLabelRect(of: card, endpoints: ends)?.contains(point) ?? false

    case .freehand:
      let points = strokePoints(of: card)
      guard let first = points.first else { return false }
      if points.count == 1 {
        return hypot(point.x - first.x, point.y - first.y) <= slop.stroke + strokeHalfWidth
      }
      return distance(from: point, toPolyline: points) <= slop.stroke + strokeHalfWidth

    case .vectorPath:
      guard let path = vectorPath(of: card) else { return false }
      if card.vectorPath?.isClosed == true, path.contains(point) { return true }
      let band = path.copy(
        strokingWithWidth: (slop.stroke + strokeHalfWidth) * 2,
        lineCap: .round, lineJoin: .round, miterLimit: 10)
      return band.contains(point)

    case .text, .image, .equation, .graph, .sticky, .checklist, .table:
      return frame.insetBy(dx: -slop.fill, dy: -slop.fill).contains(point)
    }
  }

  // MARK: Geometry helpers

  /// Freehand points resolved from the element's normalized 0…1 frame into board space.
  static func strokePoints(of card: CardState) -> [CGPoint] {
    let points = card.points ?? CardState.defaultFreehandPoints()
    return points.map { CGPoint(x: card.x + $0.x * card.w, y: card.y + $0.y * card.h) }
  }

  static func vectorPath(of card: CardState) -> CGPath? {
    guard let spec = card.vectorPath else { return nil }
    return VectorPathGeometry.path(for: spec, in: card.frame)
  }

  /// The floating label pill drawn at a connector's centre, estimated from its text. Labels are a
  /// grab target too: a label is the obvious thing to click on a labelled arrow.
  private static func connectorLabelRect(of card: CardState,
                                         endpoints: ConnectorGeometry.Endpoints) -> CGRect? {
    let label = card.text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !label.isEmpty else { return nil }
    let width = min(CGFloat(label.count) * 7 + 24, 240)
    let height: CGFloat = 28
    return CGRect(x: card.frame.midX - width / 2, y: card.frame.midY - height / 2,
                  width: width, height: height)
  }

  static func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
    let dx = b.x - a.x, dy = b.y - a.y
    let lengthSquared = dx * dx + dy * dy
    guard lengthSquared > 0 else { return hypot(p.x - a.x, p.y - a.y) }
    let t = min(max(((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared, 0), 1)
    return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
  }

  static func distance(from p: CGPoint, toPolyline points: [CGPoint]) -> CGFloat {
    guard points.count > 1 else {
      return points.first.map { hypot(p.x - $0.x, p.y - $0.y) } ?? .greatestFiniteMagnitude
    }
    var best = CGFloat.greatestFiniteMagnitude
    for index in 1..<points.count {
      best = min(best, distance(from: p, toSegment: points[index - 1], points[index]))
    }
    return best
  }

  static func rect(spanning points: [CGPoint]) -> CGRect {
    guard let first = points.first else { return .null }
    var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
    for point in points.dropFirst() {
      minX = min(minX, point.x); maxX = max(maxX, point.x)
      minY = min(minY, point.y); maxY = max(maxY, point.y)
    }
    return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
  }
}

/// Topmost-first hit testing over a whole board, and marquee containment.
enum CanvasHitTester {
  /// Cards in paint order, topmost first: higher `z` paints above, and among equal `z` the later
  /// array entry wins (SwiftUI's ZStack order for equal `zIndex`).
  static func paintOrderTopmostFirst(_ cards: [CardState]) -> [CardState] {
    cards.enumerated()
      .sorted { lhs, rhs in
        lhs.element.z != rhs.element.z ? lhs.element.z > rhs.element.z : lhs.offset > rhs.offset
      }
      .map(\.element)
  }

  /// The topmost element whose drawn geometry is under `point` (board space).
  static func topmost(at point: CGPoint,
                      in cards: [CardState],
                      slop: ElementGeometry.Slop,
                      where include: (CardState) -> Bool = { _ in true }) -> CardState? {
    paintOrderTopmostFirst(cards).first { card in
      include(card) && ElementGeometry.hits(card, at: point, slop: slop)
    }
  }

  /// Elements lying entirely inside `rect` (board space) — Excalidraw's marquee rule, so sweeping
  /// across part of a large background shape never grabs it.
  static func contained(in rect: CGRect, cards: [CardState]) -> [CardState] {
    cards.filter { card in
      let bounds = ElementGeometry.bounds(of: card)
      return bounds.minX >= rect.minX && bounds.maxX <= rect.maxX &&
        bounds.minY >= rect.minY && bounds.maxY <= rect.maxY
    }
  }

  /// The tight union of the cards' real extents.
  static func unionBounds(of cards: [CardState]) -> CGRect? {
    guard let first = cards.first else { return nil }
    return cards.dropFirst().reduce(ElementGeometry.bounds(of: first)) {
      $0.union(ElementGeometry.bounds(of: $1))
    }
  }
}
