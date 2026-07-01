import SwiftUI
import AppKit

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
