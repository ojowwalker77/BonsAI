import SwiftUI

/// The board tool. `select` moves/edits existing elements; the others drop a new element where
/// you click.
enum CanvasTool: CaseIterable, Hashable, Sendable {
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

struct CanvasToolDescriptor: Identifiable, Hashable, Sendable {
  let tool: CanvasTool
  let symbol: String
  /// Localization key for the tool's name and gesture hint, WITHOUT its shortcut — the shortcut is
  /// appended from `digit`/`letters`, so remapping a key never touches the strings files.
  let helpKey: String
  /// Bare digit that picks the tool (⌘-digit works too); shown as the button's corner badge.
  let shortcut: Int?
  /// Bare letters that pick the tool, Excalidraw-style (matched case-insensitively).
  var letters: [String] = []

  var id: CanvasTool { tool }

  var shortcutLabel: String? {
    let keys = letters + (shortcut.map { [String($0)] } ?? [])
    return keys.isEmpty ? nil : keys.joined(separator: " / ")
  }

  var localizedHelp: String {
    guard let shortcutLabel else { return helpKey.localizedUI }
    return "\(helpKey.localizedUI)  \(shortcutLabel)"
  }
}

struct CanvasToolGroupDescriptor: Equatable, Sendable {
  let symbol: String
  let helpKey: String
  let tools: [CanvasToolDescriptor]
}

/// One catalog drives the toolbar, its badges and tooltips, and the keyboard, so a tool's glyph,
/// help text, and shortcut cannot drift. Shortcuts follow Excalidraw exactly: 1/V select,
/// 2/R rectangle, 3/D diamond, 4/O ellipse, 5/A arrow, 6/L line, 7/P/X draw, 8/T text — plus
/// 9 for equations, B for the pen, and Q to keep the drawing tool active.
enum CanvasToolbarCatalog {
  static let select = CanvasToolDescriptor(
    tool: .select, symbol: "cursorarrow", helpKey: "Select  ·  move & edit cards", shortcut: 1,
    letters: ["V"])
  static let rectangle = CanvasToolDescriptor(
    tool: .rectangle, symbol: "rectangle", helpKey: "Rectangle  ·  drag to draw", shortcut: 2,
    letters: ["R"])
  static let diamond = CanvasToolDescriptor(
    tool: .diamond, symbol: "diamond", helpKey: "Diamond  ·  drag to draw", shortcut: 3,
    letters: ["D"])
  static let ellipse = CanvasToolDescriptor(
    tool: .ellipse, symbol: "circle", helpKey: "Ellipse  ·  drag to draw", shortcut: 4,
    letters: ["O"])
  static let arrow = CanvasToolDescriptor(
    tool: .arrow, symbol: "arrow.up.right", helpKey: "Arrow  ·  drag to draw", shortcut: 5,
    letters: ["A"])
  static let line = CanvasToolDescriptor(
    tool: .line, symbol: "line.diagonal", helpKey: "Line  ·  drag to draw", shortcut: 6,
    letters: ["L"])
  static let freehand = CanvasToolDescriptor(
    tool: .freehand, symbol: "scribble.variable", helpKey: "Freehand stroke  ·  drag to draw",
    shortcut: 7, letters: ["P", "X"])
  static let text = CanvasToolDescriptor(
    tool: .text, symbol: "character", helpKey: "Text  ·  click the board, then type", shortcut: 8,
    letters: ["T"])
  static let equation = CanvasToolDescriptor(
    tool: .equation, symbol: "x.squareroot",
    helpKey: "Equation  ·  click the board, then type LaTeX", shortcut: 9)
  static let vectorPen = CanvasToolDescriptor(
    tool: .vectorPen, symbol: "pencil.tip",
    helpKey: "Pen  ·  click corners, drag curves, Return commits", shortcut: nil, letters: ["B"])
  static let sticky = CanvasToolDescriptor(
    tool: .sticky, symbol: "note", helpKey: "Sticky note", shortcut: nil)
  static let checklist = CanvasToolDescriptor(
    tool: .checklist, symbol: "checklist", helpKey: "Checklist", shortcut: nil)
  static let table = CanvasToolDescriptor(
    tool: .table, symbol: "tablecells", helpKey: "Table", shortcut: nil)

  /// Toolbar order matches Excalidraw's (and the digit badges), with the pen beside freehand.
  static let fullTools = [
    select, rectangle, diamond, ellipse, arrow, line, freehand, vectorPen, text, equation,
  ]
  static let all = fullTools + [sticky, checklist, table]
  static let shapeGroup = CanvasToolGroupDescriptor(
    symbol: "square.on.circle", helpKey: rectangle.helpKey,
    tools: [rectangle, diamond, ellipse])
  static let connectorGroup = CanvasToolGroupDescriptor(
    symbol: "arrow.up.right", helpKey: "Connectors", tools: [arrow, line])
  static let drawingGroup = CanvasToolGroupDescriptor(
    symbol: "pencil.and.scribble", helpKey: "Drawing", tools: [freehand, vectorPen])
  static let moreGroup = CanvasToolGroupDescriptor(
    symbol: "plus.square.on.square", helpKey: "More canvas elements",
    tools: [sticky, checklist, table])

  /// The tool a bare (or ⌘-) digit selects.
  static func tool(forDigit digit: Int) -> CanvasTool? {
    all.first { $0.shortcut == digit }?.tool
  }

  /// The tool a bare letter selects (case-insensitive).
  static func tool(forLetter letter: String) -> CanvasTool? {
    let key = letter.uppercased()
    return all.first { $0.letters.contains(key) }?.tool
  }

  /// Excalidraw's "keep selected tool active after drawing" toggle.
  static let toolLockLetter = "Q"
}

enum CanvasToolbarLayoutPolicy {
  /// `ViewThatFits` must compare fixed footprints. The slot remains present even when its action is
  /// unavailable, preventing Select/Text from choosing a different variant at the same width.
  static let persistenceSlotCount = 1

  static func showsPersistenceAction(for tool: CanvasTool) -> Bool {
    tool.isRepeatableDrawingTool
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
    HStack(spacing: WindowChrome.itemSpacing) {
      ForEach(CanvasToolbarCatalog.fullTools) { descriptor in
        toolButton(descriptor)
      }
      toolMenu(CanvasToolbarCatalog.moreGroup)
      persistenceControl
    }
  }

  /// At the window's 640pt minimum the complete command bar cannot fit eleven fixed-width tool
  /// buttons. Preserve the primary Select/Text actions and group related placement tools into
  /// discoverable menus; keyboard shortcuts continue to select every tool directly.
  private var compactToolbar: some View {
    HStack(spacing: WindowChrome.itemSpacing) {
      toolButton(CanvasToolbarCatalog.select)
      toolMenu(CanvasToolbarCatalog.shapeGroup)
      toolMenu(CanvasToolbarCatalog.connectorGroup)
      toolMenu(CanvasToolbarCatalog.drawingGroup)
      toolButton(CanvasToolbarCatalog.text)
      toolButton(CanvasToolbarCatalog.equation)
      toolMenu(CanvasToolbarCatalog.moreGroup)
      persistenceControl
    }
  }

  private func toolButton(_ descriptor: CanvasToolDescriptor) -> some View {
    ToolButton(
      symbol: descriptor.symbol,
      help: descriptor.localizedHelp,
      active: tool == descriptor.tool,
      shortcut: descriptor.shortcut
    ) {
      tool = descriptor.tool
    }
  }

  private func toolMenu(_ group: CanvasToolGroupDescriptor) -> some View {
    Menu {
      ForEach(group.tools) { descriptor in
        Button(descriptor.localizedHelp) { tool = descriptor.tool }
      }
    } label: {
      Image(systemName: group.symbol)
        .font(WindowChrome.iconFont)
        .foregroundStyle(
          group.tools.contains(where: { $0.tool == tool })
            ? Theme.Palette.accent : Theme.Palette.chromeGlyph)
        .frame(width: ToolMetrics.side, height: ToolMetrics.side)
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    // A borderless-button Menu is an NSPopUpButton underneath and greedily fills the width it is
    // offered — it stretched the bottom bar edge to edge and let `ViewThatFits` accept the full
    // toolbar at any width. Pin it to the same square as every other tool button.
    .fixedSize()
    .frame(width: ToolMetrics.side, height: ToolMetrics.side)
    .help(group.helpKey.localizedUI)
  }

  private var persistenceControl: some View {
    let showsAction = CanvasToolbarLayoutPolicy.showsPersistenceAction(for: tool)
    return ZStack {
      if showsAction {
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
               : "Drawing tool is one-shot · click to keep active").localizedUI
              + "  \(CanvasToolbarCatalog.toolLockLetter)")
      }
    }
    .frame(width: ToolMetrics.side, height: ToolMetrics.side)
    .allowsHitTesting(showsAction)
    .accessibilityHidden(!showsAction)
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
