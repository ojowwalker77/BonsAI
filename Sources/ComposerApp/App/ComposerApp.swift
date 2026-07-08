import SwiftUI

@main
struct ComposerApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

  var body: some Scene {
    // BonsAI's UI is the AppKit board + dock owned by PanelController; this SwiftUI App only
    // hosts the delegate. The board is summoned by the global hotkey (HotKeyManager), the Dock
    // icon, or the menu-bar leaf. The placeholder Settings scene exists solely so the standard
    // Cmd-, routes to the in-board settings instead of opening a separate window.
    Settings {
      EmptyView()
    }
    .commands {
      // Sits directly under "About BonsAI" in the app menu — the standard home for this command.
      CommandGroup(after: .appInfo) {
        Button("Check for Updates...".localizedUI) { UpdaterController.shared.checkForUpdates() }
      }
      CommandGroup(replacing: .appSettings) {
        Button("Settings...".localizedUI) { appDelegate.showSettings() }
          .keyboardShortcut(",", modifiers: .command)
      }
    }
  }
}
