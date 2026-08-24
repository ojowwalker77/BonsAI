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
  case vectorPen
  case equation
  case image
  case sticky
  case checklist
  case table

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
    case .vectorPen: .vectorPath
    case .equation: .equation
    case .image: .image
    case .sticky: .sticky
    case .checklist: .checklist
    case .table: .table
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

  /// Shift snaps line/arrow drags to the nearer axis (see `CanvasElementKind.constrainsToAxis`).
  var constrainsToAxis: Bool { elementKind?.constrainsToAxis ?? false }

  /// Tools that naturally create a run of peer elements. Text, equations, images, and structured
  /// cards open an editor/chooser and remain one-shot. Pen crosses this same policy after its
  /// multi-click draft commits.
  var isRepeatableDrawingTool: Bool {
    switch self {
    case .rectangle, .ellipse, .diamond, .line, .arrow, .freehand, .vectorPen: true
    default: false
    }
  }

  /// The tool to select after a successful placement. Keeping this policy pure avoids scattering
  /// subtly different one-shot decisions across click, shape-drag, and freehand commit paths.
  func afterSuccessfulPlacement(continuousDrawing: Bool) -> CanvasTool {
    continuousDrawing && isRepeatableDrawingTool ? self : .select
  }
}

/// The canvas tool cluster — the eight placement/selection tools, rendered bare so the bottom
/// command bar can lay it alongside zoom and session utilities under one shared glass surface.
struct CanvasToolbar: View {
  @Binding var tool: CanvasTool
  @Binding var continuousDrawingEnabled: Bool

  var body: some View {
    ViewThatFits(in: .horizontal) {
      fullToolbar
      compactToolbar
    }
  }

  /// Keep every direct tool affordance while the window has room for it.
  private var fullToolbar: some View {
    HStack(spacing: 5) {
      ToolButton(symbol: "cursorarrow", help: "Select  ·  move & edit cards  1".localizedUI,
                 active: tool == .select, shortcut: 1) { tool = .select }
      ToolButton(symbol: "character", help: "Text  ·  click the board, then type  2".localizedUI,
                 active: tool == .text, shortcut: 2) { tool = .text }
      ToolButton(symbol: "rectangle", help: "Rectangle  ·  drag to draw  3".localizedUI,
                 active: tool == .rectangle, shortcut: 3) { tool = .rectangle }
      ToolButton(symbol: "circle", help: "Ellipse  ·  drag to draw  4".localizedUI,
                 active: tool == .ellipse, shortcut: 4) { tool = .ellipse }
      ToolButton(symbol: "diamond", help: "Diamond  ·  drag to draw  5".localizedUI,
                 active: tool == .diamond, shortcut: 5) { tool = .diamond }
      ToolButton(symbol: "line.diagonal", help: "Line  ·  drag to draw  6".localizedUI,
                 active: tool == .line, shortcut: 6) { tool = .line }
      ToolButton(symbol: "arrow.up.right", help: "Arrow  ·  drag to draw  7".localizedUI,
                 active: tool == .arrow, shortcut: 7) { tool = .arrow }
      ToolButton(symbol: "scribble.variable", help: "Freehand stroke  ·  drag to draw  8".localizedUI,
                 active: tool == .freehand, shortcut: 8) { tool = .freehand }
      ToolButton(symbol: "pencil.tip", help: "Pen  ·  click corners, drag curves, Return commits  P".localizedUI,
                 active: tool == .vectorPen) { tool = .vectorPen }
      ToolButton(symbol: "x.squareroot", help: "Equation  ·  click the board, then type LaTeX  9".localizedUI,
                 active: tool == .equation, shortcut: 9) { tool = .equation }
      Menu {
        Button("Sticky note".localizedUI) { tool = .sticky }
        Button("Checklist".localizedUI) { tool = .checklist }
        Button("Table".localizedUI) { tool = .table }
      } label: {
        Image(systemName: "plus.square.on.square")
          .font(WindowChrome.iconFont)
          .foregroundStyle([.sticky, .checklist, .table].contains(tool) ? Theme.Palette.accent : Theme.Palette.chromeGlyph)
          .frame(width: ToolMetrics.side, height: ToolMetrics.side)
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .help("More canvas elements".localizedUI)

      persistenceControl
    }
  }

  /// At the window's 640pt minimum the complete command bar cannot fit eleven fixed-width tool
  /// buttons. Preserve the primary Select/Text actions and group related placement tools into
  /// discoverable menus; keyboard shortcuts continue to select every tool directly.
  private var compactToolbar: some View {
    HStack(spacing: 5) {
      ToolButton(symbol: "cursorarrow", help: "Select  ·  move & edit cards  1".localizedUI,
                 active: tool == .select, shortcut: 1) { tool = .select }
      ToolButton(symbol: "character", help: "Text  ·  click the board, then type  2".localizedUI,
                 active: tool == .text, shortcut: 2) { tool = .text }
      toolMenu(
        symbol: "square.on.circle",
        help: "Rectangle  ·  drag to draw  3".localizedUI,
        active: [.rectangle, .ellipse, .diamond].contains(tool)
      ) {
        Button("Rectangle  ·  drag to draw  3".localizedUI) { tool = .rectangle }
        Button("Ellipse  ·  drag to draw  4".localizedUI) { tool = .ellipse }
        Button("Diamond  ·  drag to draw  5".localizedUI) { tool = .diamond }
      }
      toolMenu(
        symbol: "arrow.up.right",
        help: "Connectors".localizedUI,
        active: [.line, .arrow].contains(tool)
      ) {
        Button("Line  ·  drag to draw  6".localizedUI) { tool = .line }
        Button("Arrow  ·  drag to draw  7".localizedUI) { tool = .arrow }
      }
      toolMenu(
        symbol: "pencil.and.scribble",
        help: "Drawing".localizedUI,
        active: [.freehand, .vectorPen].contains(tool)
      ) {
        Button("Freehand stroke  ·  drag to draw  8".localizedUI) { tool = .freehand }
        Button("Pen  ·  click corners, drag curves, Return commits  P".localizedUI) { tool = .vectorPen }
      }
      ToolButton(symbol: "x.squareroot", help: "Equation  ·  click the board, then type LaTeX  9".localizedUI,
                 active: tool == .equation, shortcut: 9) { tool = .equation }
      toolMenu(
        symbol: "plus.square.on.square",
        help: "More canvas elements".localizedUI,
        active: [.sticky, .checklist, .table].contains(tool)
      ) {
        Button("Sticky note".localizedUI) { tool = .sticky }
        Button("Checklist".localizedUI) { tool = .checklist }
        Button("Table".localizedUI) { tool = .table }
      }

      persistenceControl
    }
  }

  private func toolMenu<Content: View>(
    symbol: String,
    help: String,
    active: Bool,
    @ViewBuilder content: () -> Content
  ) -> some View {
    Menu(content: content) {
      Image(systemName: symbol)
        .font(WindowChrome.iconFont)
        .foregroundStyle(active ? Theme.Palette.accent : Theme.Palette.chromeGlyph)
        .frame(width: ToolMetrics.side, height: ToolMetrics.side)
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .help(help)
  }

  @ViewBuilder
  private var persistenceControl: some View {
    if tool.isRepeatableDrawingTool {
      Button {
        continuousDrawingEnabled.toggle()
        Haptics.level()
      } label: {
        Image(systemName: continuousDrawingEnabled ? "pin.fill" : "pin.slash")
          .font(WindowChrome.iconFont)
          .foregroundStyle(continuousDrawingEnabled ? Theme.Palette.accent : Theme.Palette.chromeGlyph)
          .frame(width: ToolMetrics.side, height: ToolMetrics.side)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help((continuousDrawingEnabled
             ? "Drawing tool stays active · click to use once"
             : "Drawing tool is one-shot · click to keep active").localizedUI)
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
  /// The bare number key that activates this tool (⌘-number also works), shown as a small corner badge.
  var shortcut: Int? = nil
  var action: () -> Void
  @State private var hovering = false

  var body: some View {
    Button(action: action) {
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
      // No blue fill for the active state — the accent-tinted glyph is the signal. No hover
      // background either: the trackpad tick plus glyph brightening carry hover.
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
    .onHover { over in
      hovering = over
      if over, !disabled, !busy { Haptics.hover() }
    }
    .help(help.localizedUI)
    .animation(.easeOut(duration: 0.12), value: hovering)
  }

  private var foreground: AnyShapeStyle {
    if disabled { return AnyShapeStyle(Theme.Palette.chromeGlyphDim) }
    if active { return AnyShapeStyle(Theme.Palette.accent) }
    return AnyShapeStyle(hovering ? Theme.Palette.chromeGlyphHover : Theme.Palette.chromeGlyph)
  }
}
