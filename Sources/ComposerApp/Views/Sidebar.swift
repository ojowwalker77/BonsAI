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

/// The agent toggle — the one standing accent in the chrome (issue #75: it used to blend into
/// its neighbors in flat `body` ink). Same pill grammar as the Update pill: glyph + word mark in
/// accent ink; the open dock adds a quiet `accentFill` capsule so state reads at rest too.
struct SidebarAgentButton: View {
  var active: Bool
  var side: CGFloat = WindowChrome.controlHeight
  var action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 5) {
        Image(systemName: "sparkle")
          .font(WindowChrome.labelFont)
        Text("AI Agent".localizedUI)
          .font(WindowChrome.labelFont)
          .lineLimit(1)
      }
      .foregroundStyle(Theme.Palette.accent)
      .padding(.horizontal, WindowChrome.labelPadH)
      .frame(height: side)
      .background(Capsule().fill(active ? Theme.Palette.accentFill : Color.clear))
      .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .onHover { if $0 { Haptics.hover() } }
    .help("Chat with the agent on this board  ⌘J".localizedUI)
    .animation(.easeOut(duration: 0.12), value: active)
  }
}
