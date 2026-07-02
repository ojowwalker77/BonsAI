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

/// The mark for the in-canvas agent: the brand logo of the engine the chat will actually run on —
/// the user's pick when set, else the preferred available engine — falling back to the Apple
/// Intelligence mark when no CLI engine is enabled and available. Observes both the availability
/// store and the chat-engine pick so it tracks either changing.
struct AgentEngineIcon: View {
  var size: CGFloat = 15
  @ObservedObject private var capabilities = EngineCapabilityStore.shared
  @AppStorage(EnginePreferences.chatEngineKey) private var chatEngineRaw = ""

  var body: some View {
    if let engine = CanvasAgent.resolvedEngine() {
      EngineLogo(engine: engine)
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
    guard let url = Bundle.appResources.url(forResource: name, withExtension: "svg")
      ?? Bundle.appResources.url(forResource: name, withExtension: "svg", subdirectory: "Logos") else {
      return nil
    }
    return NSImage(contentsOf: url)
  }
}
