import Foundation

extension Notification.Name {
  static let composerShowWindow = Notification.Name("composerShowWindow")
  /// Dump-stack navigation: ⌘[ older, ⌘] newer, ⌘N new dump.
  static let composerPrevDump = Notification.Name("composerPrevDump")
  static let composerNextDump = Notification.Name("composerNextDump")
  static let composerNewDump = Notification.Name("composerNewDump")
  /// Board editing commands. The canvas ignores destructive commands while text is editing.
  static let composerDeleteSelection = Notification.Name("composerDeleteSelection")
  static let composerDuplicateSelection = Notification.Name("composerDuplicateSelection")
  static let composerCopySelection = Notification.Name("composerCopySelection")
  static let composerPasteSelection = Notification.Name("composerPasteSelection")
  static let composerSelectAllCards = Notification.Name("composerSelectAllCards")
  static let composerEscapeBoard = Notification.Name("composerEscapeBoard")
  static let composerUndoBoard = Notification.Name("composerUndoBoard")
  static let composerRedoBoard = Notification.Name("composerRedoBoard")
  static let composerGroupSelection = Notification.Name("composerGroupSelection")
  static let composerUngroupSelection = Notification.Name("composerUngroupSelection")
  static let composerLockSelection = Notification.Name("composerLockSelection")
  static let composerUnlockSelection = Notification.Name("composerUnlockSelection")
  /// Canvas viewport commands.
  static let composerZoomOut = Notification.Name("composerZoomOut")
  static let composerZoomIn = Notification.Name("composerZoomIn")
  static let composerZoomReset = Notification.Name("composerZoomReset")
  static let composerZoomFit = Notification.Name("composerZoomFit")
  static let composerSpaceKeyChanged = Notification.Name("composerSpaceKeyChanged")
  /// Forwarded from a card when the cursor is over it, so two-finger scroll / pinch still pans
  /// and zooms the board instead of dead-ending on an (unselected) element.
  static let composerCanvasScroll = Notification.Name("composerCanvasScroll")
  static let composerCanvasMagnify = Notification.Name("composerCanvasMagnify")
  /// Number shortcuts use a 1-based `index`; named shortcuts such as P carry a `CanvasTool`.
  static let composerSelectTool = Notification.Name("composerSelectTool")
  /// ⌘K "Add point to graph…": the graph card whose id matches `object` (a UUID) opens its Point
  /// Composer seeded at the middle of its axis ranges.
  static let composerAddGraphPoint = Notification.Name("composerAddGraphPoint")
  /// ⌘K toggles the command palette (board switcher + buried board-level actions).
  static let composerTogglePalette = Notification.Name("composerTogglePalette")
  /// ⇧⌘F expands the current text card into the centered focus-writing sheet (and back).
  static let composerToggleFocus = Notification.Name("composerToggleFocus")
  /// Opens the in-canvas Settings overlay (command-bar gear or ⌘,).
  static let composerShowSettings = Notification.Name("composerShowSettings")
  /// Fires after ⌘+/⌘− or Settings changes the editor point size.
  static let composerFontSizeChanged = Notification.Name("composerFontSizeChanged")
  /// Re-bind the "Snap to board" hotkey after the user records a new shortcut in Settings.
  static let composerShortcutChanged = Notification.Name("composerShortcutChanged")
  /// Fires when the app-wide theme (System / Light / Dark) changes. The board window remounts its
  /// SwiftUI root with the same retained workspace after synchronously flushing pending edits.
  static let composerThemeChanged = Notification.Name("composerThemeChanged")
  /// Fires when the app-wide body font family changes — the canvas rebuilds (like a theme switch)
  /// so measurement caches and chrome labels re-resolve against the new face.
  static let composerFontFamilyChanged = Notification.Name("composerFontFamilyChanged")
  /// Fires when the app language override changes — the canvas rebuilds so localized labels
  /// re-resolve immediately.
  static let composerLanguageChanged = Notification.Name("composerLanguageChanged")
  /// Fires on the capture hotkey ("Snap to board") — grab a screen region, understand it on-device,
  /// and drop it on the board as an agent-ready card.
  /// Q: toggle whether a drawing tool stays active after each placement (Excalidraw's tool lock).
  static let composerToggleToolLock = Notification.Name("composerToggleToolLock")
  static let composerCaptureToBoard = Notification.Name("composerCaptureToBoard")
  /// Fires after a region was captured and saved; `userInfo["path"]` is the PNG. The board adds the
  /// image card here and kicks off its on-device understanding.
  static let composerCaptureCompleted = Notification.Name("composerCaptureCompleted")
}

/// The single Escape priority order for the board workspace. Keeping the decision independent from
/// SwiftUI state mutations makes key routing deterministic and testable at the surface boundary.
enum ComposerEscapeTarget: Equatable {
  case boardDeletionConfirmation
  case boardRename
  case boardPicker
  case commandPalette
  case focusedEditor
  case promotion
  case auxiliaryPanel
  case activeEditor
  case drawingDraft
  case tintPicker
  case activeTool
  case selection
  /// Nothing to dismiss. BonsAI is a standard window, so a spare Escape never hides it.
  case none
}

struct ComposerEscapeState: Equatable {
  var hasBoardDeletionConfirmation = false
  var hasBoardRename = false
  var hasBoardPicker = false
  var hasCommandPalette = false
  var hasFocusedEditor = false
  var hasPromotion = false
  var hasSettings = false
  var hasActiveEditor = false
  /// Vector editing is inline and can coexist with a newly started Pen draft. In that one case the
  /// live pointer draft owns Escape; text and structured editors still keep their normal priority.
  var hasActiveVectorEditor = false
  var hasDrawingDraft = false
  var hasTintPicker = false
  var hasActiveTool = false
  var hasSelection = false
}

enum ComposerEscapeCoordinator {
  static func target(for state: ComposerEscapeState) -> ComposerEscapeTarget {
    if state.hasBoardDeletionConfirmation { return .boardDeletionConfirmation }
    if state.hasBoardRename { return .boardRename }
    // A hover-open picker must not conceal a live Pen/vector gesture from Escape. Cancel the draft
    // first when the canvas owns it outright, or when it coexists with the inline vector editor.
    // Text and structured editors retain their established priority over incidental draft state.
    if state.hasBoardPicker,
       state.hasDrawingDraft,
       !state.hasActiveEditor || state.hasActiveVectorEditor {
      return .drawingDraft
    }
    if state.hasBoardPicker { return .boardPicker }
    if state.hasCommandPalette { return .commandPalette }
    if state.hasFocusedEditor { return .focusedEditor }
    if state.hasPromotion { return .promotion }
    if state.hasSettings { return .auxiliaryPanel }
    if state.hasActiveVectorEditor && state.hasDrawingDraft { return .drawingDraft }
    if state.hasActiveEditor { return .activeEditor }
    if state.hasDrawingDraft { return .drawingDraft }
    if state.hasTintPicker { return .tintPicker }
    if state.hasActiveTool { return .activeTool }
    if state.hasSelection { return .selection }
    return .none
  }
}
