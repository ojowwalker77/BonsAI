import CoreGraphics

/// Shared measurement constants and containment math for labels centered inside diagram nodes.
enum ShapeLabelGeometry {
  static let defaultMaximumContainerWidth: CGFloat = 216
  static let horizontalPadding: CGFloat = 12
  static let verticalPadding: CGFloat = 8
  /// AppKit and SwiftUI font layout can differ by a few fractional points. Preserve the existing
  /// fit slack above the explicit padding so a last baseline never clips.
  static let measurementSlack: CGFloat = 6
  /// `ShapeBox` draws its path after a 2pt inset on every edge.
  static let shapePathInset: CGFloat = 2

  /// `ShapeBox` is laid out after the card frame has been converted from board units to screen
  /// points. Keep its padding in that same conversion so zooming out does not make the fixed
  /// screen-space inset consume a progressively larger share of a fitted diamond.
  static func renderedShapePathInset(at zoom: CGFloat) -> CGFloat {
    shapePathInset * max(zoom, 0)
  }

  static var defaultMaximumContentWidth: CGFloat {
    defaultMaximumContainerWidth - horizontalPadding * 2
  }

  static func paddedBlockSize(contentWidth: CGFloat, contentHeight: CGFloat) -> CGSize {
    CGSize(
      width: ceil(contentWidth) + horizontalPadding * 2,
      height: max(
        ceil(contentHeight) + verticalPadding * 2 + measurementSlack,
        54))
  }

  /// For a centered axis-aligned rectangle `(labelWidth, labelHeight)` inside a diamond whose
  /// interior diagonals are `(diamondWidth, diamondHeight)`, containment is exactly:
  ///
  ///     labelWidth / diamondWidth + labelHeight / diamondHeight <= 1
  ///
  /// Doubling both label dimensions is the minimum-area balanced solution. Add back the shape's
  /// render inset so the constraint applies to the visible diamond path, not the outer view frame.
  static func diamondContainerSize(containing paddedBlock: CGSize) -> CGSize {
    CGSize(
      width: ceil(paddedBlock.width * 2 + shapePathInset * 2),
      height: ceil(paddedBlock.height * 2 + shapePathInset * 2))
  }

  static func diamondContains(paddedBlock: CGSize, in container: CGSize) -> Bool {
    let interiorWidth = container.width - shapePathInset * 2
    let interiorHeight = container.height - shapePathInset * 2
    guard interiorWidth > 0, interiorHeight > 0 else { return false }
    return paddedBlock.width / interiorWidth + paddedBlock.height / interiorHeight <= 1.000_001
  }
}
