import CoreGraphics
import Foundation

/// Long-lived state for the board window.
///
/// `PanelController` owns one session for the lifetime of the app and injects it into every
/// replaceable SwiftUI root. Theme, language, and system-appearance changes may remount the view,
/// but they must never replace the working board, its undo history, or the user's viewport.
@MainActor
final class CanvasWorkspaceSession: ObservableObject {
  let store: DumpStore
  let board: BoardViewModel

  @Published var scale: CGFloat = 1
  @Published var pan: CGSize = .zero
  /// Unsaved Agent input survives replacing the SwiftUI canvas root for theme/language changes.
  @Published var agentDraft = ""

  private(set) var lastRemountTrigger: CanvasRemountTrigger?

  init(store: DumpStore? = nil) {
    let resolvedStore = store ?? DumpStore.shared
    self.store = resolvedStore
    board = BoardViewModel(store: resolvedStore)
    CanvasBridge.shared.register(board)
  }

  /// Capture live editor text and geometry synchronously before replacing the hosted root.
  ///
  /// `flushSave` also cancels the pending debounced callback. The same model is retained after the
  /// flush, so its per-board undo/redo cache and the bridge registration remain intact.
  func prepareForRemount(_ trigger: CanvasRemountTrigger) {
    board.flushSave()
    CanvasBridge.shared.register(board)
    lastRemountTrigger = trigger
  }

  /// Minimally pan until `cardID` is visible inside the canvas. Keeping this on the retained
  /// workspace makes a reveal durable across window focus changes and SwiftUI remounts.
  @discardableResult
  func revealCard(_ cardID: UUID,
                  in viewportSize: CGSize,
                  transientPan: CGSize = .zero,
                  margin: CGFloat = 48) -> Bool {
    guard viewportSize.width > 0, viewportSize.height > 0,
          let frame = board.renderingFrame(for: cardID) else { return false }

    let safeScale = max(scale, 0.01)
    let horizontalMargin = min(margin, max((viewportSize.width - 1) / 2, 0))
    let verticalMargin = min(margin, max((viewportSize.height - 1) / 2, 0))
    let visible = CGRect(
      x: horizontalMargin,
      y: verticalMargin,
      width: max(viewportSize.width - horizontalMargin * 2, 1),
      height: max(viewportSize.height - verticalMargin * 2, 1))
    let rendered = CGRect(
      x: frame.minX * safeScale + pan.width + transientPan.width,
      y: frame.minY * safeScale + pan.height + transientPan.height,
      width: frame.width * safeScale,
      height: frame.height * safeScale)

    func adjustment(minimum: CGFloat, maximum: CGFloat,
                    visibleMinimum: CGFloat, visibleMaximum: CGFloat) -> CGFloat {
      if maximum - minimum > visibleMaximum - visibleMinimum {
        return (visibleMinimum + visibleMaximum) / 2 - (minimum + maximum) / 2
      }
      if minimum < visibleMinimum { return visibleMinimum - minimum }
      if maximum > visibleMaximum { return visibleMaximum - maximum }
      return 0
    }

    let delta = CGSize(
      width: adjustment(
        minimum: rendered.minX, maximum: rendered.maxX,
        visibleMinimum: visible.minX, visibleMaximum: visible.maxX),
      height: adjustment(
        minimum: rendered.minY, maximum: rendered.maxY,
        visibleMinimum: visible.minY, visibleMaximum: visible.maxY))
    guard delta != .zero else { return false }
    pan.width += delta.width
    pan.height += delta.height
    return true
  }
}

enum CanvasRemountTrigger: CaseIterable {
  case theme
  case language
  case systemAppearance
  case fullScreenRecovery
}
