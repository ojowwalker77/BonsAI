import AppKit
import Carbon.HIToolbox

final class HotKeyManager {
  private var captureHotKeyRef: EventHotKeyRef?
  private var eventHandler: EventHandlerRef?

  /// The one global hotkey: "Snap to board" region capture.
  private static let captureID: UInt32 = 2

  func register() {
    installHandler()
    registerHotKeys()
    NotificationCenter.default.addObserver(
      self, selector: #selector(reregister),
      name: .composerShortcutChanged, object: nil)
  }

  /// Re-bind the hotkey after the user picks a new shortcut in Settings.
  @objc private func reregister() { registerHotKeys() }

  private func installHandler() {
    var eventType = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard),
      eventKind: OSType(kEventHotKeyPressed)
    )

    InstallEventHandler(
      GetApplicationEventTarget(),
      { _, event, _ in
        var hotKeyID = EventHotKeyID()
        GetEventParameter(
          event,
          EventParamName(kEventParamDirectObject),
          EventParamType(typeEventHotKeyID),
          nil,
          MemoryLayout<EventHotKeyID>.size,
          nil,
          &hotKeyID
        )

        let id = hotKeyID.id
        DispatchQueue.main.async {
          if id == HotKeyManager.captureID {
            NotificationCenter.default.post(name: .composerCaptureToBoard, object: nil)
          }
        }
        return noErr
      },
      1,
      &eventType,
      nil,
      &eventHandler
    )
  }

  private func registerHotKeys() {
    captureHotKeyRef = register(ShortcutStore.shared.captureShortcut, id: Self.captureID, replacing: captureHotKeyRef)
  }

  private func register(_ shortcut: GlobalShortcut, id: UInt32, replacing existing: EventHotKeyRef?) -> EventHotKeyRef? {
    if let existing { UnregisterEventHotKey(existing) }
    var ref: EventHotKeyRef?
    let hotKeyID = EventHotKeyID(signature: "CMPR".fourCharCode, id: id)
    let status = RegisterEventHotKey(
      shortcut.keyCode,
      shortcut.carbonModifiers,
      hotKeyID,
      GetApplicationEventTarget(),
      0,
      &ref
    )
    if status != noErr {
      UserFacingError.report("Couldn't register a global keyboard shortcut - the key combination may already be in use by another shortcut or app. Pick a different one in Settings > Keyboard.".localizedUI)
    }
    return ref
  }

  deinit {
    if let captureHotKeyRef {
      UnregisterEventHotKey(captureHotKeyRef)
    }
    if let eventHandler {
      RemoveEventHandler(eventHandler)
    }
  }
}
