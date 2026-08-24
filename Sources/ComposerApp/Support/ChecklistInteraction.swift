import CoreGraphics
import Foundation

/// The semantic interaction boundary for checklist rows.
///
/// Canvas cards render pointer-transparent content under one AppKit catcher, so completion toggles
/// need a small geometry policy instead of treating the whole row as a checkbox. The editor uses
/// the same module for stable-ID reordering, keeping both behaviors independently testable from
/// SwiftUI and AppKit.
enum ChecklistInteraction {
  enum DropPlacement: Equatable {
    case before
    case after
  }

  /// A checkbox remains intentionally acquirable when the board is zoomed out. The source rects
  /// are measured from the rendered symbols in screen space, so wrapping, font choice, and a text
  /// card's own scale cannot make the interaction drift to a different row.
  static let minimumCheckboxHitSide: CGFloat = 24

  static func checkboxHitRect(for renderedFrame: CGRect) -> CGRect {
    let width = max(renderedFrame.width, minimumCheckboxHitSide)
    let height = max(renderedFrame.height, minimumCheckboxHitSide)
    return CGRect(
      x: renderedFrame.midX - width / 2,
      y: renderedFrame.midY - height / 2,
      width: width,
      height: height)
  }

  /// Resolve among measured checkbox frames. Expanded targets can overlap at very small board
  /// zooms, so nearest-center wins instead of dictionary order deciding which row toggles.
  static func itemIndex(at point: CGPoint, renderedFrames: [Int: CGRect]) -> Int? {
    renderedFrames
      .compactMap { index, frame -> (index: Int, distance: CGFloat)? in
        guard checkboxHitRect(for: frame).contains(point) else { return nil }
        return (index, hypot(point.x - frame.midX, point.y - frame.midY))
      }
      .min { lhs, rhs in
        lhs.distance == rhs.distance ? lhs.index < rhs.index : lhs.distance < rhs.distance
      }?
      .index
  }

  static func dropPlacement(at y: CGFloat, rowHeight: CGFloat) -> DropPlacement {
    y < rowHeight / 2 ? .before : .after
  }

  /// Insert one stable checklist row before or after another. The insertion index is adjusted after
  /// removal, so the same target half has the same meaning in both drag directions. Text,
  /// completion state, and UUID travel together; invalid and already-in-place drops are no-ops.
  @discardableResult
  static func move(_ items: inout [CardState.ChecklistItem],
                   itemID: UUID,
                   to targetID: UUID,
                   placement: DropPlacement) -> Bool {
    guard itemID != targetID,
          let source = items.firstIndex(where: { $0.id == itemID }),
          let target = items.firstIndex(where: { $0.id == targetID }) else { return false }
    var insertion = target + (placement == .after ? 1 : 0)
    if source < insertion { insertion -= 1 }
    guard insertion != source else { return false }
    let item = items.remove(at: source)
    items.insert(item, at: min(max(insertion, 0), items.endIndex))
    return true
  }
}
