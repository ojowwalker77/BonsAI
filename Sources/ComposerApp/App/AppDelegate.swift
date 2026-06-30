import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  let panelController = PanelController()
  private let hotKeyManager = HotKeyManager()
  private let menuBarController = MenuBarController()
  /// Held strongly so it keeps firing — a `DispatchSourceSignal` is cancelled on dealloc.
  private var sigtermSource: DispatchSourceSignal?

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
    hotKeyManager.register()
    menuBarController.install()
    _ = EngineCapabilityStore.shared
    _ = UpdaterController.shared
    MentionStyleCache.shared.preload()
    CanvasServer.shared.start()
    installSigtermHandler()

    NSApp.servicesProvider = self

    NotificationCenter.default.addObserver(
      self, selector: #selector(toggle),
      name: .composerToggleWindow, object: nil)
    NotificationCenter.default.addObserver(
      self, selector: #selector(showBoard),
      name: .composerShowWindow, object: nil)
    NotificationCenter.default.addObserver(
      self, selector: #selector(captureToBoard),
      name: .composerCaptureToBoard, object: nil)

    panelController.show()
  }

  /// The board autosaves on a ~400ms debounce; without this, an edit made just before quit
  /// (e.g. a `delete`/`add_text` op from an external agent over the canvas API) is silently
  /// lost because the pending save's timer never gets to fire.
  func applicationWillTerminate(_ notification: Notification) {
    CanvasBridge.shared.flush()
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
    if !hasVisibleWindows { panelController.show() }
    return true
  }

  func application(_ application: NSApplication, open urls: [URL]) {
    for url in urls { handleURL(url) }
  }

  @objc private func toggle() { panelController.toggle() }
  @objc private func showBoard() { panelController.show() }

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

  /// A bare `SIGTERM` (e.g. `pkill`, used by the dev-loop relaunch script) bypasses AppKit's
  /// termination delegate entirely by default, so `applicationWillTerminate` would never run and
  /// a pending autosave would never flush. Disarm the default disposition and re-route the signal
  /// through the normal `NSApp.terminate` path so it does.
  private func installSigtermHandler() {
    signal(SIGTERM, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    source.setEventHandler { NSApp.terminate(nil) }
    source.resume()
    sigtermSource = source
  }

  /// Summon the board (if hidden) and open its companion Settings window.
  func showSettings() {
    panelController.show()
    NotificationCenter.default.post(name: .composerShowSettings, object: nil)
  }

  /// Services menu: "BonsAI → Send to BonsAI" on selected text in any app.
  @objc func captureFromService(_ pboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString?>?) {
    guard let text = pboard.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      error?.pointee = "No text was selected." as NSString
      return
    }
    panelController.show()
    CaptureInbox.shared.enqueue(text)
  }

  private func handleURL(_ url: URL) {
    guard url.scheme?.lowercased() == "bonsai" else { return }
    panelController.show()
    switch url.host?.lowercased() {
    case "capture":
      if let text = URLComponents(url: url, resolvingAgainstBaseURL: false)?
        .queryItems?.first(where: { $0.name == "text" })?.value,
         !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        CaptureInbox.shared.enqueue(text)
      }
    default:
      break
    }
  }
}
