// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "Composer",
  platforms: [
    // macOS 14 (Sonoma) is the floor: the board's persistence layer is SwiftData (`@Model` in
    // DumpStore), which requires 14. Everything Tahoe-only — Apple Intelligence (FoundationModels,
    // weak-linked) and Liquid Glass — is gated behind `#available(macOS 26, *)` and degrades
    // gracefully below it, so the core board runs unchanged all the way down to 14.
    .macOS(.v14)
  ],
  products: [
    .executable(name: "Composer", targets: ["ComposerApp"])
  ],
  dependencies: [
    // Sparkle drives the in-app auto-update (periodic check → download → install → relaunch). It is
    // bundled into the hand-staged .app by script/build_and_run.sh, which copies Sparkle.framework
    // into Contents/Frameworks and adds the loader rpath.
    .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    // SwiftMath is the native CoreText LaTeX math typesetter behind the equation canvas item — no
    // web view. Its SwiftPM resource bundle is staged by script/build_and_run.sh with app resources.
    // Vendored (upstream 1.7.3, MIT) because SwiftPM's generated `Bundle.module` accessor for plain
    // `swift build` never checks Contents/Resources — every installed CI build trapped on the first
    // equation render. Vendor/SwiftMath patches its bundle lookups (see MathResourceBundle.swift);
    // everything else is untouched upstream.
    .package(path: "Vendor/SwiftMath")
  ],
  targets: [
    .executableTarget(
      name: "ComposerApp",
      dependencies: [
        .product(name: "Sparkle", package: "Sparkle"),
        .product(name: "SwiftMath", package: "SwiftMath"),
      ],
      path: "Sources/ComposerApp",
      resources: [.process("Resources")],
      // Tools-version 6 defaults to the Swift 6 language mode (strict
      // concurrency). Stay on Swift 5 mode — the deployment target is a
      // compatibility floor, not a concurrency migration.
      swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    .testTarget(
      name: "ComposerAppTests",
      dependencies: ["ComposerApp"],
      path: "Tests/ComposerAppTests",
      swiftSettings: [.swiftLanguageMode(.v5)]
    )
  ]
)
