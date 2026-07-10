import AppKit
import SwiftUI

/// Menu-bar quick capture: one line → a new card on the current board.
@MainActor
final class MenuBarController: NSObject {
  private var statusItem: NSStatusItem?
  private var capturePanel: NSPanel?
  private var captureField: NSTextField?

  func install() {
    guard statusItem == nil else { return }
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    if let button = item.button {
      button.image = Self.menuBarIcon()
      button.image?.isTemplate = true
      button.toolTip = "BonsAI - quick capture".localizedUI
      button.target = self
      button.action = #selector(toggleCapturePanel)
    }
    statusItem = item
  }

  /// The BonsAI tree mark, rendered as a template image so the menu bar tints it for light/dark.
  /// The bundled PNG is @2x (36px); we pin the logical size to 18pt so it stays crisp on Retina.
  /// Falls back to a leaf glyph if the resource is ever missing.
  private static func menuBarIcon() -> NSImage? {
    if let url = Bundle.appResources.url(forResource: "MenuBarIcon", withExtension: "png"),
       let image = NSImage(contentsOf: url) {
      image.size = NSSize(width: 18, height: 18)
      return image
    }
    return NSImage(systemSymbolName: "leaf.fill", accessibilityDescription: "BonsAI")
  }

  @objc private func toggleCapturePanel() {
    if let panel = capturePanel, panel.isVisible {
      panel.orderOut(nil)
      return
    }
    showCapturePanel()
  }

  private func showCapturePanel() {
    let panel = capturePanel ?? makeCapturePanel()
    capturePanel = panel
    // Re-themed on every show (not just on make): the panel is cached, so this is where a theme
    // switched since the last capture catches up.
    applyTheme(to: panel)
    positionCapturePanel(panel)
    panel.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    captureField?.becomeFirstResponder()
    captureField?.selectText(nil)
  }

  /// Paint the capture panel from the active flavor — the same tokens as the board, so the quick
  /// entry reads as a shard of the app, not a system dialog. Without this the field kept AppKit's
  /// defaults, which rendered near-black placeholder/hint text on the dark themes.
  private func applyTheme(to panel: NSPanel) {
    panel.appearance = ComposerPreferences.effectiveTheme.nsAppearance
    panel.backgroundColor = Theme.nsWindowCanvas.withAlphaComponent(0.94)
    guard let field = captureField else { return }
    let font = ComposerPreferences.appFont(ofSize: 14)
    field.font = font
    field.textColor = Theme.nsBodyText
    field.placeholderAttributedString = NSAttributedString(
      string: "Capture a thought...  Return to send".localizedUI,
      attributes: [.foregroundColor: Theme.nsPlaceholderText, .font: font])
  }

  private func makeCapturePanel() -> NSPanel {
    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 420, height: 52),
      styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
      backing: .buffered,
      defer: false)
    panel.titleVisibility = .hidden
    panel.titlebarAppearsTransparent = true
    panel.isFloatingPanel = true
    panel.level = .floating
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.isMovableByWindowBackground = true
    panel.hasShadow = true

    let field = NSTextField(string: "")
    field.isBordered = false
    field.backgroundColor = .clear
    field.focusRingType = .none
    field.target = self
    field.action = #selector(submitCapture)
    captureField = field

    let container = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 52))
    field.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(field)
    NSLayoutConstraint.activate([
      field.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
      field.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
      field.centerYAnchor.constraint(equalTo: container.centerYAnchor),
    ])
    panel.contentView = container
    return panel
  }

  private func positionCapturePanel(_ panel: NSPanel) {
    guard let button = statusItem?.button, let screen = button.window?.screen ?? NSScreen.main else { return }
    let buttonFrame = button.convert(button.bounds, to: nil)
    let screenFrame = button.window?.convertToScreen(buttonFrame) ?? .zero
    var origin = NSPoint(
      x: screenFrame.midX - panel.frame.width / 2,
      y: screenFrame.minY - panel.frame.height - 6)
    origin.x = max(screen.visibleFrame.minX + 8,
                   min(origin.x, screen.visibleFrame.maxX - panel.frame.width - 8))
    panel.setFrameOrigin(origin)
  }

  @objc private func submitCapture() {
    guard let text = captureField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
          !text.isEmpty else { return }
    captureField?.stringValue = ""
    capturePanel?.orderOut(nil)
    NotificationCenter.default.post(name: .composerShowWindow, object: nil)
    CaptureInbox.shared.enqueue(text)
  }
}
