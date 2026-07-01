import AppKit
import Foundation

/// The app-wide appearance: follow macOS, or force light / dark. Applied as each window's
/// `NSAppearance`, so the adaptive `Theme` palette resolves accordingly everywhere at once.
enum ComposerTheme: String, CaseIterable, Identifiable {
  case system
  case light
  case dark

  var id: String { rawValue }

  var title: String {
    switch self {
    case .system: "System"
    case .light: "Light"
    case .dark: "Dark"
    }
  }

  /// nil = inherit the system appearance.
  var nsAppearance: NSAppearance? {
    switch self {
    case .system: nil
    case .light: NSAppearance(named: .aqua)
    case .dark: NSAppearance(named: .darkAqua)
    }
  }
}

/// User-tunable appearance controls shared by SwiftUI surfaces and AppKit text views.
enum ComposerPreferences {
  static let editorFontSizeKey = "composer.editor.fontPointSize"
  /// App-wide theme. Defaults to dark — BonsAI's signature look — so existing installs don't
  /// change; System/Light are the opt-in.
  static let themeKey = "composer.appearance.theme"

  static let minEditorFontSize: CGFloat = 11
  static let maxEditorFontSize: CGFloat = 28
  static let fontSizeStep: CGFloat = 1

  private static var defaultEditorFontSize: CGFloat {
    NSFont.preferredFont(forTextStyle: .body).pointSize + 2
  }

  static var editorFontSize: CGFloat {
    let stored = UserDefaults.standard.object(forKey: editorFontSizeKey) as? NSNumber
    return clamp(CGFloat(stored?.doubleValue ?? Double(defaultEditorFontSize)), minEditorFontSize, maxEditorFontSize)
  }

  static var editorFont: NSFont {
    NSFont.systemFont(ofSize: editorFontSize)
  }

  /// The app-wide theme (see `ComposerTheme`). Defaults to dark, today's look.
  static var theme: ComposerTheme {
    ComposerTheme(rawValue: UserDefaults.standard.string(forKey: themeKey) ?? "") ?? .dark
  }

  @discardableResult
  static func adjustEditorFontSize(by delta: CGFloat) -> CGFloat {
    let next = clamp(editorFontSize + delta, minEditorFontSize, maxEditorFontSize)
    UserDefaults.standard.set(Double(next), forKey: editorFontSizeKey)
    NotificationCenter.default.post(name: .composerFontSizeChanged, object: nil, userInfo: ["size": next])
    return next
  }

  @discardableResult
  static func resetEditorFontSize() -> CGFloat {
    UserDefaults.standard.removeObject(forKey: editorFontSizeKey)
    let size = editorFontSize
    NotificationCenter.default.post(name: .composerFontSizeChanged, object: nil, userInfo: ["size": size])
    return size
  }

  static func handleEditorFontKeyEquivalent(_ event: NSEvent) -> Bool {
    let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
    guard flags == [.command] || flags == [.command, .shift] else { return false }

    let raw = event.charactersIgnoringModifiers?.lowercased()
    let modified = event.characters?.lowercased()
    if raw == "=" || modified == "+" {
      adjustEditorFontSize(by: fontSizeStep)
      return true
    }
    if raw == "-" || modified == "_" {
      adjustEditorFontSize(by: -fontSizeStep)
      return true
    }
    return false
  }

  private static func clamp(_ value: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
    min(max(value, lower), upper)
  }
}
