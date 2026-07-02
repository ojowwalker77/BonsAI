import AppKit

/// Presentation for the copy-time shell syntax (`$(cmd)`, `name = …`, `$name`) — tint and face per
/// kind. Kept next to `ShellTemplate` (the parser) but separate so the resolver stays pure logic.
/// Both the rendered card (`ComposerChipText`) and the live editor (`FreeWriteEditor`) style from
/// here, so a token looks the same whether or not you're editing. No glyphs: the literal `$(…)` /
/// `$name` is what the user chose precisely because it's familiar, so we tint it, not replace it.
enum ShellTokenStyle {
  /// Green for shell commands (code), violet for variables (definitions + references), amber for a
  /// command that failed on the last copy.
  static let shell = NSColor(srgbRed: 0.42, green: 0.86, blue: 0.62, alpha: 1)
  static let variable = NSColor(srgbRed: 0.78, green: 0.66, blue: 1.00, alpha: 1)
  static let warning = NSColor(srgbRed: 1.00, green: 0.74, blue: 0.42, alpha: 1)

  static func tint(for kind: ShellTemplate.Kind) -> NSColor {
    switch kind {
    case .command: return shell
    case .definition, .reference: return variable
    }
  }

  /// Commands read as code (monospaced); variable names stay in the proportional body face.
  static func isCode(_ kind: ShellTemplate.Kind) -> Bool {
    if case .command = kind { return true }
    return false
  }

  static func font(for kind: ShellTemplate.Kind, size: CGFloat) -> NSFont {
    isCode(kind)
      ? NSFont.monospacedSystemFont(ofSize: size, weight: .bold)
      : ComposerPreferences.appFont(ofSize: size, weight: .bold)
  }
}
