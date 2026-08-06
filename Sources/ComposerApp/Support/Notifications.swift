import Foundation

extension Notification.Name {
  static let composerToggleWindow = Notification.Name("composerToggleWindow")
  static let composerShowWindow = Notification.Name("composerShowWindow")
  static let composerDismiss = Notification.Name("composerDismiss")
  /// Fires on ⌘R / ⌘↩ — compile the whole board into one paste-ready draft.
  static let composerCompileBoard = Notification.Name("composerCompileBoard")
  /// Fires when a refine starts/ends; userInfo["busy"] gates click-away dismissal.
  static let composerBusyChanged = Notification.Name("composerBusyChanged")
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
  /// Posted when the panel is summoned — the canvas enters editing on the active card so the
  /// caret is ready and you can type immediately, without double-clicking first.
  static let composerEnterEditing = Notification.Name("composerEnterEditing")
  /// ⌘1–⌘8 pick a canvas tool; userInfo["index"] is 1-based (1 = select, 2 = text, …).
  static let composerSelectTool = Notification.Name("composerSelectTool")
  /// ⌘K "Add point to graph…": the graph card whose id matches `object` (a UUID) opens its Point
  /// Composer seeded at the middle of its axis ranges.
  static let composerAddGraphPoint = Notification.Name("composerAddGraphPoint")
  /// ⌘J toggles the separate agent panel.
  static let composerToggleAgent = Notification.Name("composerToggleAgent")
  /// ⌘K toggles the command palette (board switcher + buried board-level actions).
  static let composerTogglePalette = Notification.Name("composerTogglePalette")
  /// ⇧⌘F expands the current text card into the centered focus-writing sheet (and back).
  static let composerToggleFocus = Notification.Name("composerToggleFocus")
  /// Opens the separate Settings panel (sidebar gear, ⌘, or the menu-bar item).
  static let composerShowSettings = Notification.Name("composerShowSettings")
  /// Fires after ⌘+/⌘− or Settings changes the editor point size.
  static let composerFontSizeChanged = Notification.Name("composerFontSizeChanged")
  /// Fires when MentionStyleCache gains a favicon/brand color (e.g. for the Settings Apps list).
  static let composerStyleCacheUpdated = Notification.Name("composerStyleCacheUpdated")
  /// Re-bind the global summon hotkey after the user records a new shortcut in Settings.
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
  static let composerCaptureToBoard = Notification.Name("composerCaptureToBoard")
  /// Fires after a region was captured and saved; `userInfo["path"]` is the PNG. The board adds the
  /// image card here and kicks off its on-device understanding.
  static let composerCaptureCompleted = Notification.Name("composerCaptureCompleted")
  /// Quick capture from the menu bar, Services menu, URL scheme, or loopback API.
  static let composerQuickCapture = Notification.Name("composerQuickCapture")
}

/// The single Escape priority order for the board workspace. Keeping the decision independent from
/// SwiftUI state mutations makes key routing deterministic and testable at the surface boundary.
enum ComposerEscapeTarget: Equatable {
  case boardDeletionConfirmation
  case boardRename
  case commandPalette
  case focusedEditor
  case compiledOverlay
  case promotion
  case auxiliaryPanel
  case activeEditor
  case drawingDraft
  case activeTool
  case selection
  case windowDismissal
}

struct ComposerEscapeState: Equatable {
  var hasBoardDeletionConfirmation = false
  var hasBoardRename = false
  var hasCommandPalette = false
  var hasFocusedEditor = false
  var hasCompiledOverlay = false
  var hasPromotion = false
  var hasAgent = false
  var hasSettings = false
  var hasActiveEditor = false
  var hasDrawingDraft = false
  var hasActiveTool = false
  var hasSelection = false
}

enum ComposerEscapeCoordinator {
  static func target(for state: ComposerEscapeState) -> ComposerEscapeTarget {
    if state.hasBoardDeletionConfirmation { return .boardDeletionConfirmation }
    if state.hasBoardRename { return .boardRename }
    if state.hasCommandPalette { return .commandPalette }
    if state.hasFocusedEditor { return .focusedEditor }
    if state.hasCompiledOverlay { return .compiledOverlay }
    if state.hasPromotion { return .promotion }
    if state.hasAgent || state.hasSettings { return .auxiliaryPanel }
    if state.hasActiveEditor { return .activeEditor }
    if state.hasDrawingDraft { return .drawingDraft }
    if state.hasActiveTool { return .activeTool }
    if state.hasSelection { return .selection }
    return .windowDismissal
  }
}
