import SwiftUI
import AppKit

// MARK: - Design tokens

/// One source of truth for spatial, material, color, and motion tokens.
/// Colors are adaptive so the panel and popovers follow the system appearance.
enum Theme {
  /// Light mode never uses pure black ink — every glyph, stroke, and text lands on #575757.
  /// One constant so the whole light palette derives from a single ink.
  static let lightInk: CGFloat = 0.341   // #575757

  static var nsBodyText: NSColor {
    Adaptive.ns(light: Adaptive.white(lightInk), dark: Adaptive.white(1.00, 0.88))
  }

  static var nsPlaceholderText: NSColor {
    Adaptive.ns(light: Adaptive.white(lightInk, 0.52), dark: Adaptive.white(1.00, 0.48))
  }

  /// The standard window's solid canvas: pure black in dark, paper white in light (the Books-style
  /// reference). Shared by the window's AppKit backing and the SwiftUI canvas surface so the
  /// system-rounded corners never show a mismatched sliver.
  static var nsWindowCanvas: NSColor {
    Adaptive.ns(light: Adaptive.white(0.99), dark: Adaptive.white(0.00))
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
    static var title: Color { Adaptive.color(light: Adaptive.white(Theme.lightInk, 0.60), dark: Adaptive.white(1.00, 0.36)) }
    static var count: Color { Adaptive.color(light: Adaptive.white(Theme.lightInk, 0.45), dark: Adaptive.white(1.00, 0.22)) }
    static var placeholder: Color { Color(nsColor: Theme.nsPlaceholderText) }
    static var menuDesc: Color { Adaptive.color(light: Adaptive.white(Theme.lightInk, 0.80), dark: Adaptive.white(1.00, 0.58)) }

    static var accentFill: Color { Color.accentColor.opacity(0.20) }
    static var rowFill: Color { Adaptive.color(light: Adaptive.white(0.00, 0.045), dark: Adaptive.white(1.00, 0.055)) }
    static var selectedRowFill: Color { Color.accentColor.opacity(0.24) }

    static var panelHairline: Color { Adaptive.color(light: Adaptive.white(0.00, 0.10), dark: Adaptive.white(1.00, 0.08)) }
    static var panelInnerLine: Color { Adaptive.color(light: Adaptive.white(1.00, 0.40), dark: Adaptive.white(1.00, 0.06)) }

    static var popupScrim: Color { Adaptive.color(light: Adaptive.white(1.00, 0.56), dark: Adaptive.white(0.00, 0.24)) }

    /// Uniform legibility tint + edge for the unified Liquid Glass surface. Dark tint over the dark
    /// theme; a milky lift in light so controls read as bright glass, not gray slabs.
    static var raisedTint: Color { Adaptive.color(light: Adaptive.white(1.00, 0.44), dark: Adaptive.white(0.00, 0.16)) }
    static var raisedRim: Color { Adaptive.color(light: Adaptive.white(0.00, 0.07), dark: Adaptive.white(1.00, 0.07)) }

    static var windowCanvas: Color { Color(nsColor: Theme.nsWindowCanvas) }

    /// Chrome tokens for the floating rail / toolbar / pill controls. These replace the old
    /// white-keyed literals so the same controls read correctly on light glass. All light-mode
    /// variants derive from the single #575757 ink — never black.
    static var chromeGlyph: Color { Adaptive.color(light: Adaptive.white(Theme.lightInk, 0.85), dark: Adaptive.white(1.00, 0.62)) }
    static var chromeGlyphHover: Color { Adaptive.color(light: Adaptive.white(Theme.lightInk), dark: Adaptive.white(1.00, 0.95)) }
    static var chromeGlyphDim: Color { Adaptive.color(light: Adaptive.white(Theme.lightInk, 0.40), dark: Adaptive.white(1.00, 0.26)) }
    static var chromeBadge: Color { Adaptive.color(light: Adaptive.white(Theme.lightInk, 0.55), dark: Adaptive.white(1.00, 0.34)) }
    static var chromeText: Color { Adaptive.color(light: Adaptive.white(Theme.lightInk, 0.92), dark: Adaptive.white(1.00, 0.78)) }
    static var hoverWash: Color { Adaptive.color(light: Adaptive.white(Theme.lightInk, 0.10), dark: Adaptive.white(1.00, 0.12)) }
    static var chromeDivider: Color { Adaptive.color(light: Adaptive.white(Theme.lightInk, 0.28), dark: Adaptive.white(1.00, 0.12)) }
    /// Ink for freehand strokes drawn straight on the board.
    static var inkStroke: Color { Adaptive.color(light: Adaptive.white(Theme.lightInk), dark: Adaptive.white(1.00, 0.82)) }
    /// Drawn board elements (shapes, lines, arrows): white ink on the dark board, #575757 on light.
    static var elementStroke: Color { Adaptive.color(light: Adaptive.white(Theme.lightInk), dark: Adaptive.white(1.00, 0.72)) }
    /// Shape interiors: unfilled on paper (light mode is outline-only, like a whiteboard); a soft
    /// dark fill on the dark board, where it grounds the shape against the glass. The light value
    /// is near-zero alpha rather than `.clear` so the interior still hit-tests for click-to-select.
    static var elementFill: Color { Adaptive.color(light: Adaptive.white(1.00, 0.001), dark: Adaptive.white(0.00, 0.22)) }
    /// Elements cast a grounding shadow only on the dark board — ink on paper casts none.
    static var elementShadow: Color { Adaptive.color(light: Adaptive.white(0.00, 0.0), dark: Adaptive.white(0.00, 0.22)) }
    /// The shape-label chip: solid fills (a translucent fill lets the chip's own shadow bleed
    /// through and muddy it — the "gray smear" bug).
    static var labelChipFill: Color { Adaptive.color(light: Adaptive.white(0.955), dark: Adaptive.white(0.17)) }

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

// MARK: - Standard-window chrome metrics

/// One design system for the standard-window floating controls — the board pill, the tool bar, the
/// action pill, and the rail all share this control height, inner padding, and corner radius so they
/// read as siblings instead of four bespoke shapes.
enum WindowChrome {
  static let controlHeight: CGFloat = 34
  static let padH: CGFloat = 6
  static let padV: CGFloat = 5
  static let radius: CGFloat = Theme.Radius.menu
  /// Uniform distance every floating control keeps from the window edges (the board pill clears the
  /// traffic lights instead). One number so nothing sits a different distance from its edge.
  static let edgeInset: CGFloat = 16
  /// Left offset for the top-left board pill: the traffic lights (repositioned onto the control
  /// row's centerline, starting at `edgeInset`) end at 16 + 3×14 + 2×6 = 70; +12 breathing room.
  static let trafficLightInset: CGFloat = 82
  /// EVERY chrome glyph: one size, one weight. No inline `.font(.system(size: …))` in chrome views.
  static let iconSize: CGFloat = 17
  static var iconFont: Font { .system(size: iconSize, weight: .medium) }
  /// EVERY chrome text label (board name, zoom %, chip text).
  static var labelFont: Font { .system(size: 13, weight: .medium) }
  /// Inner horizontal padding for a text-bearing control inside a pill (icons are square and
  /// need none).
  static let labelPadH: CGFloat = 10
  /// Spacing between sibling controls inside one pill/bar.
  static let itemSpacing: CGFloat = 4
}

extension View {
  /// THE one wrapper for every floating chrome pill and bar: identical padding, radius, and glass.
  /// Views never add their own surface padding — wrap the control row in this and it is, by
  /// construction, the same size as every other pill.
  func chromePill() -> some View {
    self
      .padding(.horizontal, WindowChrome.padH)
      .padding(.vertical, WindowChrome.padV)
      .composerPopupSurface(radius: WindowChrome.radius)
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

  /// Background for the Agent / Settings panels floating over the canvas — plain Liquid Glass.
  func dockPanelSurface(radius: CGFloat = Theme.Radius.panel) -> some View {
    floatingGlass(RoundedRectangle(cornerRadius: radius, style: .continuous))
  }
}

// MARK: - Panel backdrop

/// The canvas backdrop: a flat, solid, opaque surface — black in dark, paper white in light.
struct ComposerPanelBackground: View {
  var body: some View {
    Theme.Palette.windowCanvas.ignoresSafeArea()
  }
}
