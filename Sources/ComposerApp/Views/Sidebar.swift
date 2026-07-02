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
    Button(action: action) {
      Image(systemName: symbol)
        .font(WindowChrome.iconFont)
        .foregroundStyle(foreground)
        .frame(width: side, height: side)
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .disabled(disabled)
    // No hover background anywhere in the chrome — the trackpad tick is the hover feedback,
    // plus the glyph brightening below.
    .onHover { over in
      hovering = over
      if over, !disabled { Haptics.hover() }
    }
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

/// The agent toggle — a word-mark pill matching the Export pill's rest label: flat `body` ink,
/// hover feedback is the trackpad tick. There's no active ring or fill; open/closed reads
/// from the dock itself. Lives in the top-right actions pill.
struct SidebarAgentButton: View {
  var active: Bool
  var side: CGFloat = WindowChrome.controlHeight
  var action: () -> Void

  var body: some View {
    Button(action: action) {
      Text("AI Agent")
        .font(WindowChrome.labelFont)
        .foregroundStyle(Theme.Palette.body)
        .lineLimit(1)
        .padding(.horizontal, WindowChrome.labelPadH)
        .frame(height: side)
        .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .onHover { if $0 { Haptics.hover() } }
    .help("Chat with the agent on this board  ⌘J")
  }
}
