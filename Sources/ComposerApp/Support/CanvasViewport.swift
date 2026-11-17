import CoreGraphics

/// The board ⇄ viewport transform: `viewport = board × scale + pan`.
///
/// One value type so every input path, overlay, hit test, and zoom gesture converts the same way —
/// the old code re-derived this formula in a dozen places, and each copy was a chance to disagree
/// (forgetting the live space-pan offset, or dividing by an unclamped zero zoom).
struct CanvasViewport: Equatable {
  static let minScale: CGFloat = 0.1
  static let maxScale: CGFloat = 4

  var scale: CGFloat
  var pan: CGSize

  init(scale: CGFloat = 1, pan: CGSize = .zero) {
    self.scale = scale
    self.pan = pan
  }

  /// The zoom as a safe divisor.
  var safeScale: CGFloat { max(scale, 0.01) }

  static func clampScale(_ value: CGFloat) -> CGFloat {
    min(max(value, minScale), maxScale)
  }

  func boardPoint(_ viewportPoint: CGPoint) -> CGPoint {
    CGPoint(x: (viewportPoint.x - pan.width) / safeScale,
            y: (viewportPoint.y - pan.height) / safeScale)
  }

  func viewportPoint(_ boardPoint: CGPoint) -> CGPoint {
    CGPoint(x: boardPoint.x * scale + pan.width,
            y: boardPoint.y * scale + pan.height)
  }

  func boardRect(_ viewportRect: CGRect) -> CGRect {
    let origin = boardPoint(viewportRect.origin)
    return CGRect(x: origin.x, y: origin.y,
                  width: viewportRect.width / safeScale,
                  height: viewportRect.height / safeScale)
  }

  func viewportRect(_ boardRect: CGRect) -> CGRect {
    let origin = viewportPoint(boardRect.origin)
    return CGRect(x: origin.x, y: origin.y,
                  width: boardRect.width * scale,
                  height: boardRect.height * scale)
  }

  /// A screen-space distance (a hit slop, a drag threshold) expressed in board units.
  func boardDistance(_ screenDistance: CGFloat) -> CGFloat {
    screenDistance / safeScale
  }

  /// The same board, zoomed to `target` (clamped) while the board point under `anchor` stays put.
  func zoomed(to target: CGFloat, anchoredAt anchor: CGPoint) -> CanvasViewport {
    let next = Self.clampScale(target)
    let pinned = boardPoint(anchor)
    return CanvasViewport(
      scale: next,
      pan: CGSize(width: anchor.x - pinned.x * next, height: anchor.y - pinned.y * next))
  }

  func panned(by delta: CGSize) -> CanvasViewport {
    CanvasViewport(scale: scale, pan: CGSize(width: pan.width + delta.width,
                                             height: pan.height + delta.height))
  }

  /// The board region visible in a viewport of `size`, grown by `margin` board units.
  func visibleBoardRect(in size: CGSize, margin: CGFloat = 0) -> CGRect {
    boardRect(CGRect(origin: .zero, size: size)).insetBy(dx: -margin, dy: -margin)
  }
}
