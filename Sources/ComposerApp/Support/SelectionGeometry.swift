import CoreGraphics
import Foundation

/// One of the eight grab points on a selection box.
enum SelectionHandle: CaseIterable, Hashable {
  case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

  static let corners: [SelectionHandle] = [.topLeft, .topRight, .bottomRight, .bottomLeft]
  static let sides: [SelectionHandle] = [.top, .right, .bottom, .left]

  var isCorner: Bool { Self.corners.contains(self) }

  /// −1 drags the min-X edge, +1 the max-X edge, 0 leaves X alone.
  var horizontal: Int {
    switch self {
    case .topLeft, .left, .bottomLeft: -1
    case .topRight, .right, .bottomRight: 1
    case .top, .bottom: 0
    }
  }

  /// −1 drags the min-Y edge, +1 the max-Y edge, 0 leaves Y alone.
  var vertical: Int {
    switch self {
    case .topLeft, .top, .topRight: -1
    case .bottomLeft, .bottom, .bottomRight: 1
    case .left, .right: 0
    }
  }

  func point(on rect: CGRect) -> CGPoint {
    let x = horizontal < 0 ? rect.minX : (horizontal > 0 ? rect.maxX : rect.midX)
    let y = vertical < 0 ? rect.minY : (vertical > 0 ? rect.maxY : rect.midY)
    return CGPoint(x: x, y: y)
  }
}

/// What the pointer grabbed on the selection chrome.
enum SelectionChromeHit: Equatable {
  case handle(SelectionHandle)
  case endpoint(UUID, ConnectorEndpoint)
  case quickConnect(UUID, ConnectorDirection)
}

/// The selection chrome — box, handles, connector endpoints, quick-connect ports — laid out ONCE
/// in viewport space. The overlay draws exactly this and the pointer controller hit-tests exactly
/// this, so what you see is always what you can grab (per-card SwiftUI handles used to drift from
/// their hit targets and fight the card's own move gesture).
struct SelectionChrome: Equatable {
  struct Endpoint: Equatable {
    var connectorID: UUID
    var endpoint: ConnectorEndpoint
    var point: CGPoint
  }

  struct Port: Equatable {
    var sourceID: UUID
    var direction: ConnectorDirection
    var point: CGPoint
  }

  /// Px the box sits outside the content, so it frames the element instead of crowding it.
  static let gap: CGFloat = 5
  static let handleHitRadius: CGFloat = 10
  static let edgeHitSlop: CGFloat = 5
  static let endpointHitRadius: CGFloat = 11
  static let portHitRadius: CGFloat = 11
  /// The delete button floats this far above the top-trailing handle.
  static let deleteLift: CGFloat = 22

  /// Each selected element's own outline (viewport), drawn thin when several are selected.
  var elementOutlines: [CGRect] = []
  /// The selection box (viewport, already outset by `gap`). Nil for a lone connector, which is
  /// manipulated by its endpoints instead.
  var box: CGRect?
  var boxCornerRadius: CGFloat = 6
  /// Several elements: the box is the group's dashed frame rather than one element's ring.
  var isMultiple = false
  /// Live resize handles. Corners draw as squares; sides are invisible bands along the box edge
  /// — except a lone text element, whose left/right handles draw as the wrap-width pill.
  var handles: [SelectionHandle] = []
  var sidesAreTextWidth = false
  var endpoints: [Endpoint] = []
  var ports: [Port] = []
  var deleteCenter: CGPoint?

  var isEmpty: Bool { box == nil && endpoints.isEmpty }

  /// - Parameters:
  ///   - selected: the selected elements as currently drawn (in-flight preview applied), so the
  ///     chrome rides the drag live.
  ///   - interactive: false outside the Select tool — the box still shows, but nothing is grabbable.
  static func resolve(selected: [CardState],
                      editingID: UUID?,
                      viewport: CanvasViewport,
                      interactive: Bool) -> SelectionChrome {
    var chrome = SelectionChrome()
    guard !selected.isEmpty else { return chrome }

    if selected.count == 1, let card = selected.first {
      let editing = card.id == editingID
      // A text element being typed into is a writing caret, not a boxed object.
      if editing, card.elementKind == .text { return chrome }
      let grabbable = interactive && !editing && !card.locked

      if ConnectorGeometry.isConnector(card) {
        guard grabbable, let ends = ConnectorGeometry.endpoints(of: card) else { return chrome }
        chrome.endpoints = [
          Endpoint(connectorID: card.id, endpoint: .start, point: viewport.viewportPoint(ends.start)),
          Endpoint(connectorID: card.id, endpoint: .end, point: viewport.viewportPoint(ends.end)),
        ]
        chrome.deleteCenter = interactive
          ? CGPoint(x: max(chrome.endpoints[0].point.x, chrome.endpoints[1].point.x),
                    y: min(chrome.endpoints[0].point.y, chrome.endpoints[1].point.y) - deleteLift)
          : nil
        return chrome
      }

      let content = viewport.viewportRect(ElementGeometry.bounds(of: card))
      // Image cards draw their own rounded border; a ring offset outside it reads as a double
      // border, so it hugs the image edge instead.
      let hugs = card.elementKind == .image
      let box = content.insetBy(dx: hugs ? -1 : -gap, dy: hugs ? -1 : -gap)
      chrome.box = box
      chrome.boxCornerRadius = cornerRadius(for: card.elementKind) + (hugs ? 0 : gap)
      if grabbable {
        switch card.elementKind {
        case .text:
          chrome.handles = SelectionHandle.corners + [.left, .right]
          chrome.sidesAreTextWidth = true
        case .image:
          chrome.handles = SelectionHandle.corners
        default:
          chrome.handles = SelectionHandle.allCases
        }
        if [.rectangle, .ellipse, .diamond].contains(card.elementKind) {
          let offset = QuickConnectDragSession.screenHandleOffset
          chrome.ports = ConnectorDirection.allCases.map { direction in
            let point: CGPoint = switch direction {
            case .up: CGPoint(x: content.midX, y: content.minY - offset)
            case .right: CGPoint(x: content.maxX + offset, y: content.midY)
            case .down: CGPoint(x: content.midX, y: content.maxY + offset)
            case .left: CGPoint(x: content.minX - offset, y: content.midY)
            }
            return Port(sourceID: card.id, direction: direction, point: point)
          }
        }
      }
      if interactive, !editing, !card.locked {
        chrome.deleteCenter = CGPoint(x: box.maxX, y: box.minY - deleteLift)
      }
      return chrome
    }

    // Several elements: one dashed group box with corner handles (resizing a mixed selection
    // always scales uniformly, so side handles would only distort), plus a thin outline per member.
    let outlines = selected.map { viewport.viewportRect(ElementGeometry.bounds(of: $0)) }
    guard let union = outlines.dropFirst().reduce(outlines.first, { $0?.union($1) }) else { return chrome }
    let box = union.insetBy(dx: -gap, dy: -gap)
    chrome.isMultiple = true
    chrome.elementOutlines = outlines
    chrome.box = box
    chrome.boxCornerRadius = 4
    // A selection mixing locked and unlocked elements still moves (the unlocked part) and still
    // deletes, but offers no resize: the box could not follow the grabbed corner while the locked
    // members stay put.
    if interactive, selected.contains(where: { !$0.locked }) {
      if selected.allSatisfy({ !$0.locked }) { chrome.handles = SelectionHandle.corners }
      chrome.deleteCenter = CGPoint(x: box.maxX, y: box.minY - deleteLift)
    }
    return chrome
  }

  /// The chrome element under `point` (viewport), by priority: connector endpoints, corner
  /// handles, quick-connect ports, then side handles.
  func hit(_ point: CGPoint) -> SelectionChromeHit? {
    if let endpoint = endpoints.first(where: { distance($0.point, point) <= Self.endpointHitRadius }) {
      return .endpoint(endpoint.connectorID, endpoint.endpoint)
    }
    guard let box else { return nil }
    for handle in handles where handle.isCorner {
      if distance(handle.point(on: box), point) <= Self.handleHitRadius { return .handle(handle) }
    }
    if let port = ports.first(where: { distance($0.point, point) <= Self.portHitRadius }) {
      return .quickConnect(port.sourceID, port.direction)
    }
    for handle in handles where !handle.isCorner {
      if sideHit(handle, on: box, at: point) { return .handle(handle) }
    }
    return nil
  }

  private func sideHit(_ handle: SelectionHandle, on box: CGRect, at point: CGPoint) -> Bool {
    if sidesAreTextWidth {
      // The wrap pill: a compact target around the side's midpoint.
      let center = handle.point(on: box)
      return abs(point.x - center.x) <= 10 && abs(point.y - center.y) <= 16
    }
    // An invisible band along the whole side, stopping short of the corner targets.
    let slop = Self.edgeHitSlop
    let inset = Self.handleHitRadius
    switch handle {
    case .top, .bottom:
      let y = handle == .top ? box.minY : box.maxY
      return abs(point.y - y) <= slop && point.x > box.minX + inset && point.x < box.maxX - inset
    case .left, .right:
      let x = handle == .left ? box.minX : box.maxX
      return abs(point.x - x) <= slop && point.y > box.minY + inset && point.y < box.maxY - inset
    default:
      return false
    }
  }

  private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

  /// The content's corner radius, so the ring hugs each element's shape.
  static func cornerRadius(for kind: CanvasElementKind) -> CGFloat {
    switch kind {
    case .text, .equation: 12
    case .image: 8
    case .sticky: 14
    case .checklist, .table: 10
    case .rectangle: 8
    default: 6
    }
  }
}

/// Pure resize math for a selection box. All values are board space.
enum SelectionResize {
  /// The new box when `handle` moves by `delta`.
  /// - Parameters:
  ///   - keepAspect: scale uniformly (corners follow the dominant axis; sides grow the other axis
  ///     symmetrically).
  ///   - fromCenter: ⌥ — the opposite side mirrors the drag, so the centre stays put.
  ///   - minSize/maxSize: the box never shrinks or grows past these; it never flips.
  static func bounds(_ base: CGRect,
                     handle: SelectionHandle,
                     delta: CGSize,
                     keepAspect: Bool,
                     fromCenter: Bool,
                     minSize: CGSize,
                     maxSize: CGSize? = nil) -> CGRect {
    let factor: CGFloat = fromCenter ? 2 : 1
    var width = base.width
    var height = base.height
    if handle.horizontal != 0 { width += CGFloat(handle.horizontal) * delta.width * factor }
    if handle.vertical != 0 { height += CGFloat(handle.vertical) * delta.height * factor }

    let floor = CGSize(width: min(minSize.width, base.width), height: min(minSize.height, base.height))
    if keepAspect, base.width > 0, base.height > 0 {
      let sx = width / base.width
      let sy = height / base.height
      var scale: CGFloat
      if handle.horizontal != 0, handle.vertical != 0 {
        scale = abs(sx - 1) >= abs(sy - 1) ? sx : sy
      } else {
        scale = handle.horizontal != 0 ? sx : sy
      }
      scale = max(scale, floor.width / base.width, floor.height / base.height)
      if let maxSize {
        scale = min(scale, max(maxSize.width / base.width, 1e-6), max(maxSize.height / base.height, 1e-6))
      }
      width = base.width * scale
      height = base.height * scale
    } else {
      width = max(width, floor.width)
      height = max(height, floor.height)
      if let maxSize {
        width = min(width, maxSize.width)
        height = min(height, maxSize.height)
      }
    }

    let x: CGFloat
    if fromCenter || handle.horizontal == 0 { x = base.midX - width / 2 }
    else if handle.horizontal > 0 { x = base.minX }
    else { x = base.maxX - width }

    let y: CGFloat
    if fromCenter || handle.vertical == 0 { y = base.midY - height / 2 }
    else if handle.vertical > 0 { y = base.minY }
    else { y = base.maxY - height }

    return CGRect(x: x, y: y, width: width, height: height)
  }

  /// Carry `frame` from the old box into the new one proportionally.
  static func mapped(_ frame: CGRect, from old: CGRect, to new: CGRect) -> CGRect {
    let sx = old.width > 0 ? new.width / old.width : 1
    let sy = old.height > 0 ? new.height / old.height : 1
    return CGRect(x: new.minX + (frame.minX - old.minX) * sx,
                  y: new.minY + (frame.minY - old.minY) * sy,
                  width: frame.width * sx,
                  height: frame.height * sy)
  }
}
