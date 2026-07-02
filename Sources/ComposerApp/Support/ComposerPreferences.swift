import AppKit
import Foundation
import SwiftUI

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

/// The app-wide body font family. `.system` is San Francisco — pixel-identical to today's
/// rendering, so it resolves straight through to `NSFont.systemFont`. The two custom families
/// are bundled `.otf`s registered at launch (see `AppDelegate`). Switching rebuilds the canvas
/// so every measurement cache and chrome label re-resolves against the new family.
enum ComposerFontFamily: String, CaseIterable, Identifiable {
  case system
  case nohemi
  case satoshi

  var id: String { rawValue }

  var title: String {
    switch self {
    case .system: "San Francisco"
    case .nohemi: "Nohemi"
    case .satoshi: "Satoshi"
    }
  }

  /// The registered font family name — nil for the system font (it has no bundled PostScript face).
  var familyName: String? {
    switch self {
    case .system: nil
    case .nohemi: "Nohemi"
    case .satoshi: "Satoshi"
    }
  }

  /// Map a target weight onto this family's actual PostScript face name. Custom families ship a
  /// fixed set of weights; the mapping folds anything finer onto the nearest available face.
  /// Returns nil for the system font (which is resolved via `NSFont.systemFont` instead).
  func postScriptName(for weight: NSFont.Weight) -> String? {
    guard let familyName else { return nil }
    switch self {
    case .system:
      return nil
    case .nohemi:
      // Nohemi ships Regular / Medium / SemiBold / Bold.
      if weight >= .bold { return "\(familyName)-Bold" }
      if weight >= .semibold { return "\(familyName)-SemiBold" }
      if weight >= .medium { return "\(familyName)-Medium" }
      return "\(familyName)-Regular"
    case .satoshi:
      // Satoshi ships Regular / Medium / Bold (no SemiBold — fold onto Medium).
      if weight >= .bold { return "\(familyName)-Bold" }
      if weight >= .medium { return "\(familyName)-Medium" }
      return "\(familyName)-Regular"
    }
  }
}

/// User-tunable appearance controls shared by SwiftUI surfaces and AppKit text views.
enum ComposerPreferences {
  static let editorFontSizeKey = "composer.editor.fontPointSize"
  /// App-wide theme. Defaults to Bonsai Dark — the signature look.
  static let themeKey = "composer.appearance.theme"
  /// App-wide body font family. Defaults to `.system` (San Francisco) — zero visual change.
  static let appFontFamilyKey = "composer.appearance.fontFamily"
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
    appFont(ofSize: editorFontSize)
  }

  /// The app-wide theme (see `ComposerTheme`). Defaults to Bonsai Dark.
  static var theme: ComposerTheme {
    ComposerTheme(rawValue: UserDefaults.standard.string(forKey: themeKey) ?? "") ?? .bonsaiDark
  }

  /// The app-wide body font family (see `ComposerFontFamily`). Defaults to `.system`.
  static var appFontFamily: ComposerFontFamily {
    get { ComposerFontFamily(rawValue: UserDefaults.standard.string(forKey: appFontFamilyKey) ?? "") ?? .system }
    set { UserDefaults.standard.set(newValue.rawValue, forKey: appFontFamilyKey) }
  }

  /// THE single chokepoint for every AppKit body font in the app. Resolves the selected family at
  /// the requested size/weight, and ALWAYS falls back to the system font if a bundled face is
  /// missing (unregistered, renamed) rather than crashing. `.system` returns the system font
  /// unchanged, so selecting San Francisco is pixel-identical to the pre-feature rendering.
  static func appFont(ofSize size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
    guard let psName = appFontFamily.postScriptName(for: weight),
          let font = NSFont(name: psName, size: size)
    else {
      return NSFont.systemFont(ofSize: size, weight: weight)
    }
    return font
  }

  /// The SwiftUI twin of `appFont`. `.system` yields `Font.system` (identical to today); a custom
  /// family yields `Font.custom` on the weight-mapped PostScript face — falling back to the system
  /// font when no bundled face matches, so a missing font never blanks the text.
  static func appSwiftUIFont(size: CGFloat, weight: Font.Weight = .regular) -> Font {
    guard let psName = appFontFamily.postScriptName(for: nsWeight(from: weight)) else {
      return Font.system(size: size, weight: weight)
    }
    // `Font.custom` resolves the exact PostScript face; guard once so a stale/missing face can't
    // silently vanish the text — fall back to the system font at the same size/weight.
    if NSFont(name: psName, size: size) != nil {
      return Font.custom(psName, size: size)
    }
    return Font.system(size: size, weight: weight)
  }

  /// Resolve a SwiftUI font for a SPECIFIC family, independent of the active selection — for the
  /// Settings specimen cards, where each card must preview its own face. Falls back to the system
  /// font if the family's face isn't registered.
  static func previewFont(for family: ComposerFontFamily, size: CGFloat, weight: Font.Weight = .regular) -> Font {
    guard let psName = family.postScriptName(for: nsWeight(from: weight)),
          NSFont(name: psName, size: size) != nil
    else {
      return Font.system(size: size, weight: weight)
    }
    return Font.custom(psName, size: size)
  }

  /// Bridge SwiftUI's `Font.Weight` onto AppKit's `NSFont.Weight` so both resolvers pick the same
  /// PostScript face for the same nominal weight.
  private static func nsWeight(from weight: Font.Weight) -> NSFont.Weight {
    switch weight {
    case .ultraLight: return .ultraLight
    case .thin: return .thin
    case .light: return .light
    case .regular: return .regular
    case .medium: return .medium
    case .semibold: return .semibold
    case .bold: return .bold
    case .heavy: return .heavy
    case .black: return .black
    default: return .regular
    }
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
