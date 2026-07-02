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
    registerBundledFonts()
    hotKeyManager.register()
    menuBarController.install()
    _ = EngineCapabilityStore.shared
    _ = UpdaterController.shared
    MentionStyleCache.shared.preload()
    CanvasServer.shared.start()
    promptForAgentSkillsIfNeeded()
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

  /// Register every bundled `.otf` (Nohemi, Satoshi) so `NSFont(name:)` can resolve the custom
  /// faces the app-font picker selects. The fonts live inside the nested SwiftPM resource bundle;
  /// we iterate whatever `.otf`s it contains rather than hard-coding filenames. Registration is
  /// best-effort — a failure (including "already registered", which the API reports as an error)
  /// is logged and skipped so it can never take launch down; a genuinely missing face just falls
  /// back to the system font at resolve time.
  private func registerBundledFonts() {
    let bundle = Bundle.appResources
    let urls = bundle.urls(forResourcesWithExtension: "otf", subdirectory: nil)
      ?? bundle.urls(forResourcesWithExtension: "otf", subdirectory: "Fonts")
      ?? []
    for url in urls {
      var error: Unmanaged<CFError>?
      if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
        let message = error?.takeRetainedValue().localizedDescription ?? "unknown error"
        NSLog("BonsAI: skipped font registration for \(url.lastPathComponent): \(message)")
      }
    }
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
      // Encode the image off the main thread (a retina region is multi-MB); the board reuses the
      // in-memory image for OCR, so it never re-decodes this file.
      guard let filename = await Task.detached(priority: .userInitiated, operation: { saveCapturedImage(cgImage) }).value else { return }
      CapturedShotStore.shared.stash(cgImage, for: filename)
      panelController.show()
      NotificationCenter.default.post(
        name: .composerCaptureCompleted, object: nil, userInfo: ["path": filename])
    }
  }

  /// First launch only: if a coding agent we know how to teach (Claude Code, Codex CLI, Cursor) is
  /// detected on this Mac, offer to install the canvas-API doc into its config so it can drive the
  /// board over `127.0.0.1:7337` without the user hand-rolling curl commands. Silent no-op if none
  /// are detected, or if the user has already been asked once — re-installs live in Settings ▸
  /// Connectors instead of re-prompting every launch.
  private func promptForAgentSkillsIfNeeded() {
    let promptedKey = "app.agentSkills.hasPrompted"
    guard !UserDefaults.standard.bool(forKey: promptedKey) else { return }
    let detected = AgentSkillTarget.allCases.filter(\.isDetected)
    guard !detected.isEmpty else { return }

    UserDefaults.standard.set(true, forKey: promptedKey)

    let alert = NSAlert()
    alert.alertStyle = .informational
    alert.messageText = "Teach your coding agent the BonsAI board?"
    let names = detected.map(\.displayName).joined(separator: ", ")
    alert.informativeText = "BonsAI found \(names) on this Mac. Install a short skill doc so it knows how to read and write your board over the local canvas API? You can redo this anytime in Settings ▸ Connectors."
    alert.addButton(withTitle: "Install")
    alert.addButton(withTitle: "Not Now")
    guard alert.runModal() == .alertFirstButtonReturn else { return }

    let failures = AgentSkillsInstaller.installAllDetected()
    guard !failures.isEmpty else { return }
    let failure = NSAlert()
    failure.alertStyle = .warning
    failure.messageText = "Couldn't install for everyone"
    failure.informativeText = failures.map { "\($0.key.displayName): \($0.value.localizedDescription)" }.joined(separator: "\n")
    failure.runModal()
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
