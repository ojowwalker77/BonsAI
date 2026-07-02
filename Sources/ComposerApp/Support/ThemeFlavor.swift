import AppKit

/// One complete theme: a semantic palette plus its appearance class. `Theme.Palette` tokens map
/// roles onto these slots, so adding a theme is a data change — never a view change.
///
/// Slot semantics follow Catppuccin's model: `text` > `subtext` (secondary ink) > `overlay`
/// (dim ink, hairlines) > `surface` (fills) > `base`/`mantle`/`crust` (backgrounds).
struct ThemeFlavor {
  let isDark: Bool
  let text: NSColor
  let subtext1: NSColor
  let subtext0: NSColor
  let overlay2: NSColor
  let overlay1: NSColor
  let overlay0: NSColor
  let surface2: NSColor
  let surface1: NSColor
  let surface0: NSColor
  let base: NSColor
  let mantle: NSColor
  let crust: NSColor
  /// The one accent (selection, active tool, send).
  let accent: NSColor
  /// Informational tint (link-ish chips without a brand color).
  let info: NSColor
  /// Element tint slots, in a FIXED semantic order: red, orange, yellow, green, blue, purple.
  /// Board elements store a slot INDEX, so an element tinted "3" is green in every theme —
  /// switching themes re-resolves the index against the new flavor's slot.
  let tints: [NSColor]
}

extension ThemeFlavor {
  private static func hex(_ value: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255.0,
            green: CGFloat((value >> 8) & 0xFF) / 255.0,
            blue: CGFloat(value & 0xFF) / 255.0, alpha: 1.0)
  }

  /// BonsAI's original dark look: stone ink (#F5F4EF family) on pure black.
  static let bonsaiDark = ThemeFlavor(
    isDark: true,
    text: hex(0xE3E2DD), subtext1: hex(0xA5A4A0), subtext0: hex(0x9B9A96),
    overlay2: hex(0x807F7C), overlay1: hex(0x585856), overlay0: hex(0x403F3E),
    surface2: hex(0x2A2A28), surface1: hex(0x1F1F1E), surface0: hex(0x161615),
    base: hex(0x000000), mantle: hex(0x2B2B2B), crust: hex(0x000000),
    accent: NSColor.controlAccentColor, info: NSColor.controlAccentColor,
    tints: [hex(0xD97A74), hex(0xD99A6C), hex(0xD4B96A), hex(0x8FB37E), hex(0x7A9BC4), hex(0xA88BC4)])

  /// BonsAI's original light look: #575757 ink on soft stone paper (#F5F4EF).
  static let bonsaiLight = ThemeFlavor(
    isDark: false,
    text: hex(0x575757), subtext1: hex(0x6B6B69), subtext0: hex(0x757572),
    overlay2: hex(0x8F8F8B), overlay1: hex(0x9B9B96), overlay0: hex(0xACACA6),
    surface2: hex(0xC4C3BC), surface1: hex(0xD3D2CA), surface0: hex(0xDEDDD5),
    base: hex(0xF5F4EF), mantle: hex(0xFAF9F5), crust: hex(0xEBEAE4),
    accent: NSColor.controlAccentColor, info: NSColor.controlAccentColor,
    tints: [hex(0xC25A50), hex(0xC27E4A), hex(0xAF8B34), hex(0x6E9B5C), hex(0x5A7FA8), hex(0x8A6BAA)])

  /// Catppuccin Mocha (catppuccin.com) — accent mauve.
  static let catppuccinMocha = ThemeFlavor(
    isDark: true,
    text: Catppuccin.mocha.text, subtext1: Catppuccin.mocha.subtext1, subtext0: Catppuccin.mocha.subtext0,
    overlay2: Catppuccin.mocha.overlay2, overlay1: Catppuccin.mocha.overlay1, overlay0: Catppuccin.mocha.overlay0,
    surface2: Catppuccin.mocha.surface2, surface1: Catppuccin.mocha.surface1, surface0: Catppuccin.mocha.surface0,
    base: Catppuccin.mocha.base, mantle: Catppuccin.mocha.mantle, crust: Catppuccin.mocha.crust,
    accent: Catppuccin.mocha.mauve, info: Catppuccin.mocha.blue,
    tints: [Catppuccin.mocha.red, Catppuccin.mocha.peach, Catppuccin.mocha.yellow,
            Catppuccin.mocha.green, Catppuccin.mocha.blue, Catppuccin.mocha.mauve])

  /// Catppuccin Latte — accent mauve.
  static let catppuccinLatte = ThemeFlavor(
    isDark: false,
    text: Catppuccin.latte.text, subtext1: Catppuccin.latte.subtext1, subtext0: Catppuccin.latte.subtext0,
    overlay2: Catppuccin.latte.overlay2, overlay1: Catppuccin.latte.overlay1, overlay0: Catppuccin.latte.overlay0,
    surface2: Catppuccin.latte.surface2, surface1: Catppuccin.latte.surface1, surface0: Catppuccin.latte.surface0,
    base: Catppuccin.latte.base, mantle: Catppuccin.latte.mantle, crust: Catppuccin.latte.crust,
    accent: Catppuccin.latte.mauve, info: Catppuccin.latte.blue,
    tints: [Catppuccin.latte.red, Catppuccin.latte.peach, Catppuccin.latte.yellow,
            Catppuccin.latte.green, Catppuccin.latte.blue, Catppuccin.latte.mauve])
}
