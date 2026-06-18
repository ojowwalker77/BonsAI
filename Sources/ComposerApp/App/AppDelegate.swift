import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  let panelController = PanelController()
  private let hotKeyManager = HotKeyManager()

  func applicationDidFinishLaunching(_ notification: Notification) {
    // Menu-bar-only by default; COMPOSER_DEBUG_DOCK=1 promotes to a regular app
    // (Dock icon) purely so screenshot/automation tools can see it during testing.
    let debugDock = ProcessInfo.processInfo.environment["COMPOSER_DEBUG_DOCK"] == "1"
    NSApp.setActivationPolicy(debugDock ? .regular : .accessory)   // LSUIElement is the static floor
    if debugDock { NSApp.activate(ignoringOtherApps: true) }
    hotKeyManager.register()
    MentionStyleCache.shared.preload()
    NotificationCenter.default.addObserver(
      self, selector: #selector(toggle),
      name: .composerToggleWindow, object: nil)

    // First launch: surface the panel so the menu-bar-only app isn't invisible.
    panelController.show()
  }

  // Never NSApp.activate(ignoringOtherApps:) — it steals focus and breaks the feel.
  @objc private func toggle() { panelController.toggle() }

  /// Summon the panel (if hidden) and open its in-panel Settings — never a separate window.
  func showSettings() {
    panelController.show()
    NotificationCenter.default.post(name: .composerShowSettings, object: nil)
  }
}
