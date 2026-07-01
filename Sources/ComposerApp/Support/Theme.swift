import SwiftUI
import AppKit

// MARK: - Design tokens

/// One source of truth for spatial, material, color, and motion tokens.
/// Colors resolve through the selected `ThemeFlavor` — no view ever hard-codes a hex; tokens map
/// semantic roles onto flavor slots. A theme switch rebuilds the canvas (PanelController), so
/// plain colors are safe here.
enum Theme {
  /// The active flavor (Settings ▸ Appearance ▸ Theme).
  static var flavor: ThemeFlavor { ComposerPreferences.theme.flavor }

  static var nsBodyText: NSColor { flavor.text }

  static var nsPlaceholderText: NSColor { flavor.overlay1 }

  /// The solid canvas — the flavor's `base`.
  static var nsWindowCanvas: NSColor { flavor.base }

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

  /// Semantic roles mapped onto the active flavor's slots. Views consume ONLY these tokens.
  enum Palette {
    private static func c(_ ns: NSColor, _ alpha: CGFloat = 1) -> Color {
      Color(nsColor: alpha == 1 ? ns : ns.withAlphaComponent(alpha))
    }

    /// The one accent (mauve on Catppuccin, the system accent on Bonsai themes).
    static var accent: Color { c(Theme.flavor.accent) }
    static var nsAccent: NSColor { Theme.flavor.accent }

    static var body: Color { c(Theme.flavor.text) }
    static var title: Color { c(Theme.flavor.overlay1) }
    static var count: Color { c(Theme.flavor.overlay0) }
    static var placeholder: Color { c(Theme.flavor.overlay1) }
    static var menuDesc: Color { c(Theme.flavor.subtext0) }

    static var accentFill: Color { c(Theme.flavor.accent, 0.20) }
    static var rowFill: Color { c(Theme.flavor.surface0, 0.45) }
    static var selectedRowFill: Color { c(Theme.flavor.accent, 0.24) }

    static var panelHairline: Color { c(Theme.flavor.overlay0, 0.35) }
    static var panelInnerLine: Color { c(Theme.flavor.surface2, 0.30) }

    static var popupScrim: Color { c(Theme.flavor.base, 0.60) }

    /// Uniform legibility tint under the Liquid Glass surface — the flavor's own base, so pills
    /// read as raised canvas material in every theme.
    static var raisedTint: Color { c(Theme.flavor.base, 0.45) }
    static var raisedRim: Color { c(Theme.flavor.overlay0, 0.25) }

    static var windowCanvas: Color { c(Theme.flavor.base) }

    /// Chrome tokens for the floating pills, bars, and their controls.
    static var chromeGlyph: Color { c(Theme.flavor.subtext1) }
    static var chromeGlyphHover: Color { c(Theme.flavor.text) }
    static var chromeGlyphDim: Color { c(Theme.flavor.overlay0) }
    static var chromeBadge: Color { c(Theme.flavor.overlay1) }
    static var chromeText: Color { c(Theme.flavor.subtext1) }
    static var hoverWash: Color { c(Theme.flavor.surface1, 0.55) }
    static var chromeDivider: Color { c(Theme.flavor.surface2, 0.80) }
    /// Ink for freehand strokes drawn straight on the board.
    static var inkStroke: Color { c(Theme.flavor.text, 0.92) }
    /// Drawn board elements (shapes, lines, arrows).
    static var elementStroke: Color { c(Theme.flavor.text, 0.85) }
    /// Shape interiors: unfilled on light themes (outline-only, like a whiteboard); a soft surface
    /// fill on dark ones, where it grounds the shape against the canvas. The light value is
    /// near-zero alpha rather than `.clear` so the interior still hit-tests for select.
    static var elementFill: Color {
      Theme.flavor.isDark ? c(Theme.flavor.surface0, 0.55) : c(Theme.flavor.text, 0.001)
    }
    /// Elements cast a grounding shadow only on dark themes — ink on paper casts none.
    static var elementShadow: Color {
      Theme.flavor.isDark ? c(Theme.flavor.crust, 0.55) : Color.clear
    }
    /// The shape-label chip: solid fills (a translucent fill lets the chip's own shadow bleed
    /// through and muddy it — the "gray smear" bug).
    static var labelChipFill: Color {
      Theme.flavor.isDark ? c(Theme.flavor.surface0) : c(Theme.flavor.mantle)
    }

    static var separator: Color { c(Theme.flavor.surface2, 0.60) }
    static var keycapFill: Color { c(Theme.flavor.surface0, 0.70) }
    static var segmentedFill: Color { c(Theme.flavor.surface0, 0.55) }
    static var tagFill: Color { c(Theme.flavor.surface0, 0.60) }
    static var buttonHover: Color { c(Theme.flavor.surface1, 0.80) }
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

/// The canvas backdrop: the solid board surface (black in dark, paper white in light) over a
/// behind-window desktop blur. At the default 0 transparency the surface is fully opaque —
/// indistinguishable from solid; sliding up recedes it so the frosted desktop shows through.
struct ComposerPanelBackground: View {
  @AppStorage(ComposerPreferences.canvasTransparencyKey) private var canvasTransparency = 0.0

  var body: some View {
    let glass = ComposerPreferences.clampedCanvasTransparency(canvasTransparency)
      / ComposerPreferences.maxCanvasTransparency
    ZStack {
      VisualEffectBackground(material: .hudWindow, blending: .behindWindow, state: .active)
      Theme.Palette.windowCanvas.opacity(1.0 - 0.65 * glass)
    }
    .ignoresSafeArea()
  }
}
