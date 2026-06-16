import SwiftUI
import AppKit

// MARK: - Design tokens

/// One source of truth for everything spatial, material, and temporal.
/// The app is a single translucent card, so the token set is deliberately small.
enum Theme {
  static let nsBodyText = NSColor.white.withAlphaComponent(0.88)
  static let nsPlaceholderText = NSColor.white.withAlphaComponent(0.48)

  enum Radius {
    static let panel: CGFloat = 22
    static let actionBar: CGFloat = 10
    static let menu: CGFloat = 10
    static let row: CGFloat = 7
  }

  enum Material {
    static let hud: NSVisualEffectView.Material = .hudWindow      // canvas backdrop
    static let popover: NSVisualEffectView.Material = .popover    // selection action bar
    static let menu: NSVisualEffectView.Material = .menu          // @-mention list
  }

  enum Size {
    static let widthFraction: CGFloat = 0.52
    static let heightFraction: CGFloat = 0.62
    static let minWidth: CGFloat = 560, maxWidth: CGFloat = 820
    static let minHeight: CGFloat = 420, maxHeight: CGFloat = 680
    static let opticalLift: CGFloat = 0.06   // nudge the panel up 6% of its height

    static let actionBarHeight: CGFloat = 34
    static let actionBarItemHeight: CGFloat = 28
    static let menuWidth: CGFloat = 300
    static let menuRowHeight: CGFloat = 32
    static let menuMaxVisibleRows: CGFloat = 6
  }

  enum Inset {
    static let horizontal: CGFloat = 60
    static let titleTop: CGFloat = 16
    static let editorTop: CGFloat = 22
    static let countBottom: CGFloat = 14
    static let textContainer = NSSize(width: 4, height: 8)
  }

  enum Typography {
    static let body = NSFont.preferredFont(forTextStyle: .body)
    static let bodyLineSpacing: CGFloat = 3
    static let title = SwiftUI.Font.caption
    static let count = SwiftUI.Font.caption2
    static let menuName = SwiftUI.Font.body
    static let menuDesc = SwiftUI.Font.caption
    static let actionLabel = SwiftUI.Font.body.weight(.medium)
    static let actionIcon = SwiftUI.Font.body.weight(.medium)
  }

  /// All text is driven from semantic colors so alpha resolves correctly on vibrancy.
  enum Palette {
    static let body = Color.white.opacity(0.88)
    static let title = Color.white.opacity(0.36)
    static let count = Color.white.opacity(0.22)
    static let placeholder = Color.white.opacity(0.48)
    static let menuDesc = Color.white.opacity(0.58)
    static let accentFill = Color.accentColor.opacity(0.20)
    static let rowFill = Color.white.opacity(0.055)
    static let selectedRowFill = Color.accentColor.opacity(0.28)

    static let panelBase = Color(red: 0.070, green: 0.078, blue: 0.086)
    static let panelScrim = Color.black.opacity(0.78)
    static let panelBottomShade = Color.black.opacity(0.10)
    static let panelTopSheen = Color.white.opacity(0.035)
    static let panelHairline = Color.clear
    static let panelInnerLine = Color.clear
    static let barScrim = Color.black.opacity(0.42)
    static let barHairline = Color.clear
    static let buttonHover = Color.white.opacity(0.12)
  }

  enum Shadow {
    static let panel = (color: Color.black.opacity(0.45), radius: 36.0, y: 18.0)
    static let bar = (color: Color.black.opacity(0.36), radius: 18.0, y: 8.0)
    static let menu = (color: Color.black.opacity(0.25), radius: 16.0, y: 8.0)
  }

  enum Motion {
    static let accessory = Animation.spring(response: 0.28, dampingFraction: 0.82)
    static let dismissDuration = 0.16
    static let selectionDebounce: TimeInterval = 0.10
  }
}

// MARK: - Vibrancy

/// Native `NSVisualEffectView` so the panel picks up real desktop translucency.
struct VisualEffectBackground: NSViewRepresentable {
  var material: NSVisualEffectView.Material = .underWindowBackground
  var blending: NSVisualEffectView.BlendingMode = .behindWindow
  var emphasized: Bool = false
  var state: NSVisualEffectView.State = .followsWindowActiveState
  var forceDark: Bool = false

  func makeNSView(context: Context) -> NSVisualEffectView {
    let view = NSVisualEffectView()
    apply(to: view)
    return view
  }

  func updateNSView(_ view: NSVisualEffectView, context: Context) { apply(to: view) }

  private func apply(to view: NSVisualEffectView) {
    view.material = material
    view.blendingMode = blending
    view.state = state
    view.isEmphasized = emphasized
    view.appearance = forceDark ? NSAppearance(named: .darkAqua) : nil
  }
}

// MARK: - Panel backdrop

/// The frosted, rounded, scrimmed card the whole canvas sits on.
struct ComposerPanelBackground: View {
  var radius: CGFloat = Theme.Radius.panel

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
    ZStack {
      VisualEffectBackground(
        material: Theme.Material.popover,
        blending: .withinWindow,
        state: .active,
        forceDark: true
      )
      Theme.Palette.panelBase
      Theme.Palette.panelScrim
      LinearGradient(
        stops: [
          .init(color: Theme.Palette.panelTopSheen, location: 0),
          .init(color: Color.clear, location: 0.34),
          .init(color: Theme.Palette.panelBottomShade, location: 1)
        ],
        startPoint: .top,
        endPoint: .bottom
      )
    }
    .clipShape(shape)
    .shadow(color: Theme.Shadow.panel.color, radius: Theme.Shadow.panel.radius, y: Theme.Shadow.panel.y)
    .ignoresSafeArea()
  }
}
