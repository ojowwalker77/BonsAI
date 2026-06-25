import AppKit
import Carbon.HIToolbox
import SwiftUI

/// A user-configurable global hotkey: a virtual key code plus the device-independent
/// modifier flags. Bridges between the three representations the app needs — Carbon
/// (for `RegisterEventHotKey`), SwiftUI (`KeyEquivalent`/`EventModifiers` for the menu),
/// and a human-readable string (`⌃⌥Space`) for Settings.
struct GlobalShortcut: Equatable {
  var keyCode: UInt32
  var modifierFlags: NSEvent.ModifierFlags

  /// The original hardcoded binding, used until the user picks their own.
  static let `default` = GlobalShortcut(
    keyCode: UInt32(kVK_Space),
    modifierFlags: [.control, .option]
  )

  /// Default "Snap to board" capture key (⌘⇧Space) — clear of the system screenshot keys (⌘⇧3/4/5)
  /// and the summon key (⌃⌥Space).
  static let defaultCapture = GlobalShortcut(
    keyCode: UInt32(kVK_Space),
    modifierFlags: [.command, .shift]
  )

  var hasModifier: Bool {
    !modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
  }

  // MARK: Carbon (RegisterEventHotKey)

  var carbonModifiers: UInt32 {
    var mods: UInt32 = 0
    if modifierFlags.contains(.command) { mods |= UInt32(cmdKey) }
    if modifierFlags.contains(.option) { mods |= UInt32(optionKey) }
    if modifierFlags.contains(.control) { mods |= UInt32(controlKey) }
    if modifierFlags.contains(.shift) { mods |= UInt32(shiftKey) }
    return mods
  }

  // MARK: SwiftUI (menu key hint)

  var eventModifiers: SwiftUI.EventModifiers {
    var mods: SwiftUI.EventModifiers = []
    if modifierFlags.contains(.command) { mods.insert(.command) }
    if modifierFlags.contains(.option) { mods.insert(.option) }
    if modifierFlags.contains(.control) { mods.insert(.control) }
    if modifierFlags.contains(.shift) { mods.insert(.shift) }
    return mods
  }

  var keyEquivalent: KeyEquivalent? { Self.knownKeys[keyCode]?.equivalent }

  // MARK: Display (Settings)

  /// Conventional modifier order: ⌃⌥⇧⌘, then the key name.
  var displayString: String {
    var out = ""
    if modifierFlags.contains(.control) { out += "⌃" }
    if modifierFlags.contains(.option) { out += "⌥" }
    if modifierFlags.contains(.shift) { out += "⇧" }
    if modifierFlags.contains(.command) { out += "⌘" }
    out += Self.knownKeys[keyCode]?.name ?? "Key \(keyCode)"
    return out
  }

  // MARK: Key code table

  private struct KeyInfo {
    let name: String
    let equivalent: KeyEquivalent?
    init(_ name: String, _ equivalent: KeyEquivalent? = nil) {
      self.name = name
      self.equivalent = equivalent
    }
  }

  /// Virtual key codes for the standard US layout. Covers the keys a person is
  /// likely to bind a global summon shortcut to; anything else falls back to a
  /// readable placeholder and simply omits the SwiftUI menu hint.
  private static let knownKeys: [UInt32: KeyInfo] = [
    UInt32(kVK_ANSI_A): KeyInfo("A", "a"), UInt32(kVK_ANSI_B): KeyInfo("B", "b"),
    UInt32(kVK_ANSI_C): KeyInfo("C", "c"), UInt32(kVK_ANSI_D): KeyInfo("D", "d"),
    UInt32(kVK_ANSI_E): KeyInfo("E", "e"), UInt32(kVK_ANSI_F): KeyInfo("F", "f"),
    UInt32(kVK_ANSI_G): KeyInfo("G", "g"), UInt32(kVK_ANSI_H): KeyInfo("H", "h"),
    UInt32(kVK_ANSI_I): KeyInfo("I", "i"), UInt32(kVK_ANSI_J): KeyInfo("J", "j"),
    UInt32(kVK_ANSI_K): KeyInfo("K", "k"), UInt32(kVK_ANSI_L): KeyInfo("L", "l"),
    UInt32(kVK_ANSI_M): KeyInfo("M", "m"), UInt32(kVK_ANSI_N): KeyInfo("N", "n"),
    UInt32(kVK_ANSI_O): KeyInfo("O", "o"), UInt32(kVK_ANSI_P): KeyInfo("P", "p"),
    UInt32(kVK_ANSI_Q): KeyInfo("Q", "q"), UInt32(kVK_ANSI_R): KeyInfo("R", "r"),
    UInt32(kVK_ANSI_S): KeyInfo("S", "s"), UInt32(kVK_ANSI_T): KeyInfo("T", "t"),
    UInt32(kVK_ANSI_U): KeyInfo("U", "u"), UInt32(kVK_ANSI_V): KeyInfo("V", "v"),
    UInt32(kVK_ANSI_W): KeyInfo("W", "w"), UInt32(kVK_ANSI_X): KeyInfo("X", "x"),
    UInt32(kVK_ANSI_Y): KeyInfo("Y", "y"), UInt32(kVK_ANSI_Z): KeyInfo("Z", "z"),
    UInt32(kVK_ANSI_0): KeyInfo("0", "0"), UInt32(kVK_ANSI_1): KeyInfo("1", "1"),
    UInt32(kVK_ANSI_2): KeyInfo("2", "2"), UInt32(kVK_ANSI_3): KeyInfo("3", "3"),
    UInt32(kVK_ANSI_4): KeyInfo("4", "4"), UInt32(kVK_ANSI_5): KeyInfo("5", "5"),
    UInt32(kVK_ANSI_6): KeyInfo("6", "6"), UInt32(kVK_ANSI_7): KeyInfo("7", "7"),
    UInt32(kVK_ANSI_8): KeyInfo("8", "8"), UInt32(kVK_ANSI_9): KeyInfo("9", "9"),
    UInt32(kVK_Space): KeyInfo("Space", .space),
    UInt32(kVK_Return): KeyInfo("Return", .return),
    UInt32(kVK_Tab): KeyInfo("Tab", .tab),
    UInt32(kVK_Delete): KeyInfo("Delete", .delete),
    UInt32(kVK_Escape): KeyInfo("Esc", .escape),
    UInt32(kVK_F1): KeyInfo("F1"), UInt32(kVK_F2): KeyInfo("F2"),
    UInt32(kVK_F3): KeyInfo("F3"), UInt32(kVK_F4): KeyInfo("F4"),
    UInt32(kVK_F5): KeyInfo("F5"), UInt32(kVK_F6): KeyInfo("F6"),
    UInt32(kVK_F7): KeyInfo("F7"), UInt32(kVK_F8): KeyInfo("F8"),
    UInt32(kVK_F9): KeyInfo("F9"), UInt32(kVK_F10): KeyInfo("F10"),
    UInt32(kVK_F11): KeyInfo("F11"), UInt32(kVK_F12): KeyInfo("F12"),
    UInt32(kVK_LeftArrow): KeyInfo("←", .leftArrow),
    UInt32(kVK_RightArrow): KeyInfo("→", .rightArrow),
    UInt32(kVK_UpArrow): KeyInfo("↑", .upArrow),
    UInt32(kVK_DownArrow): KeyInfo("↓", .downArrow),
  ]
}

/// Persists the chosen summon shortcut to `UserDefaults` and notifies the rest of
/// the app (the hotkey registrar, the menu) when it changes.
final class ShortcutStore: ObservableObject {
  static let shared = ShortcutStore()

  private let keyCodeKey = "composer.shortcut.keyCode"
  private let modifiersKey = "composer.shortcut.modifiers"
  private let captureKeyCodeKey = "composer.captureShortcut.keyCode"
  private let captureModifiersKey = "composer.captureShortcut.modifiers"

  @Published var shortcut: GlobalShortcut {
    didSet {
      guard shortcut != oldValue else { return }
      let defaults = UserDefaults.standard
      defaults.set(Int(shortcut.keyCode), forKey: keyCodeKey)
      defaults.set(Int(shortcut.modifierFlags.rawValue), forKey: modifiersKey)
      NotificationCenter.default.post(name: .composerShortcutChanged, object: nil)
    }
  }

  /// The "Snap to board" capture hotkey. Re-registered alongside `shortcut` via the same change
  /// notification, so the hotkey registrar re-binds both whenever either changes.
  @Published var captureShortcut: GlobalShortcut {
    didSet {
      guard captureShortcut != oldValue else { return }
      let defaults = UserDefaults.standard
      defaults.set(Int(captureShortcut.keyCode), forKey: captureKeyCodeKey)
      defaults.set(Int(captureShortcut.modifierFlags.rawValue), forKey: captureModifiersKey)
      NotificationCenter.default.post(name: .composerShortcutChanged, object: nil)
    }
  }

  private init() {
    let defaults = UserDefaults.standard
    if defaults.object(forKey: keyCodeKey) != nil {
      shortcut = GlobalShortcut(
        keyCode: UInt32(defaults.integer(forKey: keyCodeKey)),
        modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(defaults.integer(forKey: modifiersKey)))
      )
    } else {
      shortcut = .default
    }
    if defaults.object(forKey: captureKeyCodeKey) != nil {
      captureShortcut = GlobalShortcut(
        keyCode: UInt32(defaults.integer(forKey: captureKeyCodeKey)),
        modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(defaults.integer(forKey: captureModifiersKey)))
      )
    } else {
      captureShortcut = .defaultCapture
    }
  }

  func reset() {
    shortcut = .default
    captureShortcut = .defaultCapture
  }
}

extension View {
  /// Applies the shortcut as a SwiftUI key hint when it maps to a known
  /// `KeyEquivalent`; otherwise leaves the view untouched (the global hotkey
  /// still works — this is only the visible hint in the menu).
  @ViewBuilder
  func optionalKeyboardShortcut(_ shortcut: GlobalShortcut) -> some View {
    if let key = shortcut.keyEquivalent {
      self.keyboardShortcut(key, modifiers: shortcut.eventModifiers)
    } else {
      self
    }
  }
}
