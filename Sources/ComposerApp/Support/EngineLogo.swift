import SwiftUI
import AppKit

struct EngineLogo: View {
  let engine: HeadlessEngine

  var body: some View {
    Group {
      if let image = NSImage.brandLogo(named: engine.logoResourceName) {
        Image(nsImage: image)
          .resizable()
          .scaledToFit()
      } else {
        Image(systemName: engine.systemImage)
          .resizable()
          .scaledToFit()
      }
    }
    .frame(width: 15, height: 15)
    .accessibilityHidden(true)
  }
}

private extension NSImage {
  static func brandLogo(named name: String) -> NSImage? {
    guard let url = Bundle.module.url(forResource: name, withExtension: "svg")
      ?? Bundle.module.url(forResource: name, withExtension: "svg", subdirectory: "Logos") else {
      return nil
    }
    return NSImage(contentsOf: url)
  }
}
