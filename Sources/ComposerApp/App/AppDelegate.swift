import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  let panelController = PanelController()
  private let hotKeyManager = HotKeyManager()

  func applicationDidFinishLaunching(_ notification: Notification) {
    // BonsAI is a normal Dock app: a real Dock icon and Cmd-Tab presence, with a sticky window
    // that's also summonable by global hotkey.
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
    hotKeyManager.register()
    _ = EngineCapabilityStore.shared   // first-ever launch detects + persists; later launches restore known state (Settings → Recheck re-runs)
    _ = UpdaterController.shared   // starts Sparkle's periodic background update check
    MentionStyleCache.shared.preload()
    CanvasServer.shared.start()   // local API so a CLI / MCP server can read & drive the canvas
    NotificationCenter.default.addObserver(
      self, selector: #selector(toggle),
      name: .composerToggleWindow, object: nil)

    // Surface the board on launch.
    panelController.show()
  }

  /// Clicking the Dock icon when nothing is visible re-summons the board (standard Dock behavior).
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
    if !hasVisibleWindows { panelController.show() }
    return true
  }

  @objc private func toggle() { panelController.toggle() }

  /// Summon the board (if hidden) and open its companion Settings window.
  func showSettings() {
    panelController.show()
    NotificationCenter.default.post(name: .composerShowSettings, object: nil)
  }
}
