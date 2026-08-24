import CoreGraphics

/// Pure transform math for the viewport dot grid.
///
/// Grid intersections live in board space. Zoom changes their screen-space spacing, while pan
/// changes only the phase. Keeping this independent from SwiftUI makes negative pans and zoomed
/// origins deterministic and cheap to test.
enum CanvasDotGridLayout {
  static let boardSpacing: CGFloat = 32

  struct Axis: Equatable {
    let first: CGFloat
    let spacing: CGFloat
  }

  static func axis(scale: CGFloat, translation: CGFloat) -> Axis {
    let spacing = boardSpacing * max(scale, 0.01)
    let remainder = translation.truncatingRemainder(dividingBy: spacing)
    return Axis(first: remainder >= 0 ? remainder : remainder + spacing, spacing: spacing)
  }
}
