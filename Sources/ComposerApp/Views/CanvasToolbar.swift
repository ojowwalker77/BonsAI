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
}

/// The floating top tool cluster — the canvas's analog of the left `Sidebar`, using the same
/// `railSurface()` recipe so it reads as a sibling rail floating above the card. Holds the
/// canvas tools + zoom + the board-level Compile and Copy.
struct CanvasToolbar: View {
  @Binding var tool: CanvasTool
  let zoomPercent: Int
  var canCompile: Bool
  var isCompiling: Bool
  var canCopy: Bool
  var onZoomOut: () -> Void
  var onZoomIn: () -> Void
  var onZoomReset: () -> Void
  var onFit: () -> Void
  var onCompile: () -> Void
  var onCopy: () -> Void

  var body: some View {
    HStack(spacing: 5) {
      ToolButton(symbol: "cursorarrow", help: "Select  ·  move & edit cards",
                 active: tool == .select) { tool = .select }
      ToolButton(symbol: "character", help: "Text  ·  click the board, then type",
                 active: tool == .text) { tool = .text }
      ToolButton(symbol: "rectangle", help: "Rectangle  ·  click the board to place",
                 active: tool == .rectangle) { tool = .rectangle }
      ToolButton(symbol: "circle", help: "Ellipse  ·  click the board to place",
                 active: tool == .ellipse) { tool = .ellipse }
      ToolButton(symbol: "diamond", help: "Diamond  ·  click the board to place",
                 active: tool == .diamond) { tool = .diamond }
      ToolButton(symbol: "line.diagonal", help: "Line  ·  click the board to place",
                 active: tool == .line) { tool = .line }
      ToolButton(symbol: "arrow.up.right", help: "Arrow  ·  click the board to place",
                 active: tool == .arrow) { tool = .arrow }
      ToolButton(symbol: "scribble.variable", help: "Freehand stroke  ·  click the board to place",
                 active: tool == .freehand) { tool = .freehand }

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

      if isCompiling {
        ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 32, height: 30)
      } else {
        ToolButton(symbol: "wand.and.rays", help: "Compile to draft  ⌘R",
                   disabled: !canCompile, action: onCompile)
      }
      ToolButton(symbol: "doc.on.doc", help: "Copy self-contained  ⇧⌘C",
                 disabled: !canCopy, action: onCopy)
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
