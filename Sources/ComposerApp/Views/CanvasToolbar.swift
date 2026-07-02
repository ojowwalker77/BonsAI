import SwiftUI

/// The board tool. `select` moves/edits existing elements; the others drop a new element where
/// you click.
enum CanvasTool: Equatable {
  case select
  case text
  case rectangle
  case ellipse
  case diamond
  case line
  case arrow
  case freehand
  case image

  var elementKind: CanvasElementKind? {
    switch self {
    case .select: nil
    case .text: .text
    case .rectangle: .rectangle
    case .ellipse: .ellipse
    case .diamond: .diamond
    case .line: .line
    case .arrow: .arrow
    case .freehand: .freehand
    case .image: .image
    }
  }

  /// Shapes & lines are sized by dragging (press → drag → release). Text is click-to-place
  /// (it auto-grows as you type), freehand has its own stroke capture, select marquees.
  var placesByDragging: Bool {
    switch self {
    case .rectangle, .ellipse, .diamond, .line, .arrow: true
    default: false
    }
  }

  /// Shift constrains box-shape drags to a square (see `CanvasElementKind.constrainsToSquare`).
  var constrainsToSquare: Bool { elementKind?.constrainsToSquare ?? false }
}

/// The canvas tool cluster — the eight placement/selection tools, rendered bare so the bottom
/// command bar can lay it alongside zoom and session utilities under one shared glass surface.
struct CanvasToolbar: View {
  @Binding var tool: CanvasTool

  var body: some View {
    HStack(spacing: 5) {
      ToolButton(symbol: "cursorarrow", help: "Select  ·  move & edit cards  ⌘1",
                 active: tool == .select, shortcut: 1) { tool = .select }
      ToolButton(symbol: "character", help: "Text  ·  click the board, then type  ⌘2",
                 active: tool == .text, shortcut: 2) { tool = .text }
      ToolButton(symbol: "rectangle", help: "Rectangle  ·  drag to draw  ⌘3",
                 active: tool == .rectangle, shortcut: 3) { tool = .rectangle }
      ToolButton(symbol: "circle", help: "Ellipse  ·  drag to draw  ⌘4",
                 active: tool == .ellipse, shortcut: 4) { tool = .ellipse }
      ToolButton(symbol: "diamond", help: "Diamond  ·  drag to draw  ⌘5",
                 active: tool == .diamond, shortcut: 5) { tool = .diamond }
      ToolButton(symbol: "line.diagonal", help: "Line  ·  drag to draw  ⌘6",
                 active: tool == .line, shortcut: 6) { tool = .line }
      ToolButton(symbol: "arrow.up.right", help: "Arrow  ·  drag to draw  ⌘7",
                 active: tool == .arrow, shortcut: 7) { tool = .arrow }
      ToolButton(symbol: "scribble.variable", help: "Freehand stroke  ·  drag to draw  ⌘8",
                 active: tool == .freehand, shortcut: 8) { tool = .freehand }
    }
  }
}

/// Tool buttons share the chrome grid — same square, same glyph size as every other control.
private enum ToolMetrics {
  static let side: CGFloat = WindowChrome.controlHeight
  static let icon: CGFloat = WindowChrome.iconSize
}

private struct ToolButton: View {
  let symbol: String
  let help: String
  var active = false
  var disabled = false
  /// While true the glyph is swapped for a spinner and the button is inert — for actions that
  /// run a `claude -p` call (e.g. board Copy).
  var busy = false
  /// The ⌘-number that activates this tool, shown as a small corner badge.
  var shortcut: Int? = nil
  var action: () -> Void
  @State private var hovering = false

  var body: some View {
    Button(action: { Haptics.tap(); action() }) {
      Group {
        if busy {
          ProgressView()
            .controlSize(.small)
            .tint(Theme.Palette.chromeGlyphHover)
        } else {
          Image(systemName: symbol)
            .font(WindowChrome.iconFont)
            .foregroundStyle(foreground)
        }
      }
      .frame(width: ToolMetrics.side, height: ToolMetrics.side)
      // No blue fill for the active state — the accent-tinted glyph is the signal; the only
      // background is a neutral hover wash.
      .background(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(hovering && !disabled && !busy ? Theme.Palette.hoverWash : Color.clear)
      )
      .overlay(alignment: .bottomTrailing) {
        if let shortcut, !busy {
          Text("\(shortcut)")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(active ? Theme.Palette.accent : (hovering ? Theme.Palette.chromeGlyph : Theme.Palette.chromeBadge))
            .padding(.trailing, 3).padding(.bottom, 2)
        }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(disabled || busy)
    .onHover { hovering = $0 }
    .help(help)
    .animation(.easeOut(duration: 0.12), value: hovering)
  }

  private var foreground: AnyShapeStyle {
    if disabled { return AnyShapeStyle(Theme.Palette.chromeGlyphDim) }
    if active { return AnyShapeStyle(Theme.Palette.accent) }
    return AnyShapeStyle(hovering ? Theme.Palette.chromeGlyphHover : Theme.Palette.chromeGlyph)
  }
}
