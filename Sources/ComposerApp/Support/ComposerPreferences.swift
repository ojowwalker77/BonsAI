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

  /// This theme's dark sibling — itself if already dark. Pairs the two Bonsai looks and the two
  /// Catppuccin flavors, so "match macOS appearance" swaps within the family the user picked.
  var darkCounterpart: ComposerTheme {
    switch self {
    case .bonsaiLight: .bonsaiDark
    case .catppuccinLatte: .catppuccinMocha
    default: self
    }
  }

  /// This theme's light sibling — itself if already light.
  var lightCounterpart: ComposerTheme {
    switch self {
    case .bonsaiDark: .bonsaiLight
    case .catppuccinMocha: .catppuccinLatte
    default: self
    }
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
  /// When on, the rendered theme swaps to the picked theme's light/dark counterpart as macOS
  /// switches appearance (see `effectiveTheme`). Off by default — the pick is literal.
  static let followSystemAppearanceKey = "composer.appearance.followSystem"
  /// App-wide body font family. Defaults to `.system` (San Francisco) — zero visual change.
  static let appFontFamilyKey = "composer.appearance.fontFamily"
  /// App language override. `.system` follows macOS language preferences.
  static let languageKey = "composer.appearance.language"
  /// Canvas background transparency (0 = solid, default). Sliding it up lets the desktop blur
  /// through the board surface.
  static let canvasTransparencyKey = "composer.canvas.backgroundTransparency"
  static let maxCanvasTransparency = 0.72
  /// When on, drawing tools stay active after each placement/stroke instead of snapping back to
  /// the pointer (standard drawing-tool behavior). Esc always returns to the pointer.
  static let persistentToolSelectionKey = "composer.canvas.persistentToolSelection"
  /// When on, a confidently recognized freehand stroke snaps straight into the clean shape on
  /// pen-up (OneNote "Ink to Shape"). Off keeps recognition as the opt-in promotion chip.
  static let autoSnapFreehandKey = "composer.canvas.autoSnapFreehand"

  static let minEditorFontSize: CGFloat = 11
  static let maxEditorFontSize: CGFloat = 28
  static let fontSizeStep: CGFloat = 1

  /// Internal so the Settings stepper can seed its @AppStorage default with the same value the
  /// clamped `editorFontSize` getter falls back to.
  static var defaultEditorFontSize: CGFloat {
    NSFont.preferredFont(forTextStyle: .body).pointSize + 2
  }

  static var editorFontSize: CGFloat {
    let stored = UserDefaults.standard.object(forKey: editorFontSizeKey) as? NSNumber
    return clamp(CGFloat(stored?.doubleValue ?? Double(defaultEditorFontSize)), minEditorFontSize, maxEditorFontSize)
  }

  static var editorFont: NSFont {
    appFont(ofSize: editorFontSize)
  }

  /// The app-wide theme (see `ComposerTheme`). Defaults to Bonsai Dark. This is the STORED pick —
  /// rendering reads `effectiveTheme`, which applies the follow-system swap on top.
  static var theme: ComposerTheme {
    ComposerTheme(rawValue: UserDefaults.standard.string(forKey: themeKey) ?? "") ?? .bonsaiDark
  }

  /// Whether drawing tools persist after use (Settings ▸ Appearance ▸ Drawing). Read at each
  /// commit site — no live canvas rebuild needed when it flips.
  static var persistentToolSelection: Bool {
    UserDefaults.standard.bool(forKey: persistentToolSelectionKey)
  }

  /// Whether recognized freehand strokes auto-convert on pen-up (Settings ▸ Appearance ▸ Drawing).
  static var autoSnapFreehand: Bool {
    UserDefaults.standard.bool(forKey: autoSnapFreehandKey)
  }

  /// Whether the rendered theme tracks macOS Light/Dark (Settings ▸ Appearance).
  static var followsSystemAppearance: Bool {
    get { UserDefaults.standard.bool(forKey: followSystemAppearanceKey) }
    set { UserDefaults.standard.set(newValue, forKey: followSystemAppearanceKey) }
  }

  /// The theme to RENDER right now: the stored pick, swapped to its light/dark counterpart when
  /// "match macOS appearance" is on. Every appearance consumer (window appearance, `Theme.flavor`,
  /// export) reads this; only Settings' theme gallery shows the stored pick.
  static var effectiveTheme: ComposerTheme {
    let picked = theme
    guard followsSystemAppearance else { return picked }
    let appearance = NSApplication.shared.effectiveAppearance
    let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    return isDark ? picked.darkCounterpart : picked.lightCounterpart
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

  static func clampedCanvasTransparency(_ value: Double) -> Double {
    min(max(value, 0), maxCanvasTransparency)
  }

  private static func clamp(_ value: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
    min(max(value, lower), upper)
  }
}
