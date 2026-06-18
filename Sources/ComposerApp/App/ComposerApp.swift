import SwiftUI

@main
struct ComposerApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

  var body: some Scene {
    MenuBarExtra("Composer", systemImage: "square.and.pencil") {
      Button("Show Composer") { appDelegate.panelController.toggle() }
        .keyboardShortcut(.space, modifiers: [.control, .option])
      Divider()
      Button("Settings\u{2026}") { appDelegate.showSettings() }
        .keyboardShortcut(",", modifiers: .command)
      Divider()
      Button("Quit Composer") { NSApp.terminate(nil) }
        .keyboardShortcut("q", modifiers: .command)
    }
    .menuBarExtraStyle(.menu)
  }
}
