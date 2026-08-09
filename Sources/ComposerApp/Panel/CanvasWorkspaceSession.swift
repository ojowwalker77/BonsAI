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
}

enum CanvasRemountTrigger: CaseIterable {
  case theme
  case language
  case systemAppearance
  case fullScreenRecovery
}
