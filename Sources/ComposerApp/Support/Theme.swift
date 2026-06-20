import SwiftUI
import AppKit

// MARK: - Design tokens

/// One source of truth for spatial, material, color, and motion tokens.
/// Colors are adaptive so the panel and popovers follow the system appearance.
enum Theme {
  static var nsBodyText: NSColor {
    Adaptive.ns(light: Adaptive.white(0.04, 0.84), dark: Adaptive.white(1.00, 0.88))
  }

  static var nsPlaceholderText: NSColor {
    Adaptive.ns(light: Adaptive.white(0.02, 0.38), dark: Adaptive.white(1.00, 0.48))
  }

  enum Radius {
    static let panel: CGFloat = 22
    static let actionBar: CGFloat = 12
    static let menu: CGFloat = 14
    static let row: CGFloat = 9
  }

  enum Material {
    static let hud: NSVisualEffectView.Material = .hudWindow      // canvas backdrop
    static let popover: NSVisualEffectView.Material = .popover    // selection action bar
    static let menu: NSVisualEffectView.Material = .menu          // @-mention list
  }

  enum Size {
    /// The whole panel (card + the rail/toolbar gutters) fills this fraction of the screen's
    /// visible frame, centered — Composer is a near-fullscreen canvas. The card auto-derives
    /// from the window size minus the gutters in the canvas layout.
    static let screenFraction: CGFloat = 0.95
    /// Main-surface measurements are proportions of the current viewport. They deliberately live
    /// here instead of as point constants: opening the dock must redistribute the *actual* window
    /// width, whether Composer is on a compact laptop display or a wide external screen.
    static func railGutter(in windowWidth: CGFloat) -> CGFloat {
      // This owns the rail itself plus a small gap before the board card begins. Kept tight
      // (6%) so the rail reads as attached to the board rather than marooned at the screen edge;
      // it's the floor before the fixed-width rail starts crowding the card.
      (max(windowWidth, 0) * 0.060).rounded()
    }
    static func railInset(in windowWidth: CGFloat) -> CGFloat {
      (max(windowWidth, 0) * 0.014).rounded()
    }
    static func toolbarGutter(in windowHeight: CGFloat) -> CGFloat {
      (max(windowHeight, 0) * 0.060).rounded()
    }
    static func toolbarInset(in windowHeight: CGFloat) -> CGFloat {
      (max(windowHeight, 0) * 0.012).rounded()
    }
    static func dockMargin(in windowWidth: CGFloat) -> CGFloat {
      (max(windowWidth, 0) * 0.009).rounded()
    }
    static func dockWidth(in windowWidth: CGFloat) -> CGFloat {
      (max(windowWidth, 0) * 0.24).rounded()
    }
    static let actionBarHeight: CGFloat = 34
    static let actionBarItemHeight: CGFloat = 28
    static let menuWidth: CGFloat = 320
    static let menuRowHeight: CGFloat = 36
    static let menuMaxVisibleRows: CGFloat = 6
  }

  enum Inset {
    static let horizontal: CGFloat = 60
    static let editorTop: CGFloat = 34
    static let countBottom: CGFloat = 14
    static let textContainer = NSSize(width: 4, height: 8)
  }

  enum Typography {
    static var body: NSFont { ComposerPreferences.editorFont }
    static let bodyLineSpacing: CGFloat = 3
    static let count = SwiftUI.Font.caption2
    static let menuName = SwiftUI.Font.body
    static let menuDesc = SwiftUI.Font.caption
    static let actionLabel = SwiftUI.Font.body.weight(.medium)
    static let actionIcon = SwiftUI.Font.body.weight(.medium)
  }

  /// All foreground and surface colors are adaptive. Avoid hard-coded white/black in views.
  enum Palette {
    static var body: Color { Color(nsColor: Theme.nsBodyText) }
    static var title: Color { Adaptive.color(light: Adaptive.white(0.02, 0.42), dark: Adaptive.white(1.00, 0.36)) }
    static var count: Color { Adaptive.color(light: Adaptive.white(0.02, 0.30), dark: Adaptive.white(1.00, 0.22)) }
    static var placeholder: Color { Color(nsColor: Theme.nsPlaceholderText) }
    static var menuDesc: Color { Adaptive.color(light: Adaptive.white(0.02, 0.58), dark: Adaptive.white(1.00, 0.58)) }

    static var accentFill: Color { Color.accentColor.opacity(0.20) }
    static var rowFill: Color { Adaptive.color(light: Adaptive.white(0.00, 0.045), dark: Adaptive.white(1.00, 0.055)) }
    static var selectedRowFill: Color { Color.accentColor.opacity(0.24) }

    static var panelBase: Color {
      Adaptive.color(
        light: Adaptive.srgb(0.965, 0.960, 0.945),
        dark: Adaptive.srgb(0.070, 0.078, 0.086)
      )
    }
    static var panelScrim: Color { Adaptive.color(light: Adaptive.white(1.00, 0.50), dark: Adaptive.white(0.00, 0.66)) }
    static var panelBottomShade: Color { Adaptive.color(light: Adaptive.white(0.00, 0.035), dark: Adaptive.white(0.00, 0.10)) }
    static var panelTopSheen: Color { Adaptive.color(light: Adaptive.white(1.00, 0.46), dark: Adaptive.white(1.00, 0.04)) }
    static var panelHairline: Color { Adaptive.color(light: Adaptive.white(0.00, 0.10), dark: Adaptive.white(1.00, 0.08)) }
    static var panelInnerLine: Color { Adaptive.color(light: Adaptive.white(1.00, 0.40), dark: Adaptive.white(1.00, 0.06)) }

    static var popupScrim: Color { Adaptive.color(light: Adaptive.white(1.00, 0.56), dark: Adaptive.white(0.00, 0.24)) }
    static var popupSheen: Color { Adaptive.color(light: Adaptive.white(1.00, 0.38), dark: Adaptive.white(1.00, 0.045)) }
    static var popupHairline: Color { Adaptive.color(light: Adaptive.white(0.00, 0.10), dark: Adaptive.white(1.00, 0.08)) }

    /// Uniform legibility tint + edge for the unified Liquid Glass surface (forced-dark panel).
    static var raisedTint: Color { Color.black.opacity(0.16) }
    static var raisedRim: Color { Color.white.opacity(0.07) }

    static var barScrim: Color { Adaptive.color(light: Adaptive.white(1.00, 0.60), dark: Adaptive.white(0.00, 0.42)) }
    static var barHairline: Color { Adaptive.color(light: Adaptive.white(0.00, 0.10), dark: Adaptive.white(1.00, 0.08)) }
    static var barSheen: Color { Adaptive.color(light: Adaptive.white(1.00, 0.36), dark: Adaptive.white(1.00, 0.055)) }

    static var separator: Color { Adaptive.color(light: Adaptive.white(0.00, 0.085), dark: Adaptive.white(1.00, 0.07)) }
    static var keycapFill: Color { Adaptive.color(light: Adaptive.white(0.00, 0.060), dark: Adaptive.white(1.00, 0.08)) }
    static var segmentedFill: Color { Adaptive.color(light: Adaptive.white(0.00, 0.045), dark: Adaptive.white(1.00, 0.05)) }
    static var tagFill: Color { Adaptive.color(light: Adaptive.white(0.00, 0.060), dark: Adaptive.white(1.00, 0.075)) }
    static var buttonHover: Color { Adaptive.color(light: Adaptive.white(0.00, 0.070), dark: Adaptive.white(1.00, 0.12)) }
    static var toastScrim: Color { Adaptive.color(light: Adaptive.white(1.00, 0.42), dark: Adaptive.white(0.00, 0.35)) }
  }

  enum Shadow {
    static var panel: (color: Color, radius: Double, y: Double) {
      (Adaptive.color(light: Adaptive.white(0.00, 0.20), dark: Adaptive.white(0.00, 0.45)), 36.0, 18.0)
    }
    static var bar: (color: Color, radius: Double, y: Double) {
      (Adaptive.color(light: Adaptive.white(0.00, 0.18), dark: Adaptive.white(0.00, 0.36)), 18.0, 8.0)
    }
    static var menu: (color: Color, radius: Double, y: Double) {
      (Adaptive.color(light: Adaptive.white(0.00, 0.16), dark: Adaptive.white(0.00, 0.25)), 16.0, 8.0)
    }
  }

  enum Motion {
    static let accessory = Animation.spring(response: 0.28, dampingFraction: 0.82)
    static let dismissDuration = 0.16
    static let selectionDebounce: TimeInterval = 0.10
  }
}

// MARK: - Adaptive colors

private enum Adaptive {
  static func ns(light: NSColor, dark: NSColor) -> NSColor {
    NSColor(name: nil) { appearance in
      isDark(appearance) ? dark : light
    }
  }

  static func color(light: NSColor, dark: NSColor) -> Color {
    Color(nsColor: ns(light: light, dark: dark))
  }

  static func white(_ white: CGFloat, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(white: white, alpha: alpha)
  }

  static func srgb(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
  }

  private static func isDark(_ appearance: NSAppearance) -> Bool {
    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
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

// MARK: - Shared surfaces

extension View {
  /// THE one cohesive raised surface for every floating element — menus, lists, bars, the
  /// rail. Real Liquid Glass on macOS 26, a uniform dark-vibrancy fallback elsewhere.
  /// Deliberately uniform (no internal gradient), so it never shifts shade over a busy
  /// or light backdrop the way a manual sheen does.
  @ViewBuilder
  func floatingGlass<S: Shape>(_ shape: S) -> some View {
    if #available(macOS 26.0, *) {
      self
        .clipShape(shape)
        .background(Theme.Palette.raisedTint, in: shape)
        .glassEffect(.regular, in: shape)
    } else {
      self
        .background {
          ZStack {
            VisualEffectBackground(material: Theme.Material.menu, blending: .withinWindow, state: .active)
            Theme.Palette.popupScrim
          }
        }
        .clipShape(shape)
        .shadow(color: Theme.Shadow.menu.color, radius: Theme.Shadow.menu.radius, y: Theme.Shadow.menu.y)
    }
  }

  /// Rounded popover surface used by every menu/list overlay.
  func composerPopupSurface(radius: CGFloat = Theme.Radius.menu) -> some View {
    floatingGlass(RoundedRectangle(cornerRadius: radius, style: .continuous))
  }
}

// MARK: - Panel backdrop

/// The frosted, rounded, scrimmed card the whole canvas sits on.
struct ComposerPanelBackground: View {
  var radius: CGFloat = Theme.Radius.panel
  @AppStorage(ComposerPreferences.panelTransparencyKey) private var panelTransparency = ComposerPreferences.defaultPanelTransparency

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
    // 0 = Opaque, maxPanelTransparency = Glass. Normalize to 0…1 so the tint sweeps a
    // wide, obviously-live range as the slider moves.
    let glass = ComposerPreferences.clampedPanelTransparency(panelTransparency) / ComposerPreferences.maxPanelTransparency
    let tint = 0.80 - 0.58 * glass

    ZStack {
      // Genuine frosted glass: `.behindWindow` samples and blurs the desktop behind the
      // panel (Spotlight / Control Center vibrancy), not just content within the window.
      VisualEffectBackground(material: .hudWindow, blending: .behindWindow, state: .active)

      // Legibility tint over the blur — recedes toward Glass, deepens toward Opaque.
      Color.black.opacity(tint)

      // Top sheen → clear → faint floor gives the slab depth.
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
    .ignoresSafeArea()
  }
}
