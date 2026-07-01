import AppKit
import SwiftUI

/// Owns BonsAI's single board window: show/hide (the global hotkey toggles it), frame restore,
/// traffic-light layout, theming, and first-responder focus. Agent and Settings are SwiftUI
/// overlays inside the canvas — there are no auxiliary windows.
@MainActor
final class PanelController: NSObject, NSWindowDelegate {
  private var panel: FloatingPanel?
  var isVisible: Bool { panel?.isVisible ?? false }

  override init() {
    super.init()
    NotificationCenter.default.addObserver(
      self, selector: #selector(handleDismiss), name: .composerDismiss, object: nil)
    NotificationCenter.default.addObserver(
      forName: .composerThemeChanged, object: nil, queue: .main
    ) { [weak self] _ in MainActor.assumeIsolated { self?.applyTheme() } }
  }

  @objc private func handleDismiss() { hide() }

  func toggle() { isVisible ? hide() : show() }

  func show() {
    let panel = self.panel ?? makePanel()
    self.panel = panel
    // The window keeps whatever frame the user left it at — no reframing on summon.
    NSApp.activate(ignoringOtherApps: true)
    panel.makeKeyAndOrderFront(nil)
    panel.orderFrontRegardless()
    panel.layoutWindowChromeButtons()
    focusEditor(in: panel)
    // The active card's editor only exists once SwiftUI mounts it, so ask the canvas to enter
    // editing — the caret is ready to type the instant the window appears (no double-click).
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
      NotificationCenter.default.post(name: .composerEnterEditing, object: nil)
    }
  }

  func hide() {
    guard let panel, panel.isVisible else { return }
    panel.orderOut(nil)
    NSApp.deactivate()
  }

  /// Apply the selected theme: set the window's appearance class AND rebuild the canvas —
  /// palette tokens are plain flavor lookups captured at render, so the tree must re-render from
  /// scratch. Board content is store-backed and the agent is a singleton, so nothing is lost.
  private func applyTheme() {
    guard let panel else { return }
    panel.appearance = ComposerPreferences.theme.nsAppearance
    installContent(ComposerCanvas(), in: panel)
    panel.layoutWindowChromeButtons()
  }

  // MARK: Build

  private func makePanel() -> FloatingPanel {
    let panel = FloatingPanel(contentRect: defaultWindowFrame())
    panel.delegate = self
    panel.minSize = NSSize(width: 640, height: 460)
    // Restore (and keep persisting) the size/position the user last left the window at.
    panel.setFrameAutosaveName("BonsAIBoardWindow")
    installContent(ComposerCanvas(), in: panel)
    return panel
  }

  /// A comfortable default the first time the window is shown; superseded thereafter by the
  /// autosaved frame.
  private func defaultWindowFrame() -> NSRect {
    guard let visible = NSScreen.main?.visibleFrame else {
      return NSRect(x: 0, y: 0, width: 1100, height: 720)
    }
    let width = min(1180, visible.width * 0.72).rounded()
    let height = min(820, visible.height * 0.84).rounded()
    return NSRect(
      x: (visible.midX - width / 2).rounded(),
      y: (visible.midY - height / 2).rounded(),
      width: width,
      height: height
    )
  }

  /// A hosted SwiftUI view must not be allowed to infer an AppKit window size — the window is
  /// explicitly framed (and then user-resized).
  private func installContent<Content: View>(_ root: Content, in panel: FloatingPanel) {
    let host = NSHostingView(rootView: root)
    host.translatesAutoresizingMaskIntoConstraints = false
    host.sizingOptions = []

    let container = NonMovableView()
    container.wantsLayer = true
    container.layer?.backgroundColor = NSColor.clear.cgColor
    container.addSubview(host)
    NSLayoutConstraint.activate([
      host.topAnchor.constraint(equalTo: container.topAnchor),
      host.bottomAnchor.constraint(equalTo: container.bottomAnchor),
      host.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      host.trailingAnchor.constraint(equalTo: container.trailingAnchor),
    ])
    panel.contentView = container
  }

  // MARK: NSWindowDelegate — AppKit resets the titlebar buttons; put them back on the control row

  func windowDidResize(_ notification: Notification) { relayoutChromeButtons(notification) }
  func windowDidMove(_ notification: Notification) { relayoutChromeButtons(notification) }
  func windowDidBecomeKey(_ notification: Notification) { relayoutChromeButtons(notification) }
  func windowDidResignKey(_ notification: Notification) { relayoutChromeButtons(notification) }

  private func relayoutChromeButtons(_ notification: Notification) {
    guard let panel, (notification.object as? NSWindow) === panel else { return }
    panel.layoutWindowChromeButtons()
  }

  // MARK: Focus the text view so typing works the instant the window appears.

  private func focusEditor(in panel: NSPanel) {
    guard let content = panel.contentView, let textView = firstTextView(in: content) else { return }
    panel.makeFirstResponder(textView)
  }

  private func firstTextView(in view: NSView) -> NSTextView? {
    if let textView = view as? NSTextView { return textView }
    for sub in view.subviews {
      if let found = firstTextView(in: sub) { return found }
    }
    return nil
  }
}

/// Host container that never lets a click-drag move the window — the canvas owns all dragging.
private final class NonMovableView: NSView {
  override var mouseDownCanMoveWindow: Bool { false }
}
