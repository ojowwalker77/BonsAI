import Foundation

extension Bundle {
  /// Resolves the SwiftPM resource bundle (`Composer_ComposerApp.bundle`) no matter where the staged
  /// `.app` places it — and, unlike SwiftPM's generated `Bundle.module`, never `fatalError`s.
  ///
  /// `Bundle.module`'s generated accessor only checks `Bundle.main.bundleURL/<bundle>` (the app root)
  /// and a hard-coded CI build path. When a release stages the bundle into the canonical, codesign-clean
  /// `Contents/Resources/` instead, `Bundle.module` can't find it and its static initializer traps —
  /// which is exactly what crashed every downloaded 1.0.1 build on launch (the first brand-logo render
  /// touched `Bundle.module`). This checks every sane location and degrades to `Bundle.main` so a
  /// genuinely missing resource just returns `nil` to the caller (logo → SF Symbol, welcome board →
  /// blank board) rather than taking the whole app down.
  static let appResources: Bundle = {
    let name = "Composer_ComposerApp.bundle"
    var seen = Set<String>()
    var candidates: [URL] = []
    func consider(_ dir: URL?) {
      guard let dir, seen.insert(dir.path).inserted else { return }
      candidates.append(dir)
    }
    consider(main.resourceURL)                                  // Contents/Resources (canonical app layout)
    consider(main.bundleURL)                                    // app root (SwiftPM executable layout / `swift run`)
    consider(main.executableURL?.deletingLastPathComponent())  // Contents/MacOS (next to the binary)
    consider(main.resourceURL?.deletingLastPathComponent())    // Contents (defensive)

    for dir in candidates {
      if let bundle = Bundle(url: dir.appendingPathComponent(name)) {
        return bundle
      }
    }
    return .main
  }()
}
