import Foundation

/// The two auxiliary panels are real AppKit windows, coordinated with the board window rather
/// than rendered inside its SwiftUI hierarchy.
enum ComposerDockKind: String {
  case agent
  case settings
}

extension Notification.Name {
  static let composerToggleWindow = Notification.Name("composerToggleWindow")
  static let composerDismiss = Notification.Name("composerDismiss")
  static let composerCopy = Notification.Name("composerCopy")
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
  /// ⌘J toggles the separate agent panel.
  static let composerToggleAgent = Notification.Name("composerToggleAgent")
  /// ⌘K toggles the command palette (board switcher + buried board-level actions).
  static let composerTogglePalette = Notification.Name("composerTogglePalette")
  /// Opens the separate Settings panel (sidebar gear, ⌘, or the menu-bar item).
  static let composerShowSettings = Notification.Name("composerShowSettings")
  /// Requests an auxiliary panel. `object` is the active `CanvasAgent` for `.agent` and
  /// `userInfo["kind"]` is a `ComposerDockKind.rawValue`.
  static let composerPresentDock = Notification.Name("composerPresentDock")
  /// Requests the currently-visible auxiliary panel to close.
  static let composerDismissDock = Notification.Name("composerDismissDock")
  /// Sent after the panel has closed, so the board can update its toolbar/overlay state.
  static let composerDockDismissed = Notification.Name("composerDockDismissed")
  /// Fires after ⌘+/⌘− or Settings changes the editor point size.
  static let composerFontSizeChanged = Notification.Name("composerFontSizeChanged")
  /// Fires when MentionStyleCache gains a favicon/brand color (e.g. for the Settings Apps list).
  static let composerStyleCacheUpdated = Notification.Name("composerStyleCacheUpdated")
  /// Re-bind the global summon hotkey after the user records a new shortcut in Settings.
  static let composerShortcutChanged = Notification.Name("composerShortcutChanged")
}
