import SwiftUI

/// Shared icon-button components for the floating chrome (bottom command bar, action pills).

struct SidebarButton: View {
  let symbol: String
  let help: String
  var active = false
  var disabled = false
  var side: CGFloat = WindowChrome.controlHeight
  var action: () -> Void
  @State private var hovering = false

  var body: some View {
    Button(action: { Haptics.tap(); action() }) {
      Image(systemName: symbol)
        .font(WindowChrome.iconFont)
        .foregroundStyle(foreground)
        .frame(width: side, height: side)
        .background(
          // Active reads through the accent-tinted icon (below) — no blue fill, just a neutral
          // hover wash so the control still feels live.
          Circle().fill(hovering && !disabled ? Theme.Palette.hoverWash : Color.clear)
        )
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .disabled(disabled)
    .onHover { hovering = $0 }
    .help(help)
    .animation(.easeOut(duration: 0.12), value: hovering)
  }

  // Adaptive chrome tokens: white-keyed on the dark rail, ink-keyed on light glass.
  private var foreground: AnyShapeStyle {
    if disabled { return AnyShapeStyle(Theme.Palette.chromeGlyphDim) }
    if active { return AnyShapeStyle(Theme.Palette.accent) }
    return AnyShapeStyle(hovering ? Theme.Palette.chromeGlyphHover : Theme.Palette.chromeGlyph)
  }
}

/// The agent toggle — shows the active engine's brand mark. There's no active ring or fill;
/// open/closed reads from the dock itself, and the mark just brightens on hover or when the dock
/// is open. Lives on the rail in floating mode, in the top-right actions pill in window mode.
struct SidebarAgentButton: View {
  var active: Bool
  var side: CGFloat = WindowChrome.controlHeight
  var action: () -> Void
  @State private var hovering = false

  var body: some View {
    Button(action: { Haptics.tap(); action() }) {
      AgentEngineIcon(size: 18)
        .frame(width: side, height: side)
        .opacity(active ? 1 : (hovering ? 0.95 : 0.78))
        .background(Circle().fill(hovering ? Theme.Palette.hoverWash : Color.clear))
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
    .help("Chat with the agent on this board  ⌘J")
    .animation(.easeOut(duration: 0.12), value: hovering)
  }
}
