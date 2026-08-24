import CoreGraphics
import Foundation

/// Which end of a line/arrow is being addressed. Kept independent of view geometry so drawing,
/// endpoint handles, programmatic connections, persistence refresh, and tests all cross the same
/// connector seam.
enum ConnectorEndpoint: CaseIterable, Equatable {
  case start
  case end
}

/// Pure connector geometry and binding policy.
///
/// The interface accepts and returns `CardState` values; callers never need to know how endpoints
/// are normalized into a padded card frame, how a binding anchor is chosen, or how arrowhead space
/// differs from a plain line. That keeps every connector mutation on one testable in-process seam.
enum ConnectorGeometry {
  struct Endpoints: Equatable {
    var start: CGPoint
    var end: CGPoint

    subscript(endpoint: ConnectorEndpoint) -> CGPoint {
      get { endpoint == .start ? start : end }
      set {
        switch endpoint {
        case .start: start = newValue
        case .end: end = newValue
        }
      }
    }
  }

  static func isConnector(_ card: CardState) -> Bool {
    card.elementKind == .line || card.elementKind == .arrow
  }

  /// Resolve a connector's stored normalized points into board space.
  static func endpoints(of card: CardState) -> Endpoints? {
    guard isConnector(card) else { return nil }
    let points = card.points ?? CardState.defaultLinePoints()
    let start = points.first?.cgPoint ?? CGPoint(x: 0.06, y: 0.88)
    let end = points.dropFirst().first?.cgPoint ?? CGPoint(x: 0.94, y: 0.12)
    return Endpoints(
      start: CGPoint(x: card.x + start.x * card.w, y: card.y + start.y * card.h),
      end: CGPoint(x: card.x + end.x * card.w, y: card.y + end.y * card.h))
  }

  /// The target a drawn/dragged endpoint would bind to. Exposed only as an id so previews can use
  /// the exact commit policy without learning the target-scoring implementation.
  static func bindingTarget(at point: CGPoint,
                            among cards: [CardState],
                            excluding: Set<UUID>) -> UUID? {
    nearestTarget(to: point, among: cards, excluding: excluding)?.id
  }

  /// Bind both ends of a freshly drawn connector wherever they landed. The two ends cannot bind to
  /// the same card, matching the existing arrow behavior.
  static func finalizingDrawn(_ connector: CardState, among cards: [CardState]) -> CardState? {
    guard let resolved = endpoints(of: connector) else { return nil }
    var result = connector
    var excluded: Set<UUID> = [result.id]
    if let target = nearestTarget(to: resolved.start, among: cards, excluding: excluded) {
      result.startBindingID = target.id
      result.startBindingAnchor = bindingAnchor(on: target.frame, drawn: resolved.start, otherEnd: resolved.end)
      excluded.insert(target.id)
    }
    if let target = nearestTarget(to: resolved.end, among: cards, excluding: excluded) {
      result.endBindingID = target.id
      result.endBindingAnchor = bindingAnchor(on: target.frame, drawn: resolved.end, otherEnd: resolved.start)
    }
    guard result.startBindingID != nil || result.endBindingID != nil else { return result }
    return refreshed(result, among: replacing(result, in: cards))
  }

  /// Return a connector with exactly one endpoint moved. The opposite board-space endpoint and its
  /// binding stay intact; the moved endpoint detaches, then rebinds if it lands on an eligible card.
  static func moving(_ endpoint: ConnectorEndpoint,
                     of connector: CardState,
                     to boardPoint: CGPoint,
                     among cards: [CardState]) -> CardState? {
    guard var resolved = endpoints(of: connector) else { return nil }
    var anchoredConnector = connector
    let opposite = endpoint.opposite
    // Programmatic connectors intentionally start anchor-less so they route center-to-center. Once
    // a user edits one endpoint, freeze the untouched end at its current boundary spot; otherwise
    // changing the segment direction would visibly slide both ends during a one-handle gesture.
    if bindingAnchor(opposite, on: anchoredConnector) == nil,
       let targetID = bindingID(opposite, on: anchoredConnector),
       let target = cards.first(where: { $0.id == targetID }) {
      let frozen = bindingAnchor(
        on: target.frame,
        drawn: resolved[opposite],
        otherEnd: boardPoint)
      setBinding(targetID, anchor: frozen, endpoint: opposite, on: &anchoredConnector)
    }
    resolved[endpoint] = boardPoint
    guard var result = rebased(anchoredConnector, endpoints: resolved) else { return nil }
    setBinding(nil, anchor: nil, endpoint: endpoint, on: &result)

    var excluded: Set<UUID> = [result.id]
    if let otherID = bindingID(endpoint.opposite, on: result) { excluded.insert(otherID) }
    if let target = nearestTarget(to: boardPoint, among: cards, excluding: excluded) {
      setBinding(
        target.id,
        anchor: bindingAnchor(on: target.frame, drawn: boardPoint, otherEnd: resolved[endpoint.opposite]),
        endpoint: endpoint,
        on: &result)
    }
    return refreshed(result, among: replacing(result, in: cards))
  }

  /// Create a connector bound between two cards. Anchor-less bindings deliberately use boundary-ray
  /// routing: arrow tips reserve arrowhead clearance while plain lines land symmetrically.
  static func makeBoundConnector(kind: CanvasElementKind,
                                 text: String,
                                 source: CardState,
                                 target: CardState,
                                 z: Int,
                                 author: Int?,
                                 tint: Int? = nil) -> CardState? {
    guard kind == .line || kind == .arrow, source.id != target.id else { return nil }
    let card = CardState(
      kind: kind,
      text: text,
      x: 0,
      y: 0,
      w: Double(CardState.lineSize.width),
      h: Double(CardState.lineSize.height),
      z: z,
      startBindingID: source.id,
      endBindingID: target.id,
      whoWrote: author,
      tint: tint)
    return refreshed(card, among: [source, target, card])
  }

  /// Re-resolve every bound line/arrow against the current card frames, dropping references whose
  /// targets no longer exist. This is shared by live mutations and read-only rendering snapshots.
  static func refreshing(in cards: [CardState]) -> [CardState] {
    var result = cards
    let existing = Set(cards.map(\.id))
    for index in result.indices where isConnector(result[index]) {
      if let start = result[index].startBindingID, !existing.contains(start) {
        result[index].startBindingID = nil
        result[index].startBindingAnchor = nil
      }
      if let end = result[index].endBindingID, !existing.contains(end) {
        result[index].endBindingID = nil
        result[index].endBindingAnchor = nil
      }
      if result[index].startBindingID != nil || result[index].endBindingID != nil {
        result[index] = refreshed(result[index], among: result) ?? result[index]
      }
    }
    return result
  }

  // MARK: Implementation

  private static func refreshed(_ connector: CardState, among cards: [CardState]) -> CardState? {
    guard var resolved = endpoints(of: connector) else { return nil }
    let source = connector.startBindingID.flatMap { id in cards.first { $0.id == id } }
    let target = connector.endBindingID.flatMap { id in cards.first { $0.id == id } }
    let rawStart = source.map(center(of:)) ?? resolved.start
    let rawEnd = target.map(center(of:)) ?? resolved.end

    if let source {
      resolved.start = connector.startBindingAnchor.map { anchoredPoint($0, in: source.frame) }
        ?? boundaryPoint(of: source.frame, toward: rawEnd, margin: 1)
    }
    if let target {
      let margin: CGFloat = connector.elementKind == .arrow ? 7 : 1
      resolved.end = connector.endBindingAnchor.map { anchoredPoint($0, in: target.frame) }
        ?? boundaryPoint(of: target.frame, toward: rawStart, margin: margin)
    }
    return rebased(connector, endpoints: resolved)
  }

  private static func rebased(_ connector: CardState, endpoints: Endpoints?) -> CardState? {
    guard let endpoints else { return nil }
    var result = connector
    let padding: CGFloat = 18
    var minX = min(endpoints.start.x, endpoints.end.x) - padding
    var minY = min(endpoints.start.y, endpoints.end.y) - padding
    var maxX = max(endpoints.start.x, endpoints.end.x) + padding
    var maxY = max(endpoints.start.y, endpoints.end.y) + padding
    let minSize = connector.minimumSize
    if maxX - minX < minSize.width {
      let extra = (minSize.width - (maxX - minX)) / 2
      minX -= extra
      maxX += extra
    }
    if maxY - minY < minSize.height {
      let extra = (minSize.height - (maxY - minY)) / 2
      minY -= extra
      maxY += extra
    }
    let frame = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    result.frame = frame
    result.points = [
      CanvasPoint(
        x: Double((endpoints.start.x - frame.minX) / frame.width),
        y: Double((endpoints.start.y - frame.minY) / frame.height)),
      CanvasPoint(
        x: Double((endpoints.end.x - frame.minX) / frame.width),
        y: Double((endpoints.end.y - frame.minY) / frame.height)),
    ]
    return result
  }

  private static func nearestTarget(to point: CGPoint,
                                    among cards: [CardState],
                                    excluding excluded: Set<UUID>) -> CardState? {
    let edgeSlop: CGFloat = 16
    return cards
      .filter { card in
        !excluded.contains(card.id) &&
        !card.locked &&
        !isConnector(card) &&
        card.elementKind != .freehand
      }
      .compactMap { card -> (card: CardState, rectDistance: CGFloat, centerDistance: CGFloat)? in
        let rect = card.frame
        let dx = max(rect.minX - point.x, point.x - rect.maxX, 0)
        let dy = max(rect.minY - point.y, point.y - rect.maxY, 0)
        let rectDistance = hypot(dx, dy)
        guard rectDistance <= edgeSlop else { return nil }
        let center = center(of: card)
        return (card, rectDistance, hypot(center.x - point.x, center.y - point.y))
      }
      .min(by: { lhs, rhs in
        lhs.rectDistance != rhs.rectDistance
          ? lhs.rectDistance < rhs.rectDistance
          : lhs.centerDistance < rhs.centerDistance
      })?
      .card
  }

  private static func bindingAnchor(on frame: CGRect, drawn: CGPoint, otherEnd: CGPoint) -> CanvasPoint {
    let point: CGPoint
    if frame.contains(drawn) {
      point = segmentEntry(into: frame, from: otherEnd, to: drawn) ?? drawn
    } else {
      point = CGPoint(
        x: min(max(drawn.x, frame.minX), frame.maxX),
        y: min(max(drawn.y, frame.minY), frame.maxY))
    }
    return CanvasPoint(
      x: Double((point.x - frame.minX) / max(frame.width, 1)),
      y: Double((point.y - frame.minY) / max(frame.height, 1)))
  }

  private static func segmentEntry(into rect: CGRect, from: CGPoint, to: CGPoint) -> CGPoint? {
    guard !rect.contains(from) else { return nil }
    let dx = to.x - from.x
    let dy = to.y - from.y
    var tMin: CGFloat = 0
    var tMax: CGFloat = 1
    for (p, q) in [(-dx, from.x - rect.minX), (dx, rect.maxX - from.x),
                   (-dy, from.y - rect.minY), (dy, rect.maxY - from.y)] {
      if p == 0 {
        if q < 0 { return nil }
        continue
      }
      let t = q / p
      if p < 0 { tMin = max(tMin, t) } else { tMax = min(tMax, t) }
      if tMin > tMax { return nil }
    }
    return CGPoint(x: from.x + dx * tMin, y: from.y + dy * tMin)
  }

  private static func boundaryPoint(of rect: CGRect, toward target: CGPoint, margin: CGFloat) -> CGPoint {
    let center = CGPoint(x: rect.midX, y: rect.midY)
    let dx = target.x - center.x
    let dy = target.y - center.y
    guard dx != 0 || dy != 0 else { return center }
    let tx = dx != 0 ? (rect.width / 2) / abs(dx) : .greatestFiniteMagnitude
    let ty = dy != 0 ? (rect.height / 2) / abs(dy) : .greatestFiniteMagnitude
    let t = min(tx, ty)
    let length = hypot(dx, dy)
    return CGPoint(
      x: center.x + dx * t + dx / length * margin,
      y: center.y + dy * t + dy / length * margin)
  }

  private static func anchoredPoint(_ anchor: CanvasPoint, in frame: CGRect) -> CGPoint {
    CGPoint(
      x: frame.minX + CGFloat(anchor.x) * frame.width,
      y: frame.minY + CGFloat(anchor.y) * frame.height)
  }

  private static func center(of card: CardState) -> CGPoint {
    CGPoint(x: card.frame.midX, y: card.frame.midY)
  }

  private static func replacing(_ connector: CardState, in cards: [CardState]) -> [CardState] {
    var result = cards.filter { $0.id != connector.id }
    result.append(connector)
    return result
  }

  private static func bindingID(_ endpoint: ConnectorEndpoint, on card: CardState) -> UUID? {
    endpoint == .start ? card.startBindingID : card.endBindingID
  }

  private static func bindingAnchor(_ endpoint: ConnectorEndpoint, on card: CardState) -> CanvasPoint? {
    endpoint == .start ? card.startBindingAnchor : card.endBindingAnchor
  }

  private static func setBinding(_ id: UUID?,
                                 anchor: CanvasPoint?,
                                 endpoint: ConnectorEndpoint,
                                 on card: inout CardState) {
    switch endpoint {
    case .start:
      card.startBindingID = id
      card.startBindingAnchor = anchor
    case .end:
      card.endBindingID = id
      card.endBindingAnchor = anchor
    }
  }
}

private extension ConnectorEndpoint {
  var opposite: ConnectorEndpoint { self == .start ? .end : .start }
}
