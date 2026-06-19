import CoreGraphics
import Foundation

/// Which way a layered layout flows.
enum LayoutDirection: String {
  /// Roots at the top, children below — hierarchies, architecture.
  case down
  /// Roots at the left, children to the right — pipelines, flows.
  case right
}

/// A pure, deterministic graph-layout pass — the spatial reasoning an LLM can't do in its head.
///
/// The agent declares *structure* (which nodes connect to which); this assigns clean board
/// positions so nodes never overlap and edges mostly avoid crossing. It's a compact Sugiyama-style
/// layered layout: assign ranks (longest-path, cycle-safe), reduce crossings (barycenter sweeps),
/// then place coordinates rank by rank. Disconnected pieces are laid out independently and
/// flow-packed into rows, so a board with several little clusters still reads tidily.
enum BoardLayout {
  struct Node { var id: UUID; var size: CGSize }
  struct Edge { var from: UUID; var to: UUID }

  struct Config {
    var direction: LayoutDirection = .down
    /// Gap between siblings within one rank.
    var nodeGap: CGFloat = 44
    /// Gap between successive ranks (the flow axis).
    var rankGap: CGFloat = 108
    /// Gap between disconnected components.
    var componentGap: CGFloat = 96
    /// Board-space top-left the whole layout starts from.
    var origin: CGPoint = CGPoint(x: 120, y: 120)
    /// Components wrap onto a new row once a row would exceed this width.
    var maxRowWidth: CGFloat = 2600
  }

  /// Top-left board positions for every node id. Nodes not touched by any edge are laid out as
  /// singleton components and flow-packed after the connected ones.
  static func layout(nodes: [Node], edges rawEdges: [Edge], config: Config = Config()) -> [UUID: CGPoint] {
    guard !nodes.isEmpty else { return [:] }
    let order = nodes.map(\.id)
    let index = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
    let sizes = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0.size) })
    let ids = Set(order)

    // Keep only edges between real, distinct nodes; drop duplicates.
    var seen = Set<String>()
    let edges = rawEdges.filter { e in
      guard ids.contains(e.from), ids.contains(e.to), e.from != e.to else { return false }
      return seen.insert(e.from.uuidString + "->" + e.to.uuidString).inserted
    }

    // Weakly-connected components via union-find over the undirected edges.
    var parent = Dictionary(uniqueKeysWithValues: order.map { ($0, $0) })
    func find(_ a: UUID) -> UUID {
      var r = a
      while parent[r]! != r { parent[r] = parent[parent[r]!]!; r = parent[r]! }
      return r
    }
    func union(_ a: UUID, _ b: UUID) { let ra = find(a), rb = find(b); if ra != rb { parent[ra] = rb } }
    for e in edges { union(e.from, e.to) }
    var grouped: [UUID: [UUID]] = [:]
    for id in order { grouped[find(id), default: []].append(id) }

    // Lay out each component locally, normalize to a (0,0) top-left, remember its size.
    struct Placed { var positions: [UUID: CGPoint]; var size: CGSize; var count: Int; var rank: Int }
    var components: [Placed] = []
    for (_, raw) in grouped {
      let compIDs = raw.sorted { index[$0]! < index[$1]! }
      let compSet = Set(compIDs)
      let compEdges = edges.filter { compSet.contains($0.from) && compSet.contains($0.to) }
      var positions = layoutComponent(ids: compIDs, edges: compEdges, sizes: sizes, index: index, config: config)
      let minX = positions.values.map(\.x).min() ?? 0
      let minY = positions.values.map(\.y).min() ?? 0
      var w: CGFloat = 0, h: CGFloat = 0
      for id in compIDs {
        let p = CGPoint(x: (positions[id]?.x ?? 0) - minX, y: (positions[id]?.y ?? 0) - minY)
        positions[id] = p
        w = max(w, p.x + (sizes[id]?.width ?? 0))
        h = max(h, p.y + (sizes[id]?.height ?? 0))
      }
      components.append(Placed(positions: positions, size: CGSize(width: w, height: h),
                               count: compIDs.count, rank: index[compIDs[0]]!))
    }

    // Biggest cluster first (it's the "main" diagram), then original order. Flow-pack into rows.
    components.sort { $0.count != $1.count ? $0.count > $1.count : $0.rank < $1.rank }

    var result: [UUID: CGPoint] = [:]
    var cursorX: CGFloat = 0, cursorY: CGFloat = 0, rowHeight: CGFloat = 0
    for placed in components {
      if cursorX > 0, cursorX + placed.size.width > config.maxRowWidth {
        cursorX = 0; cursorY += rowHeight + config.componentGap; rowHeight = 0
      }
      for (id, p) in placed.positions {
        result[id] = CGPoint(x: config.origin.x + cursorX + p.x, y: config.origin.y + cursorY + p.y)
      }
      cursorX += placed.size.width + config.componentGap
      rowHeight = max(rowHeight, placed.size.height)
    }
    return result
  }

  // MARK: One connected component → layered positions (local coordinates)

  private static func layoutComponent(ids: [UUID], edges: [Edge], sizes: [UUID: CGSize],
                                      index: [UUID: Int], config: Config) -> [UUID: CGPoint] {
    guard ids.count > 1 else { return [ids[0]: .zero] }

    var succ: [UUID: [UUID]] = [:], pred: [UUID: [UUID]] = [:]
    var indeg = Dictionary(uniqueKeysWithValues: ids.map { ($0, 0) })
    for e in edges {
      succ[e.from, default: []].append(e.to)
      pred[e.to, default: []].append(e.from)
      indeg[e.to]! += 1
    }

    // Longest-path layering via Kahn, breaking cycles by force-popping the lowest-in-degree node.
    var layer = Dictionary(uniqueKeysWithValues: ids.map { ($0, 0) })
    var remaining = Set(ids)
    var work = indeg
    var queue = ids.filter { work[$0] == 0 }
    while !remaining.isEmpty {
      if queue.isEmpty {
        if let pick = ids.filter({ remaining.contains($0) })
          .min(by: { (work[$0] ?? 0, index[$0]!) < (work[$1] ?? 0, index[$1]!) }) {
          queue.append(pick)
        } else { break }
      }
      let u = queue.removeFirst()
      guard remaining.contains(u) else { continue }
      remaining.remove(u)
      for v in succ[u] ?? [] where remaining.contains(v) {
        layer[v] = max(layer[v]!, (layer[u] ?? 0) + 1)
        work[v] = max(0, (work[v] ?? 1) - 1)
        if work[v] == 0 { queue.append(v) }
      }
    }

    // Bucket into ranks, seeded in original order.
    let maxLayer = layer.values.max() ?? 0
    var ranks: [[UUID]] = Array(repeating: [], count: maxLayer + 1)
    for id in ids.sorted(by: { index[$0]! < index[$1]! }) { ranks[layer[id]!].append(id) }

    var pos: [UUID: Int] = [:]
    for rank in ranks { for (i, id) in rank.enumerated() { pos[id] = i } }

    func barycenter(_ id: UUID, _ neighbors: [UUID]?) -> Double {
      let vals = (neighbors ?? []).compactMap { pos[$0] }
      guard !vals.isEmpty else { return Double(pos[id] ?? 0) }
      return Double(vals.reduce(0, +)) / Double(vals.count)
    }
    // Alternating down/up sweeps; neighbors live in the already-fixed adjacent rank, so each sort
    // is stable. Ties fall back to original order for determinism.
    for sweep in 0..<6 where maxLayer >= 1 {
      if sweep % 2 == 0 {
        for l in 1...maxLayer {
          let bc = Dictionary(uniqueKeysWithValues: ranks[l].map { ($0, barycenter($0, pred[$0])) })
          ranks[l].sort { (bc[$0]!, index[$0]!) < (bc[$1]!, index[$1]!) }
          for (i, id) in ranks[l].enumerated() { pos[id] = i }
        }
      } else {
        for l in stride(from: maxLayer - 1, through: 0, by: -1) {
          let bc = Dictionary(uniqueKeysWithValues: ranks[l].map { ($0, barycenter($0, succ[$0])) })
          ranks[l].sort { (bc[$0]!, index[$0]!) < (bc[$1]!, index[$1]!) }
          for (i, id) in ranks[l].enumerated() { pos[id] = i }
        }
      }
    }

    return assignCoordinates(ranks: ranks, sizes: sizes, config: config)
  }

  /// Place each rank along the flow axis, centering its members on the cross axis.
  private static func assignCoordinates(ranks: [[UUID]], sizes: [UUID: CGSize], config: Config) -> [UUID: CGPoint] {
    var result: [UUID: CGPoint] = [:]
    let down = (config.direction == .down)
    var flow: CGFloat = 0

    for rank in ranks where !rank.isEmpty {
      // Thickness along the flow axis; total span across it (for centering).
      let thickness = rank.map { down ? (sizes[$0]?.height ?? 0) : (sizes[$0]?.width ?? 0) }.max() ?? 0
      let cross = rank.map { down ? (sizes[$0]?.width ?? 0) : (sizes[$0]?.height ?? 0) }
      let totalCross = cross.reduce(0, +) + CGFloat(max(rank.count - 1, 0)) * config.nodeGap
      var crossCursor = -totalCross / 2

      for id in rank {
        let s = sizes[id] ?? .zero
        if down {
          result[id] = CGPoint(x: crossCursor, y: flow + (thickness - s.height) / 2)
          crossCursor += s.width + config.nodeGap
        } else {
          result[id] = CGPoint(x: flow + (thickness - s.width) / 2, y: crossCursor)
          crossCursor += s.height + config.nodeGap
        }
      }
      flow += thickness + config.rankGap
    }
    return result
  }
}
