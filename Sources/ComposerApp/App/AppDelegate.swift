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
    NotificationCenter.default.addObserver(
      self, selector: #selector(captureToBoard),
      name: .composerCaptureToBoard, object: nil)

    // Surface the board on launch.
    panelController.show()
  }

  /// Clicking the Dock icon when nothing is visible re-summons the board (standard Dock behavior).
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
    if !hasVisibleWindows { panelController.show() }
    return true
  }

  @objc private func toggle() { panelController.toggle() }

  /// "Snap to board": run the region capture overlay, save the shot, summon the board, and hand the
  /// PNG to the canvas to add the card and read it on-device. Capture runs above all apps, so this
  /// works even when BonsAI isn't frontmost.
  @objc private func captureToBoard() {
    Task { @MainActor in
      guard let cgImage = await ScreenCaptureService.shared.capture() else { return }
      // Encode the PNG off the main thread (a retina region is multi-MB); the board reuses the
      // in-memory image for OCR, so it never re-decodes this file.
      guard let url = await Task.detached(priority: .userInitiated, operation: { saveCapturedPNG(cgImage) }).value else { return }
      CapturedShotStore.shared.stash(cgImage, for: url.path)
      panelController.show()
      NotificationCenter.default.post(
        name: .composerCaptureCompleted, object: nil, userInfo: ["path": url.path])
    }
  }

  /// Summon the board (if hidden) and open its companion Settings window.
  func showSettings() {
    panelController.show()
    NotificationCenter.default.post(name: .composerShowSettings, object: nil)
  }
}
