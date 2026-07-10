import AppKit

/// Owns the reparented traffic lights: a plain host on the control row's centerline, OUTSIDE the
/// titlebar (whose 32pt hit-test bounds the buttons overflowed — hover lit on a sliver, clicks
/// fell through; every titlebar-stretching lever failed: an empty toolbar paints Tahoe hover
/// glass behind the floating pills, `.top` accessories swallow clicks, `.left` ones don't
/// stretch). Reparented theme widgets draw their ×−+ glyphs only while their superview answers
/// the private `_mouseInGroup:` query — this host answers it from its own tracking area (the
/// standard recipe for custom traffic-light placement; direct-distribution app, no App Store
/// review concern).
private final class TrafficLightHostView: NSView {
  private var tracking: NSTrackingArea?
  private var mouseInside = false

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let tracking { removeTrackingArea(tracking) }
    let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways],
                              owner: self, userInfo: nil)
    addTrackingArea(area)
    tracking = area
  }

  override func mouseEntered(with event: NSEvent) { setGroupHover(true) }
  override func mouseExited(with event: NSEvent) { setGroupHover(false) }

  private func setGroupHover(_ inside: Bool) {
    mouseInside = inside
    for case let button as NSButton in subviews { button.needsDisplay = true }
  }

  @objc(_mouseInGroup:) func mouseInGroup(_ button: NSButton) -> Bool { mouseInside }

  /// Only the buttons take events — the padding/gaps pass through to the canvas.
  override func hitTest(_ point: NSPoint) -> NSView? {
    let hit = super.hitTest(point)
    return hit === self ? nil : hit
  }
}

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

  /// Hosts the reparented traffic lights on the control row (see TrafficLightHostView).
  private let trafficLightHost = TrafficLightHostView(frame: .zero)
  /// The buttons' native titlebar parent — they return there for full screen, where AppKit
  /// owns their layout (the menu-bar reveal).
  private weak var nativeButtonParent: NSView?

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
    collectionBehavior = [.fullScreenPrimary]
    // Non-opaque with a clear backing: the canvas paints its own surface — solid at the default
    // 0 transparency, receding over a behind-window blur as the Settings slider comes up.
    isOpaque = false
    backgroundColor = .clear
    hasShadow = true
  }

  /// Put the traffic lights on the SAME centerline as the floating control row (the Books-style
  /// strip), instead of AppKit's default top-left corner — that mismatch is what made the top-left
  /// read as two unrelated rows. The buttons are REPARENTED into `trafficLightHost` on the theme
  /// frame (see TrafficLightHostView for why the titlebar can't host them down here), which owns
  /// their hover and hit-testing. Lights start at the shared edge inset, so lights and pills all
  /// sit on one spacing grid. AppKit re-asserts titlebar ownership on some window events, so the
  /// controller re-calls this after each.
  func layoutWindowChromeButtons() {
    guard !styleMask.contains(.fullScreen) else { return }
    let types: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
    let buttons = types.compactMap { standardWindowButton($0) }
    guard buttons.count == types.count, let frameView = contentView?.superview else { return }
    if nativeButtonParent == nil {
      nativeButtonParent = buttons[0].superview
    }

    let spacing: CGFloat = 6
    let pad: CGFloat = 4   // hover grace around the group, passes clicks through
    let buttonSize = buttons[0].frame.size
    let groupWidth = buttons.reduce(0) { $0 + $1.frame.width } + spacing * CGFloat(buttons.count - 1)
    let hostSize = NSSize(width: groupWidth + pad * 2, height: buttonSize.height + pad * 2)
    // Center of the floating control row: edge inset + half the pill height.
    let rowCenterY = WindowChrome.edgeInset + (WindowChrome.controlHeight + WindowChrome.padV * 2) / 2
    let hostY = frameView.isFlipped
      ? rowCenterY - hostSize.height / 2
      : frameView.frame.height - rowCenterY - hostSize.height / 2
    // (Re)attach topmost every pass: a canvas rebuild swaps the content view in above it.
    frameView.addSubview(trafficLightHost)
    trafficLightHost.isHidden = false
    trafficLightHost.frame = NSRect(x: WindowChrome.edgeInset - pad, y: hostY,
                                    width: hostSize.width, height: hostSize.height)

    var x = pad
    for button in buttons {
      if button.superview !== trafficLightHost { trafficLightHost.addSubview(button) }
      button.setFrameOrigin(NSPoint(x: x, y: (hostSize.height - button.frame.height) / 2))
      x += button.frame.width + spacing
    }
    trafficLightHost.updateTrackingAreas()
  }

  /// Hand the lights back to AppKit for full screen: they return to their native titlebar
  /// parent so the menu-bar reveal can lay them out, and the host stands down.
  func returnChromeButtonsToTitlebar() {
    guard let parent = nativeButtonParent else { return }
    for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
      if let button = standardWindowButton(type), button.superview !== parent {
        parent.addSubview(button)
      }
    }
    trafficLightHost.isHidden = true
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
