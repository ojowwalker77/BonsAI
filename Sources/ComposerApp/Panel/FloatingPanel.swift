import AppKit

/// Non-activating, always-on-top, chromeless panel that can still take keystrokes.
final class FloatingPanel: NSPanel {
  /// MANDATORY: a borderless / non-activating panel returns false by default,
  /// so without this the text canvas never gets an insertion point.
  override var canBecomeKey: Bool { true }
  /// Not required for typing. false → the user's previous app keeps main-window status.
  override var canBecomeMain: Bool { false }

  init(contentRect: NSRect) {
    super.init(
      contentRect: contentRect,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    isFloatingPanel = true
    becomesKeyOnlyIfNeeded = false
    hidesOnDeactivate = false
    isMovableByWindowBackground = true
    isReleasedWhenClosed = false
    level = .floating
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    animationBehavior = .none

    isOpaque = false
    backgroundColor = .clear
    hasShadow = false

    // Force dark at the window level so semantic label colors resolve light-on-dark
    // (matches the .hudWindow material).
    appearance = NSAppearance(named: .darkAqua)
  }

  /// Escape dismisses when the panel itself is first responder.
  override func cancelOperation(_ sender: Any?) {
    (delegate as? PanelController)?.hide()
  }

  /// The app is non-activating, so app-menu shortcuts don't fire. Catch ⇧⌘C here
  /// (copy self-contained text) at the key window level instead.
  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
    if flags == [.command, .shift], event.charactersIgnoringModifiers?.lowercased() == "c" {
      NotificationCenter.default.post(name: .composerCopy, object: nil)
      return true
    }
    return super.performKeyEquivalent(with: event)
  }
}
