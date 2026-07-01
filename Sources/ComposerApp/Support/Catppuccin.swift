import AppKit

/// The Catppuccin palette (catppuccin.com) — data for the Catppuccin `ThemeFlavor`s.
/// Adding Frappé or Macchiato is pasting a palette + one `ThemeFlavor` entry.
struct CatppuccinFlavor {
  // Accents
  let rosewater: NSColor; let flamingo: NSColor; let pink: NSColor; let mauve: NSColor
  let red: NSColor; let maroon: NSColor; let peach: NSColor; let yellow: NSColor
  let green: NSColor; let teal: NSColor; let sky: NSColor; let sapphire: NSColor
  let blue: NSColor; let lavender: NSColor
  // Typography: text = primary ink, subtext = secondary/tertiary.
  let text: NSColor; let subtext1: NSColor; let subtext0: NSColor
  // Overlays: dim ink — badges, placeholders, disabled, hairlines.
  let overlay2: NSColor; let overlay1: NSColor; let overlay0: NSColor
  // Surfaces: UI fills — rows, chips, washes.
  let surface2: NSColor; let surface1: NSColor; let surface0: NSColor
  // Backgrounds: base = the canvas; mantle/crust recede below it.
  let base: NSColor; let mantle: NSColor; let crust: NSColor
}

enum Catppuccin {
  static let latte = CatppuccinFlavor(
    rosewater: hex(0xDC8A78), flamingo: hex(0xDD7878), pink: hex(0xEA76CB), mauve: hex(0x8839EF),
    red: hex(0xD20F39), maroon: hex(0xE64553), peach: hex(0xFE640B), yellow: hex(0xDF8E1D),
    green: hex(0x40A02B), teal: hex(0x179299), sky: hex(0x04A5E5), sapphire: hex(0x209FB5),
    blue: hex(0x1E66F5), lavender: hex(0x7287FD),
    text: hex(0x4C4F69), subtext1: hex(0x5C5F77), subtext0: hex(0x6C6F85),
    overlay2: hex(0x7C7F93), overlay1: hex(0x8C8FA1), overlay0: hex(0x9CA0B0),
    surface2: hex(0xACB0BE), surface1: hex(0xBCC0CC), surface0: hex(0xCCD0DA),
    base: hex(0xEFF1F5), mantle: hex(0xE6E9EF), crust: hex(0xDCE0E8))

  static let mocha = CatppuccinFlavor(
    rosewater: hex(0xF5E0DC), flamingo: hex(0xF2CDCD), pink: hex(0xF5C2E7), mauve: hex(0xCBA6F7),
    red: hex(0xF38BA8), maroon: hex(0xEBA0AC), peach: hex(0xFAB387), yellow: hex(0xF9E2AF),
    green: hex(0xA6E3A1), teal: hex(0x94E2D5), sky: hex(0x89DCEB), sapphire: hex(0x74C7EC),
    blue: hex(0x89B4FA), lavender: hex(0xB4BEFE),
    text: hex(0xCDD6F4), subtext1: hex(0xBAC2DE), subtext0: hex(0xA6ADC8),
    overlay2: hex(0x9399B2), overlay1: hex(0x7F849C), overlay0: hex(0x6C7086),
    surface2: hex(0x585B70), surface1: hex(0x45475A), surface0: hex(0x313244),
    base: hex(0x1E1E2E), mantle: hex(0x181825), crust: hex(0x11111B))

  private static func hex(_ value: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255.0,
            green: CGFloat((value >> 8) & 0xFF) / 255.0,
            blue: CGFloat(value & 0xFF) / 255.0, alpha: 1.0)
  }
}
