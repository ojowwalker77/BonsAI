import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  let panelController = PanelController()
  private let hotKeyManager = HotKeyManager()
  /// Held strongly so it keeps firing — a `DispatchSourceSignal` is cancelled on dealloc.
  private var sigtermSource: DispatchSourceSignal?
  /// Watches macOS Light/Dark for the "match macOS appearance" setting. NSApp's own appearance is
  /// never pinned, so `effectiveAppearance` tracks the system even while our windows are themed.
  private var appearanceObservation: NSKeyValueObservation?

  func applicationDidFinishLaunching(_ notification: Notification) {
    registerBundledFonts()
    hotKeyManager.register()
    _ = UpdaterController.shared
    CanvasServer.shared.start()
    promptForAgentSkillsIfNeeded()
    installSigtermHandler()

    NotificationCenter.default.addObserver(
      self, selector: #selector(showBoard),
      name: .composerShowWindow, object: nil)
    NotificationCenter.default.addObserver(
      self, selector: #selector(captureToBoard),
      name: .composerCaptureToBoard, object: nil)

    // A system Light/Dark switch re-resolves the effective theme when "match macOS appearance"
    // is on — routed through the same notification a manual theme pick posts, so the window
    // appearance and canvas rebuild in one place (PanelController.applyTheme).
    appearanceObservation = NSApp.observe(\.effectiveAppearance) { _, _ in
      DispatchQueue.main.async {
        guard ComposerPreferences.followsSystemAppearance else { return }
        NotificationCenter.default.post(
          name: .composerThemeChanged, object: CanvasRemountTrigger.systemAppearance)
      }
    }

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
        let message = error?.takeRetainedValue().localizedDescription ?? "unknown error".localizedUI
        NSLog("BonsAI: skipped font registration for \(url.lastPathComponent): \(message)")
      }
    }
  }

  /// Flush pending board edits before quitting — `DumpStore`'s autosave is debounced, so an edit
  /// (including one an external agent made over the canvas API) right before quit would be lost.
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    CanvasBridge.shared.flush()
    return .terminateNow
  }

  /// A final idempotent flush covers termination routes that do not consult the delegate first.
  func applicationWillTerminate(_ notification: Notification) {
    CanvasBridge.shared.flush()
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
    if !hasVisibleWindows { panelController.show() }
    return true
  }

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
  /// Agents instead of re-prompting every launch.
  private func promptForAgentSkillsIfNeeded() {
    let promptedKey = "app.agentSkills.hasPrompted"
    guard !UserDefaults.standard.bool(forKey: promptedKey) else { return }
    let detected = AgentSkillTarget.allCases.filter(\.isDetected)
    guard !detected.isEmpty else { return }

    UserDefaults.standard.set(true, forKey: promptedKey)

    let alert = NSAlert()
    alert.alertStyle = .informational
    alert.messageText = "Teach your coding agent the BonsAI board?".localizedUI
    let names = detected.map(\.displayName).joined(separator: ", ")
    alert.informativeText = "BonsAI found %@ on this Mac. Install a short skill doc so it knows how to read and write your board over the local canvas API? You can redo this anytime in Settings > Agents.".localizedUI(names)
    alert.addButton(withTitle: "Install".localizedUI)
    alert.addButton(withTitle: "Not Now".localizedUI)
    guard alert.runModal() == .alertFirstButtonReturn else { return }

    let failures = AgentSkillsInstaller.installAllDetected()
    guard !failures.isEmpty else { return }
    let failure = NSAlert()
    failure.alertStyle = .warning
    failure.messageText = "Couldn't install for everyone".localizedUI
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

  /// Summon the board (if hidden) and open its in-canvas Settings overlay.
  func showSettings() {
    panelController.show()
    NotificationCenter.default.post(name: .composerShowSettings, object: nil)
  }
}
