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

/// The mark for the in-canvas agent: the active engine's brand logo (Claude preferred, then
/// Codex), falling back to the Apple Intelligence mark when the user has neither enabled.
struct AgentEngineIcon: View {
  var size: CGFloat = 15

  var body: some View {
    if EnginePreferences.isEnabled(.claude) {
      EngineLogo(engine: .claude)
    } else if EnginePreferences.isEnabled(.codex) {
      EngineLogo(engine: .codex)
    } else {
      Image(systemName: "apple.intelligence")
        .resizable()
        .scaledToFit()
        .frame(width: size, height: size)
        .foregroundStyle(
          AngularGradient(
            gradient: Gradient(colors: [.orange, .red, .purple, .blue, .cyan, .orange]),
            center: .center))
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
