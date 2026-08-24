import CoreGraphics
import Foundation

/// The semantic interaction boundary for checklist rows.
///
/// Canvas cards render pointer-transparent content under one AppKit catcher, so completion toggles
/// need a small geometry policy instead of treating the whole row as a checkbox. The editor uses
/// the same module for stable-ID reordering, keeping both behaviors independently testable from
/// SwiftUI and AppKit.
enum ChecklistInteraction {
  enum CanvasLayout {
    case structured
    case markdown

    fileprivate var topInset: CGFloat {
      switch self {
      case .structured: 16
      case .markdown: 18
      }
    }

    fileprivate var rowStride: CGFloat {
      switch self {
      case .structured: 30
      case .markdown: 24
      }
    }

    fileprivate var checkboxHeight: CGFloat {
      switch self {
      case .structured: 22
      case .markdown: 20
      }
    }
  }

  /// A padded checkbox column: wide enough to acquire intentionally, narrow enough that task text
  /// and the rest of the card always fall through to select/move/double-click editing.
  private static let checkboxXRange: ClosedRange<CGFloat> = 10...42

  static func itemIndex(at point: CGPoint,
                        zoom: CGFloat,
                        itemCount: Int,
                        layout: CanvasLayout) -> Int? {
    guard zoom > 0, itemCount > 0 else { return nil }
    let local = CGPoint(x: point.x / zoom, y: point.y / zoom)
    guard checkboxXRange.contains(local.x) else { return nil }
    let relativeY = local.y - layout.topInset
    guard relativeY >= 0 else { return nil }
    let index = Int(relativeY / layout.rowStride)
    guard (0..<itemCount).contains(index) else { return nil }
    let yWithinRow = relativeY - CGFloat(index) * layout.rowStride
    guard yWithinRow <= layout.checkboxHeight else { return nil }
    return index
  }

  /// Move one stable checklist row to the position occupied by another. Text, completion state,
  /// and UUID travel together; invalid or identity drops are no-ops.
  @discardableResult
  static func move(_ items: inout [CardState.ChecklistItem],
                   itemID: UUID,
                   to targetID: UUID) -> Bool {
    guard itemID != targetID,
          let source = items.firstIndex(where: { $0.id == itemID }),
          let target = items.firstIndex(where: { $0.id == targetID }) else { return false }
    let item = items.remove(at: source)
    items.insert(item, at: min(target, items.endIndex))
    return true
  }
}
