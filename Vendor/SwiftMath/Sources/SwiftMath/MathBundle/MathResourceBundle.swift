//
//  MathResourceBundle.swift
//  BonsAI vendoring patch — the ONLY functional divergence from upstream SwiftMath 1.7.3.
//
//  SwiftPM's generated `Bundle.module` accessor for plain `swift build` only checks
//  `Bundle.main.bundleURL/<bundle>` (the app root) and a hard-coded absolute build path baked in
//  at compile time. BonsAI is a hand-staged .app that keeps SwiftPM resource bundles in the
//  codesign-clean `Contents/Resources/`, so on any machine without the builder's `.build`
//  directory the accessor's static initializer traps — this took down every installed 1.3.1 the
//  moment an equation rendered (the same failure `Bundle.appResources` fixed for the app's own
//  bundle in 1.0.1). All internal `Bundle.module` uses are redirected here.
//

import Foundation

extension Bundle {
    /// Resolves `SwiftMath_SwiftMath.bundle` from every sane app layout before deferring to the
    /// generated `Bundle.module` (which still covers `swift run`/`swift test` from the build dir).
    static let swiftMathResources: Bundle = {
        let name = "SwiftMath_SwiftMath.bundle"
        var seen = Set<String>()
        var candidates: [URL] = []
        func consider(_ dir: URL?) {
            guard let dir, seen.insert(dir.path).inserted else { return }
            candidates.append(dir)
        }
        consider(main.resourceURL)                                 // Contents/Resources (canonical app layout)
        consider(main.bundleURL)                                   // app root (SwiftPM executable layout)
        consider(main.executableURL?.deletingLastPathComponent())  // Contents/MacOS (next to the binary)
        consider(main.resourceURL?.deletingLastPathComponent())    // Contents (defensive)

        for dir in candidates {
            if let bundle = Bundle(url: dir.appendingPathComponent(name)) {
                return bundle
            }
        }
        return .module
    }()
}
