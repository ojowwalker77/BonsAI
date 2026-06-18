import AppKit
import SwiftUI

/// Owns the single reusable floating panel: summon/dismiss, animation,
/// center-on-mouse, focus, and click-away dismissal.
@MainActor
final class PanelController: NSObject, NSWindowDelegate {
  private var panel: FloatingPanel?
  /// True while a refine is in flight — suppresses click-away dismissal so the panel
  /// never vanishes mid-work and drops the result.
  private var isBusy = false
  var isVisible: Bool { panel?.isVisible ?? false }

  override init() {
    super.init()
    NotificationCenter.default.addObserver(
      self, selector: #selector(handleDismiss), name: .composerDismiss, object: nil)
    NotificationCenter.default.addObserver(
      forName: .composerBusyChanged, object: nil, queue: .main
    ) { [weak self] note in
      MainActor.assumeIsolated { self?.isBusy = (note.userInfo?["busy"] as? Bool) ?? false }
    }
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
    // The active card's editor only exists once SwiftUI mounts it, so ask the canvas to enter
    // editing — the caret is ready to type the instant the panel appears (no double-click).
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
      NotificationCenter.default.post(name: .composerEnterEditing, object: nil)
    }

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

    let container = NonMovableView()
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
    // The whole panel fills ~95% of the visible screen, centered. The card auto-derives from
    // the window size minus the rail/toolbar gutters (handled by the canvas layout).
    let w = (visible.width * Theme.Size.screenFraction).rounded()
    let winH = (visible.height * Theme.Size.screenFraction).rounded()
    let x = (visible.midX - w / 2).rounded()
    let y = (visible.midY - winH / 2).rounded()
    panel.setFrame(NSRect(x: x, y: y, width: w, height: winH), display: true)
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
    guard !isBusy else { return }
    hide()
  }

  private var reduceMotion: Bool {
    NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
  }
}

/// Host container that never lets a click-drag move the window — the canvas owns all dragging.
private final class NonMovableView: NSView {
  override var mouseDownCanMoveWindow: Bool { false }
}
