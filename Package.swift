// swift-tools-version: 5.9

import PackageDescription

let package = Package(
  name: "Composer",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .executable(name: "Composer", targets: ["ComposerApp"])
  ],
  targets: [
    .executableTarget(
      name: "ComposerApp",
      path: "Sources/ComposerApp",
      resources: [.process("Resources")]
    )
  ]
)
