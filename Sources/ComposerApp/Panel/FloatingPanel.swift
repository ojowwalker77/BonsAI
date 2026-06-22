import AppKit

/// Chromeless, normal-level window for BonsAI's board (and its auxiliary dock / settings siblings).
/// Borderless windows return false from `canBecomeKey` by default — hence the override below.
final class FloatingPanel: NSPanel {
  /// The board is the workspace's primary panel. Agent and Settings are separate sibling panels
  /// whose Escape action should close only themselves.
  var isAuxiliaryPanel = false
  /// MANDATORY: a borderless / non-activating panel returns false by default,
  /// so without this the text canvas never gets an insertion point.
  override var canBecomeKey: Bool { true }
  /// The board is a normal main window; the auxiliary dock / settings panels are not.
  override var canBecomeMain: Bool { !isAuxiliaryPanel }

  init(contentRect: NSRect) {
    super.init(
      contentRect: contentRect,
      styleMask: [.borderless],   // a normal (activating) window, not a floating overlay panel
      backing: .buffered,
      defer: false
    )
    isFloatingPanel = false
    becomesKeyOnlyIfNeeded = false
    hidesOnDeactivate = false
    // The canvas owns dragging (pan the board, move cards). Background window-drag would
    // fight every gesture — drag a card and the whole window would move with it.
    isMovableByWindowBackground = false
    isMovable = false
    isReleasedWhenClosed = false
    level = .normal   // a normal Dock-app window, not always-on-top
    // Summon onto whatever Space the user is on (via the hotkey) rather than yanking them to
    // another Space; still allowed to appear over a full-screen app.
    collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
    animationBehavior = .none

    isOpaque = false
    backgroundColor = .clear
    // Let AppKit cast the soft drop shadow that grounds a floating glass panel — it
    // follows the rounded vibrant content's alpha, which a SwiftUI shadow can't (the
    // content fills the window, so a SwiftUI shadow has no margin to bleed into).
    hasShadow = true

    // A command panel is dark glass regardless of system appearance — consistent with
    // the brand-icon color extraction, which already normalizes for a forced-dark panel.
    appearance = NSAppearance(named: .darkAqua)
  }

  /// Escape dismisses when the panel itself is first responder.
  override func cancelOperation(_ sender: Any?) {
    if isAuxiliaryPanel {
      NotificationCenter.default.post(name: .composerDismissDock, object: nil)
    } else {
      (delegate as? PanelController)?.hide()
    }
  }

  /// BonsAI has no menu bar, so app-menu shortcuts don't fire. Catch the board's
  /// shortcuts at the key-window level instead.
  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
    let raw = event.charactersIgnoringModifiers?.lowercased()
    let textIsEditing = firstResponder is NSTextView

    if flags == [.command, .shift], raw == "c" {
      NotificationCenter.default.post(name: .composerCopy, object: nil)
      return true
    }

    if !textIsEditing {
      if flags == [.command], raw == "z" {
        NotificationCenter.default.post(name: .composerUndoBoard, object: nil)
        return true
      }
      if flags == [.command, .shift], raw == "z" {
        NotificationCenter.default.post(name: .composerRedoBoard, object: nil)
        return true
      }
      if flags == [.command], raw == "g" {
        NotificationCenter.default.post(name: .composerGroupSelection, object: nil)
        return true
      }
      if flags == [.command, .shift], raw == "g" {
        NotificationCenter.default.post(name: .composerUngroupSelection, object: nil)
        return true
      }
      if flags == [.command], raw == "l" {
        NotificationCenter.default.post(name: .composerLockSelection, object: nil)
        return true
      }
      if flags == [.command, .shift], raw == "l" {
        NotificationCenter.default.post(name: .composerUnlockSelection, object: nil)
        return true
      }
      if flags == [.command], raw == "a" {
        NotificationCenter.default.post(name: .composerSelectAllCards, object: nil)
        return true
      }
      if flags == [.command], raw == "c" {
        NotificationCenter.default.post(name: .composerCopySelection, object: nil)
        return true
      }
      if flags == [.command], raw == "v" {
        NotificationCenter.default.post(name: .composerPasteSelection, object: nil)
        return true
      }
      if flags == [.command], raw == "d" {
        NotificationCenter.default.post(name: .composerDuplicateSelection, object: nil)
        return true
      }
    }

    // Compile the whole board into one paste-ready draft: ⌘R (refine→compile) or ⌘↩.
    if flags == [.command], raw == "r" || raw == "\r" {
      NotificationCenter.default.post(name: .composerCompileBoard, object: nil)
      return true
    }

    if flags == [.command], raw == "[" {
      NotificationCenter.default.post(name: .composerPrevDump, object: nil)
      return true
    }
    if flags == [.command], raw == "]" {
      NotificationCenter.default.post(name: .composerNextDump, object: nil)
      return true
    }
    if flags == [.command], raw == "n" {
      NotificationCenter.default.post(name: .composerNewDump, object: nil)
      return true
    }
    if flags == [.command], raw == "," {
      NotificationCenter.default.post(name: .composerShowSettings, object: nil)
      return true
    }
    if flags == [.command], raw == "j" {
      NotificationCenter.default.post(name: .composerToggleAgent, object: nil)
      return true
    }
    // ⌘K summons the command palette. Only the board panel owns it — the auxiliary agent/settings
    // panels would open it in a window that isn't key, leaving the search field unfocusable.
    if flags == [.command], raw == "k", !isAuxiliaryPanel {
      NotificationCenter.default.post(name: .composerTogglePalette, object: nil)
      return true
    }

    if ComposerPreferences.handleEditorFontKeyEquivalent(event) { return true }

    if flags == [.command], raw == "-" {
      NotificationCenter.default.post(name: .composerZoomOut, object: nil)
      return true
    }
    if flags == [.command], raw == "=" || raw == "+" {
      NotificationCenter.default.post(name: .composerZoomIn, object: nil)
      return true
    }
    if flags == [.command], raw == "0" {
      NotificationCenter.default.post(name: .composerZoomReset, object: nil)
      return true
    }
    // ⌘1–⌘8 pick a tool (select, text, rectangle, ellipse, diamond, line, arrow, freehand).
    if flags == [.command], let raw, let index = Int(raw), (1...8).contains(index) {
      NotificationCenter.default.post(name: .composerSelectTool, object: nil, userInfo: ["index": index])
      return true
    }

    return super.performKeyEquivalent(with: event)
  }

  override func keyDown(with event: NSEvent) {
    let raw = event.charactersIgnoringModifiers
    let textIsEditing = firstResponder is NSTextView
    if !textIsEditing, raw == " " {
      NotificationCenter.default.post(
        name: .composerSpaceKeyChanged,
        object: nil,
        userInfo: ["down": true]
      )
      return
    }
    if !textIsEditing, raw == "\u{1b}" {
      NotificationCenter.default.post(name: .composerEscapeBoard, object: nil)
      return
    }
    if !textIsEditing, raw == "\u{7f}" || raw == "\u{08}" {
      NotificationCenter.default.post(name: .composerDeleteSelection, object: nil)
      return
    }
    super.keyDown(with: event)
  }

  override func keyUp(with event: NSEvent) {
    if !(firstResponder is NSTextView), event.charactersIgnoringModifiers == " " {
      NotificationCenter.default.post(
        name: .composerSpaceKeyChanged,
        object: nil,
        userInfo: ["down": false]
      )
      return
    }
    super.keyUp(with: event)
  }
}
