import SwiftUI
import AppKit

struct EngineLogo: View {
  let engine: HeadlessEngine
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    Group {
      if let image = NSImage.brandLogo(named: engine.logoResourceName) {
        logoImage(image)
      } else {
        Image(systemName: engine.systemImage)
          .resizable()
          .scaledToFit()
      }
    }
    .frame(width: 15, height: 15)
    .accessibilityHidden(true)
  }

  @ViewBuilder
  private func logoImage(_ image: NSImage) -> some View {
    let view = Image(nsImage: image)
      .resizable()
      .scaledToFit()
    if engine == .codex, colorScheme == .light {
      view.colorInvert()
    } else {
      view
    }
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
