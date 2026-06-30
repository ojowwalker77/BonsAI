import AppKit
import Carbon.HIToolbox
import SwiftUI

/// A click-to-record control for a global shortcut. Click it, then press a key combination (which
/// must include at least one modifier). Esc cancels. Binds to whichever shortcut it's given, so the
/// same control records the summon key and the "Snap to board" capture key.
struct ShortcutRecorder: View {
  @Binding var shortcut: GlobalShortcut
  var defaultValue: GlobalShortcut = .default
  @State private var recording = false
  @State private var monitor: Any?

  var body: some View {
    HStack(spacing: 8) {
      Button(action: toggle) {
        Text(recording ? "Type a shortcut…" : shortcut.displayString)
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(recording ? Color.accentColor : .secondary)
          .padding(.horizontal, 8).padding(.vertical, 3)
          .frame(minWidth: 78)
          .background(
            RoundedRectangle(cornerRadius: 5)
              .fill(Color.primary.opacity(0.06))
              .overlay(
                RoundedRectangle(cornerRadius: 5)
                  .strokeBorder(Color.accentColor.opacity(recording ? 0.9 : 0), lineWidth: 1)
              )
          )
      }
      .buttonStyle(.plain)

      if shortcut != defaultValue {
        Button("Reset") { shortcut = defaultValue }
          .buttonStyle(.plain)
          .font(.system(size: 11))
          .foregroundStyle(.tertiary)
      }
    }
    .onDisappear(perform: stop)
  }

  private func toggle() { recording ? stop() : start() }

  private func start() {
    recording = true
    monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
      handle(event)
      return nil // swallow the event while recording
    }
  }

  private func stop() {
    recording = false
    if let monitor {
      NSEvent.removeMonitor(monitor)
      self.monitor = nil
    }
  }

  private func handle(_ event: NSEvent) {
    if event.keyCode == UInt16(kVK_Escape) { stop(); return }
    let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
    guard !flags.isEmpty else { return } // a bare key would be too easy to trigger
    shortcut = GlobalShortcut(keyCode: UInt32(event.keyCode), modifierFlags: flags)
    stop()
  }
}
