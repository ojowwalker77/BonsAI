import CoreGraphics
import Foundation

/// One normalized vector node. Handles are absolute points in the same local 0...1 coordinate
/// space as the anchor. A corner node has no handles; a smooth node has a symmetric pair.
struct VectorPathNode: Codable, Equatable {
  var anchor: CanvasPoint
  var incoming: CanvasPoint?
  var outgoing: CanvasPoint?

  init(anchor: CanvasPoint, incoming: CanvasPoint? = nil, outgoing: CanvasPoint? = nil) {
    self.anchor = anchor
    self.incoming = incoming
    self.outgoing = outgoing
  }
}

/// The durable vector payload. It stays independent of `CardState` so draft geometry, rendering,
/// persistence, and edit gestures all cross the same small model interface.
struct VectorPathSpec: Codable, Equatable {
  var nodes: [VectorPathNode]
  var isClosed: Bool

  init(nodes: [VectorPathNode] = [], isClosed: Bool = false) {
    self.nodes = nodes
    self.isClosed = isClosed
  }

  private enum CodingKeys: String, CodingKey { case nodes, isClosed }

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    nodes = try values.decodeIfPresent([VectorPathNode].self, forKey: .nodes) ?? []
    isClosed = try values.decodeIfPresent(Bool.self, forKey: .isClosed) ?? false
  }
}

struct VectorPathPlacement: Equatable {
  var frame: CGRect
  var spec: VectorPathSpec
}

enum VectorPathControl: Equatable {
  case anchor
  case incoming
  case outgoing
}

/// Converts a stable screen-space control drag into one vector placement. Keeping zoom conversion
/// and the refit in this pure seam guarantees the local preview and mouse-up commit use identical
/// geometry even though refitting changes the card's frame and origin during the gesture.
enum VectorPathControlDrag {
  static func boardTranslation(from screenTranslation: CGSize, zoom: CGFloat) -> CGSize {
    let safeZoom = max(zoom, 0.01)
    return CGSize(
      width: screenTranslation.width / safeZoom,
      height: screenTranslation.height / safeZoom)
  }

  static func placement(_ control: VectorPathControl,
                        nodeAt index: Int,
                        screenTranslation: CGSize,
                        zoom: CGFloat,
                        in spec: VectorPathSpec,
                        frame: CGRect) -> VectorPathPlacement? {
    // DragGesture(minimumDistance: 0) also ends for a bare control click. Do not feed that through
    // normalization/refitting: an imported or legacy path may not be tightly fitted, so a zero
    // translation could otherwise move it and consume an undo step despite no pointer motion.
    guard hypot(screenTranslation.width, screenTranslation.height) > 0.5 else { return nil }
    return VectorPathGeometry.moving(
      control,
      nodeAt: index,
      by: boardTranslation(from: screenTranslation, zoom: zoom),
      in: spec,
      frame: frame)
  }
}

/// A multi-click pen draft in board coordinates. Callers feed it one press/drag at a time and only
/// need to distinguish `nil` (keep drawing) from a returned placement (closed path committed).
struct VectorPathDraft: Equatable {
  fileprivate var nodes: [VectorPathGeometry.WorldNode] = []
  fileprivate var preview: VectorPathGeometry.WorldNode?

  var nodeCount: Int { nodes.count }
  var anchorPoints: [CGPoint] { nodes.map(\.anchor) + [preview?.anchor].compactMap { $0 } }
  var previewPath: CGPath { VectorPathGeometry.path(nodes: renderingNodes, isClosed: false) }

  private var renderingNodes: [VectorPathGeometry.WorldNode] {
    nodes + [preview].compactMap { $0 }
  }

  mutating func update(anchor: CGPoint, drag: CGPoint) {
    preview = VectorPathGeometry.node(anchor: anchor, drag: drag)
  }

  /// Track the pointer between clicks so the unfinished final segment rubber-bands from the last
  /// committed node. Before the first node (or after leaving the canvas) there is no preview.
  mutating func hover(at point: CGPoint?) {
    preview = nodes.isEmpty ? nil : point.map { VectorPathGeometry.node(anchor: $0, drag: $0) }
  }

  /// Finish one pointer gesture. Clicking the first anchor closes when at least three committed
  /// nodes exist; otherwise the new corner/smooth node becomes part of the open draft.
  mutating func finish(anchor: CGPoint,
                       drag: CGPoint,
                       closeTolerance: CGFloat) -> VectorPathPlacement? {
    preview = nil
    if nodes.count >= 3,
       hypot(anchor.x - drag.x, anchor.y - drag.y) < 0.001,
       let first = nodes.first?.anchor,
       hypot(anchor.x - first.x, anchor.y - first.y) <= closeTolerance {
      return VectorPathGeometry.placement(nodes: nodes, isClosed: true)
    }
    nodes.append(VectorPathGeometry.node(anchor: anchor, drag: drag))
    return nil
  }

  /// Return commits an open path only after two nodes. A one-point draft remains in progress.
  func commitOpen() -> VectorPathPlacement? {
    guard nodes.count >= 2 else { return nil }
    return VectorPathGeometry.placement(nodes: nodes, isClosed: false)
  }
}

/// Pure vector geometry and pen policy.
///
/// The interface hides draft lifecycle, cubic construction, normalized persistence coordinates,
/// frame fitting, and symmetric handle edits. Both SwiftUI callers and tests use these operations;
/// no view needs to duplicate Bezier or normalization math.
enum VectorPathGeometry {
  fileprivate struct WorldNode: Equatable {
    var anchor: CGPoint
    var incoming: CGPoint?
    var outgoing: CGPoint?
  }

  static let padding: CGFloat = 8

  static func path(for spec: VectorPathSpec, in rect: CGRect) -> CGPath {
    path(nodes: spec.nodes.map { worldNode($0, in: rect) }, isClosed: spec.isClosed)
  }

  static func controlPoint(_ control: VectorPathControl,
                           nodeAt index: Int,
                           in spec: VectorPathSpec,
                           frame: CGRect) -> CGPoint? {
    guard spec.nodes.indices.contains(index) else { return nil }
    let node = worldNode(spec.nodes[index], in: frame)
    switch control {
    case .anchor: return node.anchor
    case .incoming: return node.incoming
    case .outgoing: return node.outgoing
    }
  }

  /// Move one anchor or existing handle by a board-space translation and return a refitted,
  /// normalized placement. Anchor moves carry their handles; handle moves mirror the opposite
  /// handle through the anchor, preserving the pen tool's symmetric-smooth invariant.
  static func moving(_ control: VectorPathControl,
                     nodeAt index: Int,
                     by translation: CGSize,
                     in spec: VectorPathSpec,
                     frame: CGRect) -> VectorPathPlacement? {
    guard spec.nodes.indices.contains(index) else { return nil }
    var world = spec.nodes.map { worldNode($0, in: frame) }
    let delta = CGPoint(x: translation.width, y: translation.height)
    switch control {
    case .anchor:
      world[index].anchor = world[index].anchor + delta
      world[index].incoming = world[index].incoming.map { $0 + delta }
      world[index].outgoing = world[index].outgoing.map { $0 + delta }
    case .incoming:
      guard let handle = world[index].incoming else { return nil }
      let moved = handle + delta
      world[index].incoming = moved
      world[index].outgoing = mirror(moved, around: world[index].anchor)
    case .outgoing:
      guard let handle = world[index].outgoing else { return nil }
      let moved = handle + delta
      world[index].outgoing = moved
      world[index].incoming = mirror(moved, around: world[index].anchor)
    }
    return placement(nodes: world, isClosed: spec.isClosed)
  }

  fileprivate static func node(anchor: CGPoint, drag: CGPoint) -> WorldNode {
    guard hypot(drag.x - anchor.x, drag.y - anchor.y) >= 0.01 else {
      return WorldNode(anchor: anchor)
    }
    return WorldNode(anchor: anchor, incoming: mirror(drag, around: anchor), outgoing: drag)
  }

  fileprivate static func placement(nodes: [WorldNode], isClosed: Bool) -> VectorPathPlacement? {
    guard !nodes.isEmpty else { return nil }
    let controlPoints = nodes.flatMap { node in
      [node.anchor] + [node.incoming, node.outgoing].compactMap { $0 }
    }
    guard var minX = controlPoints.map(\.x).min(),
          var minY = controlPoints.map(\.y).min(),
          var maxX = controlPoints.map(\.x).max(),
          var maxY = controlPoints.map(\.y).max() else { return nil }
    minX -= padding
    minY -= padding
    maxX += padding
    maxY += padding
    let minimum = CardState.lineMinSize
    if maxX - minX < minimum.width {
      let extra = (minimum.width - (maxX - minX)) / 2
      minX -= extra
      maxX += extra
    }
    if maxY - minY < minimum.height {
      let extra = (minimum.height - (maxY - minY)) / 2
      minY -= extra
      maxY += extra
    }
    let frame = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    let normalizedNodes = nodes.map { node in
      VectorPathNode(
        anchor: normalized(node.anchor, in: frame),
        incoming: node.incoming.map { normalized($0, in: frame) },
        outgoing: node.outgoing.map { normalized($0, in: frame) })
    }
    return VectorPathPlacement(frame: frame, spec: VectorPathSpec(nodes: normalizedNodes, isClosed: isClosed))
  }

  fileprivate static func path(nodes: [WorldNode], isClosed: Bool) -> CGPath {
    let result = CGMutablePath()
    guard let first = nodes.first else { return result }
    result.move(to: first.anchor)
    for index in 1..<nodes.count {
      appendSegment(from: nodes[index - 1], to: nodes[index], to: result)
    }
    if isClosed, nodes.count > 1 {
      appendSegment(from: nodes[nodes.count - 1], to: first, to: result)
      result.closeSubpath()
    }
    return result
  }

  private static func appendSegment(from start: WorldNode, to end: WorldNode, to path: CGMutablePath) {
    if start.outgoing != nil || end.incoming != nil {
      path.addCurve(
        to: end.anchor,
        control1: start.outgoing ?? start.anchor,
        control2: end.incoming ?? end.anchor)
    } else {
      path.addLine(to: end.anchor)
    }
  }

  private static func worldNode(_ node: VectorPathNode, in frame: CGRect) -> WorldNode {
    WorldNode(
      anchor: world(node.anchor, in: frame),
      incoming: node.incoming.map { world($0, in: frame) },
      outgoing: node.outgoing.map { world($0, in: frame) })
  }

  private static func world(_ point: CanvasPoint, in frame: CGRect) -> CGPoint {
    CGPoint(x: frame.minX + CGFloat(point.x) * frame.width,
            y: frame.minY + CGFloat(point.y) * frame.height)
  }

  private static func normalized(_ point: CGPoint, in frame: CGRect) -> CanvasPoint {
    CanvasPoint(x: Double((point.x - frame.minX) / max(frame.width, 1)),
                y: Double((point.y - frame.minY) / max(frame.height, 1)))
  }

  private static func mirror(_ point: CGPoint, around anchor: CGPoint) -> CGPoint {
    CGPoint(x: anchor.x * 2 - point.x, y: anchor.y * 2 - point.y)
  }
}

private extension CGPoint {
  static func + (lhs: CGPoint, rhs: CGPoint) -> CGPoint {
    CGPoint(x: lhs.x + rhs.x, y: lhs.y + rhs.y)
  }
}
