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
}

/// The floating top tool cluster — the canvas's analog of the left `Sidebar`, using the same
/// `railSurface()` recipe so it reads as a sibling rail floating above the card. Holds the
/// canvas tools + zoom + the board-level Compile and Copy.
struct CanvasToolbar: View {
  @Binding var tool: CanvasTool
  let zoomPercent: Int
  var agentOpen: Bool
  var onAgent: () -> Void
  var onZoomOut: () -> Void
  var onZoomIn: () -> Void
  var onZoomReset: () -> Void
  var onFit: () -> Void

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

      divider

      ToolButton(symbol: "minus.magnifyingglass", help: "Zoom out", action: onZoomOut)
      Button(action: onZoomReset) {
        Text("\(zoomPercent)%")
          .font(.caption.monospacedDigit().weight(.medium))
          .foregroundStyle(Color.white.opacity(0.82))
          .frame(width: 44, height: 30)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help("Reset to 100%")
      ToolButton(symbol: "plus.magnifyingglass", help: "Zoom in", action: onZoomIn)
      ToolButton(symbol: "arrow.up.left.and.down.right.magnifyingglass", help: "Fit board", action: onFit)

      divider

      AgentToolButton(active: agentOpen, action: onAgent)
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 5)
    .railSurface()
  }

  private var divider: some View {
    Rectangle().fill(Color.white.opacity(0.12)).frame(width: 1, height: 18).padding(.horizontal, 2)
  }
}

private struct ToolButton: View {
  let symbol: String
  let help: String
  var active = false
  var disabled = false
  /// The ⌘-number that activates this tool, shown as a small corner badge.
  var shortcut: Int? = nil
  var action: () -> Void
  @State private var hovering = false

  var body: some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: 15, weight: .medium))
        .foregroundStyle(foreground)
        .frame(width: 32, height: 30)
        .background(
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(active ? Color.accentColor.opacity(0.22)
                  : (hovering && !disabled ? Color.white.opacity(0.12) : Color.clear))
        )
        .overlay(alignment: .bottomTrailing) {
          if let shortcut {
            Text("\(shortcut)")
              .font(.system(size: 8, weight: .bold))
              .foregroundStyle(active ? Color.accentColor : Color.white.opacity(hovering ? 0.6 : 0.34))
              .padding(.trailing, 3).padding(.bottom, 2)
          }
        }
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(disabled)
    .onHover { hovering = $0 }
    .help(help)
    .animation(.easeOut(duration: 0.12), value: hovering)
  }

  private var foreground: AnyShapeStyle {
    if disabled { return AnyShapeStyle(Color.white.opacity(0.26)) }
    if active { return AnyShapeStyle(Color.accentColor) }
    return AnyShapeStyle(Color.white.opacity(hovering ? 0.95 : 0.62))
  }
}

/// The agent toggle — shows the active engine's brand mark instead of a generic glyph.
private struct AgentToolButton: View {
  var active: Bool
  var action: () -> Void
  @State private var hovering = false

  var body: some View {
    Button(action: action) {
      AgentEngineIcon(size: 16)
        .frame(width: 32, height: 30)
        .opacity(active ? 1 : (hovering ? 0.95 : 0.78))
        .background(
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(active ? Color.accentColor.opacity(0.22) : (hovering ? Color.white.opacity(0.12) : Color.clear))
        )
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
    .help("Chat with the agent on this board  ⌘J")
    .animation(.easeOut(duration: 0.12), value: hovering)
  }
}
