import AppKit
import Foundation

/// The app-wide theme: a named flavor (palette + appearance class). Switching rebuilds the
/// canvas so every plain-color token re-resolves against the new flavor.
enum ComposerTheme: String, CaseIterable, Identifiable {
  case bonsaiDark
  case bonsaiLight
  case catppuccinMocha
  case catppuccinLatte

  var id: String { rawValue }

  var title: String {
    switch self {
    case .bonsaiDark: "Bonsai Dark"
    case .bonsaiLight: "Bonsai Light"
    case .catppuccinMocha: "Catppuccin Mocha"
    case .catppuccinLatte: "Catppuccin Latte"
    }
  }

  var flavor: ThemeFlavor {
    switch self {
    case .bonsaiDark: .bonsaiDark
    case .bonsaiLight: .bonsaiLight
    case .catppuccinMocha: .catppuccinMocha
    case .catppuccinLatte: .catppuccinLatte
    }
  }

  var nsAppearance: NSAppearance? {
    NSAppearance(named: flavor.isDark ? .darkAqua : .aqua)
  }
}

/// User-tunable appearance controls shared by SwiftUI surfaces and AppKit text views.
enum ComposerPreferences {
  static let editorFontSizeKey = "composer.editor.fontPointSize"
  /// App-wide theme. Defaults to Bonsai Dark — the signature look.
  static let themeKey = "composer.appearance.theme"
  /// Canvas background transparency (0 = solid, default). Sliding it up lets the desktop blur
  /// through the board surface.
  static let canvasTransparencyKey = "composer.canvas.backgroundTransparency"
  static let maxCanvasTransparency = 0.72

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

  /// The app-wide theme (see `ComposerTheme`). Defaults to Bonsai Dark.
  static var theme: ComposerTheme {
    ComposerTheme(rawValue: UserDefaults.standard.string(forKey: themeKey) ?? "") ?? .bonsaiDark
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

  static func clampedCanvasTransparency(_ value: Double) -> Double {
    min(max(value, 0), maxCanvasTransparency)
  }

  private static func clamp(_ value: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
    min(max(value, lower), upper)
  }
}
