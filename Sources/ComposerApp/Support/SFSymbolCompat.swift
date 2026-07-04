import SwiftUI
import AppKit

/// Resolves an SF Symbol NAME (a plain string) against the running OS, for call sites that pass a
/// bare symbol string rather than building an `Image` (e.g. `PaletteCommand.symbol`, rendered by a
/// plain `Image(systemName:)`). Same probe as the `Image` initializer below — falls back when the
/// preferred glyph isn't present on the deployment floor.
enum SFSymbolName {
  static func resolve(_ preferred: String, fallback: String) -> String {
    NSImage(systemSymbolName: preferred, accessibilityDescription: nil) != nil ? preferred : fallback
  }
}

extension Image {
  /// An SF Symbol image with a graceful fallback for OS versions where `preferred` doesn't exist yet.
  ///
  /// SF Symbol names are plain strings, so the compiler can't version-check them the way it gates a
  /// real API behind `@available`. A glyph introduced in a newer OS — e.g. `apple.intelligence` and
  /// `wand.and.sparkles`, both macOS 15+ — therefore compiles cleanly but renders as an empty
  /// missing-glyph box on an older system, which is exactly the kind of silent, misleading
  /// degradation the deployment-target floor (macOS 14) must not introduce.
  ///
  /// This probes the *running* OS via AppKit — `NSImage(systemSymbolName:)` returns nil when the
  /// symbol isn't present — and falls back to an always-available mark, so the icon degrades to a
  /// sensible shape below its introduction version. `fallback` must be a symbol that exists on the
  /// deployment floor.
  init(systemName preferred: String, fallback: String) {
    let resolved = NSImage(systemSymbolName: preferred, accessibilityDescription: nil) != nil
      ? preferred
      : fallback
    self.init(systemName: resolved)
  }
}
