// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "Composer",
  platforms: [
    .macOS(.v26)
  ],
  products: [
    .executable(name: "Composer", targets: ["ComposerApp"])
  ],
  dependencies: [
    // Sparkle drives the in-app auto-update (periodic check → download → install → relaunch). It is
    // bundled into the hand-staged .app by script/build_and_run.sh, which copies Sparkle.framework
    // into Contents/Frameworks and adds the loader rpath. The only external dependency.
    .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
  ],
  targets: [
    .executableTarget(
      name: "ComposerApp",
      dependencies: [.product(name: "Sparkle", package: "Sparkle")],
      path: "Sources/ComposerApp",
      resources: [.process("Resources")],
      // Tools-version 6 defaults to the Swift 6 language mode (strict
      // concurrency). Stay on Swift 5 mode — the macOS 26 bump is about the
      // deployment target, not a concurrency migration.
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
