import CoreGraphics

/// Pure transform math for the viewport dot grid.
///
/// Grid intersections live in board space. Zoom changes their screen-space spacing, while pan
/// changes only the phase. Keeping this independent from SwiftUI makes negative pans and zoomed
/// origins deterministic and cheap to test.
enum CanvasDotGridLayout {
  static let boardSpacing: CGFloat = 32
  /// Below this screen-space separation, render every second/third/etc. board intersection. This
  /// keeps the grid quiet and bounds the path work while preserving board-space alignment.
  static let minimumScreenSpacing: CGFloat = 24
  /// Each dot adds an ellipse subpath on every live pan/zoom frame. Four thousand is a hard
  /// per-frame path-work budget; an 8K viewport at minimum zoom measures about 3,300 dots after
  /// integer board-step alignment, down from roughly 10,800 with the former 12K budget.
  static let maximumDotCount = 4_000

  struct Axis: Equatable {
    let first: CGFloat
    let spacing: CGFloat
  }

  struct Layout: Equatable {
    let xAxis: Axis
    let yAxis: Axis
    let boardStep: Int
    let dotCount: Int
  }

  static func axis(scale: CGFloat, translation: CGFloat, boardStep: Int = 1) -> Axis {
    let spacing = boardSpacing * max(scale, 0.01) * CGFloat(max(boardStep, 1))
    let remainder = translation.truncatingRemainder(dividingBy: spacing)
    return Axis(first: remainder >= 0 ? remainder : remainder + spacing, spacing: spacing)
  }

  static func layout(scale: CGFloat, translation: CGSize, viewportSize: CGSize) -> Layout {
    let baseSpacing = boardSpacing * max(scale, 0.01)
    let area = max(viewportSize.width, 0) * max(viewportSize.height, 0)
    let budgetSpacing = sqrt(area / CGFloat(maximumDotCount))
    let requestedSpacing = max(minimumScreenSpacing, budgetSpacing)
    var boardStep = max(1, Int(ceil(requestedSpacing / baseSpacing)))
    var result = makeLayout(
      scale: scale, translation: translation, viewportSize: viewportSize, boardStep: boardStep)

    // Edge-inclusive counts can exceed the area estimate by one row/column. Tighten until the
    // explicit count satisfies the hard budget instead of relying on the approximation.
    while result.dotCount > maximumDotCount {
      boardStep += 1
      result = makeLayout(
        scale: scale, translation: translation, viewportSize: viewportSize, boardStep: boardStep)
    }
    return result
  }

  private static func makeLayout(scale: CGFloat,
                                 translation: CGSize,
                                 viewportSize: CGSize,
                                 boardStep: Int) -> Layout {
    let xAxis = axis(scale: scale, translation: translation.width, boardStep: boardStep)
    let yAxis = axis(scale: scale, translation: translation.height, boardStep: boardStep)
    let count = pointCount(on: xAxis, through: viewportSize.width)
      * pointCount(on: yAxis, through: viewportSize.height)
    return Layout(xAxis: xAxis, yAxis: yAxis, boardStep: boardStep, dotCount: count)
  }

  private static func pointCount(on axis: Axis, through length: CGFloat) -> Int {
    guard length >= 0, axis.first <= length, axis.spacing > 0 else { return 0 }
    return Int(floor((length - axis.first) / axis.spacing)) + 1
  }
}
