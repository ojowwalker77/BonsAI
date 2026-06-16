import AppKit
import SwiftUI

/// Owns the single reusable floating panel: summon/dismiss, animation,
/// center-on-mouse, focus, and click-away dismissal.
@MainActor
final class PanelController: NSObject, NSWindowDelegate {
  private var panel: FloatingPanel?
  var isVisible: Bool { panel?.isVisible ?? false }

  override init() {
    super.init()
    NotificationCenter.default.addObserver(
      self, selector: #selector(handleDismiss), name: .composerDismiss, object: nil)
  }

  @objc private func handleDismiss() { hide() }

  func toggle() { isVisible ? hide() : show() }

  func show() {
    let panel = self.panel ?? makePanel()
    self.panel = panel
    positionCentered(panel)

    panel.alphaValue = 0
    panel.contentView?.wantsLayer = true
    panel.contentView?.layer?.transform = CATransform3DMakeScale(0.97, 0.97, 1)

    // Key WITHOUT activating Composer: the previous app stays frontmost.
    panel.makeKeyAndOrderFront(nil)
    panel.orderFrontRegardless()
    focusEditor(in: panel)

    if reduceMotion {
      panel.alphaValue = 1
      panel.contentView?.layer?.transform = CATransform3DIdentity
    } else {
      NSAnimationContext.runAnimationGroup { ctx in
        ctx.duration = 0.26
        ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
        panel.animator().alphaValue = 1
        panel.contentView?.layer?.transform = CATransform3DIdentity
      }
    }
  }

  func hide() {
    guard let panel, panel.isVisible else { return }
    guard !reduceMotion else {
      panel.orderOut(nil)
      panel.contentView?.layer?.transform = CATransform3DIdentity
      return
    }
    NSAnimationContext.runAnimationGroup({ ctx in
      ctx.duration = Theme.Motion.dismissDuration
      ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
      panel.animator().alphaValue = 0
      panel.contentView?.layer?.transform = CATransform3DMakeScale(0.97, 0.97, 1)
    }, completionHandler: {
      MainActor.assumeIsolated {
        panel.orderOut(nil)
        panel.contentView?.layer?.transform = CATransform3DIdentity
      }
    })
  }

  // MARK: Build

  private func makePanel() -> FloatingPanel {
    let panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 720, height: 480))
    panel.delegate = self

    let host = NSHostingView(rootView: ComposerCanvas())
    host.translatesAutoresizingMaskIntoConstraints = false

    let container = NSView()
    container.wantsLayer = true
    container.layer?.backgroundColor = NSColor.clear.cgColor
    container.layer?.cornerRadius = Theme.Radius.panel
    container.layer?.cornerCurve = .continuous
    container.layer?.masksToBounds = false
    container.addSubview(host)
    NSLayoutConstraint.activate([
      host.topAnchor.constraint(equalTo: container.topAnchor),
      host.bottomAnchor.constraint(equalTo: container.bottomAnchor),
      host.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      host.trailingAnchor.constraint(equalTo: container.trailingAnchor),
    ])
    panel.contentView = container
    return panel
  }

  // MARK: Placement

  private func positionCentered(_ panel: NSPanel) {
    let mouse = NSEvent.mouseLocation
    let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
      ?? NSScreen.main ?? NSScreen.screens.first
    guard let visible = screen?.visibleFrame else { panel.center(); return }
    let w = min(max(visible.width * Theme.Size.widthFraction, Theme.Size.minWidth), Theme.Size.maxWidth)
    let h = min(max(visible.height * Theme.Size.heightFraction, Theme.Size.minHeight), Theme.Size.maxHeight)
    let x = visible.midX - w / 2
    let y = visible.midY - h / 2 + h * Theme.Size.opticalLift
    panel.setFrame(NSRect(x: x.rounded(), y: y.rounded(), width: w, height: h), display: true)
  }

  // MARK: Focus the text view so typing works the instant the panel appears.

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

  // MARK: Click-away dismissal

  func windowDidResignKey(_ notification: Notification) {
    hide()
  }

  private var reduceMotion: Bool {
    NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
  }
}
