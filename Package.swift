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
  targets: [
    .executableTarget(
      name: "ComposerApp",
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
