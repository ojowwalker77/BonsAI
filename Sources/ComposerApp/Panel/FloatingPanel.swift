import AppKit

/// BonsAI's board window: a standard titled, resizable macOS window with a full-size content
/// view. Every control floats over the solid canvas inside; the title bar is transparent and the
/// traffic lights are re-laid onto the control row's centerline.
///
/// A real `NSWindow`, NOT an `NSPanel`: the panel superclass was a leftover from the deleted
/// floating-panel mode, and panels get second-class full-screen treatment (transition delegate
/// callbacks and the menu-bar traffic-light reveal misbehave). Everything panel-specific was
/// already being switched off.
final class FloatingPanel: NSWindow {
  /// MANDATORY: full-size-content windows can decline key status in some configurations,
  /// so without this the text canvas never gets an insertion point.
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { true }

  init(contentRect: NSRect) {
    super.init(
      contentRect: contentRect,
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    isReleasedWhenClosed = false
    level = .normal   // a normal Dock-app window, not always-on-top
    animationBehavior = .none
    // Themed at the window level so the adaptive palette resolves app-wide. The default theme is
    // dark — BonsAI's signature look — with System/Light as the user's opt-in (⚙︎ Appearance).
    appearance = ComposerPreferences.effectiveTheme.nsAppearance

    // A real window: the title-bar strip drags it, but the canvas (content view) must not —
    // it owns background drag for panning. Traffic lights float over a full-size content view.
    isMovable = true
    isMovableByWindowBackground = false
    titleVisibility = .hidden
    titlebarAppearsTransparent = true
    title = "BonsAI"
    // MANDATORY for the re-centered traffic lights: AppKit hit-tests and hover-tracks the
    // buttons only INSIDE the titlebar container's bounds. The default container (32pt) ends
    // above the control row's centerline — the moved lights rendered at y −13…+1 in container
    // coords, so hover lit on a 1px sliver and clicks fell through to the board. An empty
    // unified toolbar is the one PUBLIC lever that grows the container (to ~52pt) with AppKit
    // doing the layout natively: no accessory wrapper to swallow clicks (a `.top` accessory's
    // host blocks the buttons; `.left` accessories don't stretch the container at all). The
    // transparent titlebar keeps it invisible.
    toolbar = NSToolbar()
    toolbarStyle = .unified
    collectionBehavior = [.fullScreenPrimary]
    // Non-opaque with a clear backing: the canvas paints its own surface — solid at the default
    // 0 transparency, receding over a behind-window blur as the Settings slider comes up.
    isOpaque = false
    backgroundColor = .clear
    hasShadow = true
  }

  /// Put the traffic lights on the SAME centerline as the floating control row (the Books-style
  /// strip), instead of AppKit's default top-left corner — that mismatch is what made the top-left
  /// read as two unrelated rows. Lights start at the shared edge inset, so lights and pills all
  /// sit on one spacing grid. AppKit resets these frames on resize and key-state changes, so the
  /// controller re-calls this after each.
  func layoutWindowChromeButtons() {
    guard !styleMask.contains(.fullScreen) else { return }
    let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
    guard let container = standardWindowButton(.closeButton)?.superview else { return }
    // Center of the floating control row: edge inset + half the pill height.
    let rowCenterY = WindowChrome.edgeInset + (WindowChrome.controlHeight + WindowChrome.padV * 2) / 2
    var x = WindowChrome.edgeInset
    for type in buttons {
      guard let button = standardWindowButton(type) else { continue }
      let y = container.isFlipped
        ? rowCenterY - button.frame.height / 2
        : container.frame.height - rowCenterY - button.frame.height / 2
      button.setFrameOrigin(NSPoint(x: x, y: y))
      x += button.frame.width + 6
    }
    // The rollover highlight is driven by tracking areas the theme frame computed for the
    // DEFAULT button positions — moving the buttons alone leaves the hover region at the old
    // corner (hover lights up above the lights, clicks land on them). Ask every ancestor to
    // rebuild its tracking areas from the frames we just set so hover and hit area coincide.
    var ancestor: NSView? = container
    while let view = ancestor {
      view.updateTrackingAreas()
      ancestor = view.superview
    }
  }

  /// Escape hides the window when it is itself first responder.
  override func cancelOperation(_ sender: Any?) {
    (delegate as? PanelController)?.hide()
  }

  /// Losing key status mid-press can swallow the space `keyUp`, which would otherwise leave the
  /// board stuck in pan mode (open-hand cursor, cards non-interactive). Clear the space latch so it
  /// resets — mirroring a `keyUp` — the moment focus leaves.
  override func resignKey() {
    super.resignKey()
    NotificationCenter.default.post(
      name: .composerSpaceKeyChanged,
      object: nil,
      userInfo: ["down": false]
    )
  }

  /// BonsAI has no menu bar, so app-menu shortcuts don't fire. Catch the board's
  /// shortcuts at the key-window level instead.
  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
    let raw = event.charactersIgnoringModifiers?.lowercased()
    let textIsEditing = firstResponder is NSTextView

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

    // ⌃⌘1 / ⌃⌘2 / ⌃⌘3: pick the app-wide body font (San Francisco / Nohemi / Satoshi). An
    // app-level combo, so it works regardless of text-editing state — the exact `[.control,
    // .command]` flag match keeps it clear of the plain ⌘1–⌘8 tool switch below.
    if flags == [.control, .command], let raw,
       let family: ComposerFontFamily = raw == "1" ? .system : (raw == "2" ? .nohemi : (raw == "3" ? .satoshi : nil)) {
      ComposerPreferences.appFontFamily = family
      NotificationCenter.default.post(name: .composerFontFamilyChanged, object: nil)
      return true
    }

    // ⇧⌘F: focus-write the current card (works while the editor has the keyboard).
    if flags == [.command, .shift], raw == "f" {
      NotificationCenter.default.post(name: .composerToggleFocus, object: nil)
      return true
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
    // ⌘K summons the command palette.
    if flags == [.command], raw == "k" {
      NotificationCenter.default.post(name: .composerTogglePalette, object: nil)
      return true
    }

    // ⌘+/⌘−/⌘0 zoom the canvas — the documented behavior. Shift is accepted because "+" IS ⇧= on
    // most layouts, so "⌘+" arrives as [.command, .shift] + "=". (These keys used to fall through
    // to the app-wide editor font size first, which read as "resizing one text box resizes all" —
    // the global text size now lives in Settings ▸ Appearance, and per-box sizing is tracked
    // separately.)
    if flags == [.command] || flags == [.command, .shift] {
      if raw == "-" || modifiedCharacters(event) == "_" {
        NotificationCenter.default.post(name: .composerZoomOut, object: nil)
        return true
      }
      if raw == "=" || raw == "+" || modifiedCharacters(event) == "+" {
        NotificationCenter.default.post(name: .composerZoomIn, object: nil)
        return true
      }
    }
    if flags == [.command], raw == "0" {
      NotificationCenter.default.post(name: .composerZoomReset, object: nil)
      return true
    }
    // ⌘1–⌘9 pick a tool (select, text, rectangle, ellipse, diamond, line, arrow, freehand, equation).
    if flags == [.command], let raw, let index = Int(raw), (1...9).contains(index) {
      NotificationCenter.default.post(name: .composerSelectTool, object: nil, userInfo: ["index": index])
      return true
    }

    return super.performKeyEquivalent(with: event)
  }

  /// The event's characters WITH modifiers applied — how "⌘⇧=" reads as "⌘+" on layouts where
  /// "+" lives on shifted "=".
  private func modifiedCharacters(_ event: NSEvent) -> String? {
    event.characters?.lowercased()
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
