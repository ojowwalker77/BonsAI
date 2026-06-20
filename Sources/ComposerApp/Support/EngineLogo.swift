import SwiftUI
import AppKit

struct EngineLogo: View {
  let engine: HeadlessEngine

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

  private func logoImage(_ image: NSImage) -> some View {
    Image(nsImage: image)
      .resizable()
      .scaledToFit()
  }
}

/// The mark for the in-canvas agent: the active engine's brand logo (Claude today), falling back to
/// the Apple Intelligence mark when no CLI engine is enabled and available.
struct AgentEngineIcon: View {
  var size: CGFloat = 15
  @ObservedObject private var capabilities = EngineCapabilityStore.shared

  var body: some View {
    if EnginePreferences.isEnabled(.claude), capabilities.isAvailable(.claude) {
      EngineLogo(engine: .claude)
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
