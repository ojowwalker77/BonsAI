import AppKit
import SwiftUI

/// The one editing surface for every card kind. Presented by `ComposerCanvas` whenever
/// `board.editingCardID` is non-nil, it recedes the board behind a scrim and elevates a centered
/// glass panel — the shape the Focus Write sheet had always used — so text, equation, graph, and
/// shape/line editing all enter, sit, and exit identically. Per-kind draft state (equation LaTeX,
/// graph spec) lives here, seeded from the card on appear and committed through the board's own
/// mutations (each already registers exactly one undo step).
///
/// `editingCardID` stays the single source of truth: nothing here invents new global edit state.
/// The card behind the scrim renders statically while its stage is open — the live editor mounts
/// only in the stage, handed over via the same `captureEditorState()` the focus sheet always used.
struct EditingStage: View {
  @ObservedObject var board: BoardViewModel
  let card: CardState
  @ObservedObject var interaction: CardInteraction
  let size: CGSize
  let isWorking: Bool
  /// The engine the linter's "Refine with …" escalation targets on the text stage; nil hides it.
  let askEngine: HeadlessEngine?
  /// Axes→graph promotion: open the label stage straight in graph-config mode on appear (as if
  /// "Make graph" were tapped). One-shot — `onGraphConfigConsumed` clears the pending intent so a
  /// later manual reopen of the same card lands on the label, not the config.
  var openGraphConfigOnAppear: Bool = false
  var onGraphConfigConsumed: () -> Void = {}
  /// Commit-close the stage the way a click-away ends editing (text/label/equation commit, graph
  /// closes without applying). Wired to the scrim tap and the header close button.
  let onClose: () -> Void

  /// Equation edit is a local draft (raw LaTeX, no `$` delimiters), seeded from the card and
  /// committed on Return / scrim-tap. Esc reverts it; a blank commit prunes the card.
  @State private var equationDraft = ""
  @FocusState private var equationFocused: Bool

  /// Graph config editing: a local draft spec seeded on open. `graphConverting` is set while a
  /// line/arrow is being folded into a graph (the confirm reads "Make Graph" and commits via
  /// `convertElementToGraph`); false means editing an existing graph card ("Apply" → `setGraphSpec`).
  @State private var graphDraft = GraphDraft()
  @State private var graphConverting = false
  /// True while the label stage has swapped its content to the graph config (line/arrow "Make graph"
  /// tapped). Esc here falls BACK to the label content — the same session — mirroring the old
  /// in-card `cancelGraphConfig` fallback.
  @State private var showingGraphConfig = false

  /// Labels edit through a local draft (not `interaction.text` live) so Esc can revert — the house
  /// rule: Esc cancels the draft, exactly as the old in-card label chip did.
  @State private var labelDraft = ""
  @FocusState private var labelFocused: Bool

  private var tint: Color? { Theme.tintColor(card.tint).map { Color(nsColor: $0) } }
  private var canMakeGraph: Bool { card.elementKind == .line || card.elementKind == .arrow }

  var body: some View {
    ZStack {
      // The board recedes; a click on it commit-closes the stage (the focus/click-away contract).
      Theme.Palette.windowCanvas.opacity(0.72)
        .contentShape(Rectangle())
        .onTapGesture { scrimTap() }

      stagePanel
        .dockPanelSurface()
        .shadow(color: Theme.Shadow.panel.color, radius: Theme.Shadow.panel.radius, y: Theme.Shadow.panel.y)
    }
    .zIndex(70)
    .transition(.opacity)
    .onAppear(perform: seedDraft)
  }

  // MARK: Header

  /// The shared header: the kind's name on the left, a "back to board" button on the right that
  /// behaves like a scrim tap (commit-close, or fall back to the label while converting).
  private func header(_ title: String) -> some View {
    HStack {
      Text(title)
        .font(WindowChrome.labelFont)
        .foregroundStyle(Theme.Palette.menuDesc)
      Spacer(minLength: 8)
      SidebarButton(symbol: "arrow.down.right.and.arrow.up.left",
                    help: "Back to board  ·  Esc".localizedUI, side: 26) { scrimTap() }
    }
    .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 6)
  }

  // MARK: Panel routing

  @ViewBuilder
  private var stagePanel: some View {
    switch card.elementKind {
    case .text:
      textStage
    case .equation:
      equationStage
    case .graph:
      graphStage
    case .line, .arrow, .rectangle, .ellipse, .diamond:
      labelStage
    case .freehand, .image:
      // These kinds have no edit session; the canvas guards against opening a stage for them, so
      // this branch is unreachable. Render nothing rather than an empty glass panel.
      EmptyView()
    }
  }

  // MARK: Text stage (the old Focus Write sheet, verbatim)

  private var textStage: some View {
    VStack(spacing: 0) {
      header("Write".localizedUI)
      FreeWriteEditor(
        text: Binding(get: { interaction.text }, set: { interaction.text = $0 }),
        initialAttributedText: interaction.attributedSnapshot,
        placeholder: "Brain dump...".localizedUI,
        onCountChange: { interaction.count = $0 },
        onSelectionChange: { interaction.selection = $0 },
        onEscape: { onClose() },
        onFocusChange: { _ in },
        onHeightChange: { _ in },
        boardContext: { board.lintContext(excluding: card.id) },
        definedVariables: { board.definedVariableNames },
        mentions: interaction.mentions,
        appSearch: interaction.appSearch,
        controller: interaction.controller,
        lint: interaction.lint,
        refine: interaction.refine,
        store: DumpStore.shared
      )
      .padding(.horizontal, 28)
      .padding(.bottom, 22)
    }
    .frame(width: min(720, size.width * 0.72), height: min(640, size.height * 0.82))
    .onAppear {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { interaction.controller.focus() }
    }
  }

  // MARK: Equation stage

  /// A large live SwiftMath preview of the draft over the LaTeX field. The preview updates per
  /// keystroke — it doubles as parse feedback (the raw-source fallback shows when the draft won't
  /// parse). Return / scrim-tap commits; Esc reverts to the committed LaTeX and prunes a blank card.
  private var equationStage: some View {
    VStack(spacing: 0) {
      header("Equation".localizedUI)
      VStack(spacing: 14) {
        EquationView(latex: equationDraft, tint: tint, zoom: 1)
          .frame(minHeight: 120)
          .frame(maxWidth: .infinity)
          .allowsHitTesting(false)
        TextField("\\frac{\\hbar^2}{2m} \u{2026}", text: $equationDraft)
          .textFieldStyle(.plain)
          .font(.system(size: 12.5, design: .monospaced))
          .foregroundStyle(Theme.Palette.body)
          .padding(.horizontal, 10)
          .padding(.vertical, 7)
          .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Theme.Palette.segmentedFill))
          .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(Theme.Palette.panelHairline, lineWidth: 1))
          .focused($equationFocused)
          .onSubmit(commitEquation)
          .onExitCommand(perform: revertEquation)
      }
      .padding(.horizontal, 20)
      .padding(.bottom, 18)
    }
    .frame(width: 460)
    .onAppear {
      DispatchQueue.main.async { equationFocused = true }
    }
  }

  private func commitEquation() {
    board.setText(card.id, equationDraft.trimmingCharacters(in: .whitespacesAndNewlines))
    board.endEditing(card.id)
  }

  /// House rule: Esc drops what was typed, ends editing, and prunes the card if it never held any
  /// committed LaTeX (a blank equation shows nothing, unlike a blank text write-spot).
  private func revertEquation() {
    equationDraft = card.latex ?? ""
    board.endEditing(card.id)
    board.pruneBlankEquation(card.id)
  }

  // MARK: Graph stage

  /// A live `GraphCardView` rendering the DRAFT spec (edits preview immediately) over the config
  /// fields. "Apply" commits via `setGraphSpec`; Esc closes without applying.
  private var graphStage: some View {
    VStack(spacing: 0) {
      header("Graph".localizedUI)
      graphEditorBody(converting: false, onCommit: {
        board.setGraphSpec(card.id, graphDraft.spec())
        board.endEditing(card.id)
      }, onCancel: { board.endEditing(card.id) })
    }
    .frame(width: 560)
  }

  /// Shared graph body — a live preview of the draft over the config strip. Used by the graph stage
  /// and by the label stage's "Make Graph" content swap (which commits via `convertElementToGraph`).
  private func graphEditorBody(converting: Bool,
                               onCommit: @escaping () -> Void,
                               onCancel: @escaping () -> Void) -> some View {
    VStack(spacing: 14) {
      GraphCardView(spec: graphDraft.spec(), tint: tint)
        .frame(width: 420, height: 260)
        .allowsHitTesting(false)
      GraphConfigStrip(
        draft: $graphDraft,
        converting: converting,
        width: 520,
        onCommit: onCommit,
        onCancel: onCancel)
    }
    .padding(.horizontal, 20)
    .padding(.bottom, 18)
  }

  // MARK: Label stage (shapes + lines/arrows, with line→graph conversion)

  /// A compact label editor. For lines/arrows it also offers "Make graph", which swaps the stage
  /// content to the graph config (same session); Esc while converting falls back to the label.
  private var labelStage: some View {
    Group {
      if showingGraphConfig {
        VStack(spacing: 0) {
          header("Graph".localizedUI)
          graphEditorBody(converting: true, onCommit: {
            board.convertElementToGraph(card.id, spec: graphDraft.spec())
            board.endEditing(card.id)
          }, onCancel: {
            // Esc while converting drops the config and returns to the label — same session.
            showingGraphConfig = false
          })
        }
        .frame(width: 560)
      } else {
        VStack(spacing: 0) {
          header("Label".localizedUI)
          HStack(spacing: 8) {
            TextField("Label".localizedUI, text: $labelDraft)
              .textFieldStyle(.plain)
              .font(ComposerPreferences.appSwiftUIFont(size: 15, weight: .medium))
              .foregroundStyle(tint ?? Theme.Palette.body)
              .multilineTextAlignment(.center)
              .focused($labelFocused)
              .onSubmit(commitLabel)
              .onExitCommand(perform: revertLabel)
              .padding(.horizontal, 10)
              .frame(height: 34)
              .frame(maxWidth: .infinity)
              .background(labelFieldSurface)
            if canMakeGraph {
              Button(action: openGraphConfig) {
                Image(systemName: "chart.xyaxis.line")
                  .font(.system(size: 14, weight: .medium))
                  .foregroundStyle(Theme.Palette.accent)
                  .frame(width: 34, height: 34)
                  .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
              }
              .buttonStyle(.plain)
              .background(labelFieldSurface)
              .onHover { if $0 { Haptics.hover() } }
              .help("Make graph".localizedUI)
            }
          }
          .padding(.horizontal, 20)
          .padding(.bottom, 18)
        }
        .frame(width: 420)
        .onAppear { DispatchQueue.main.async { labelFocused = true } }
      }
    }
  }

  private var labelFieldSurface: some View {
    RoundedRectangle(cornerRadius: 8, style: .continuous)
      .fill(Theme.Palette.labelChipFill)
      .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
        .strokeBorder(Theme.Palette.panelHairline, lineWidth: 1))
  }

  private func commitLabel() {
    interaction.text = labelDraft
    board.endEditing(card.id)
  }

  /// Esc drops the draft and ends the session with the committed label untouched.
  private func revertLabel() {
    labelDraft = interaction.text
    board.endEditing(card.id)
  }

  /// "Make graph" tapped inside a line/arrow's label: same editing session, just swap the label
  /// content for the graph config, prefilling axis labels from this arrow (and its perpendicular
  /// partner).
  private func openGraphConfig() {
    graphDraft = seededGraphDraft()
    graphConverting = true
    showingGraphConfig = true
  }

  // MARK: Seeding

  private func seedDraft() {
    switch card.elementKind {
    case .equation:
      // Seed from the committed source so reopening shows its LaTeX and a fresh card starts empty.
      equationDraft = card.latex ?? ""
    case .graph:
      graphDraft = GraphDraft(spec: card.graph ?? CardState.GraphSpec())
      graphConverting = false
      showingGraphConfig = false
    case .line, .arrow, .rectangle, .ellipse, .diamond:
      labelDraft = interaction.text
      // Axes→graph promotion: open straight in graph-config, as if "Make graph" were tapped. Esc
      // still falls back to the label (same session), matching the manual conversion path.
      if openGraphConfigOnAppear, canMakeGraph {
        graphDraft = seededGraphDraft()
        graphConverting = true
        showingGraphConfig = true
      }
      onGraphConfigConsumed()
    default:
      break
    }
  }

  /// Seed a fresh draft when converting a line/arrow: the more-horizontal-than-vertical arrow lends
  /// its label to X, else to Y; a labeled perpendicular partner fills the other axis. Ranges default
  /// 0–10, grid on. (Mirrors the old in-card `seededGraphDraft` exactly.)
  private func seededGraphDraft() -> GraphDraft {
    var draft = GraphDraft()
    let mine = card.text.trimmingCharacters(in: .whitespacesAndNewlines)
    let partner = board.perpendicularPartner(of: card.id)
    let partnerLabel = (partner?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let points = card.points ?? CardState.defaultLinePoints()
    let dx = abs((points.last?.x ?? 1) - (points.first?.x ?? 0))
    let dy = abs((points.last?.y ?? 0) - (points.first?.y ?? 1))
    if dx >= dy {
      draft.xLabel = mine
      draft.yLabel = partnerLabel
    } else {
      draft.yLabel = mine
      draft.xLabel = partnerLabel
    }
    return draft
  }

  // MARK: Close semantics

  /// Scrim tap / header close: commit-close for text/label/equation, close-without-apply for a graph
  /// (matches today's click-away). While the label stage shows the graph config, tapping the scrim
  /// backs out of the conversion to the label rather than committing a half-built graph.
  private func scrimTap() {
    if showingGraphConfig { showingGraphConfig = false; return }
    switch card.elementKind {
    case .equation:
      commitEquation()
    case .line, .arrow, .rectangle, .ellipse, .diamond:
      // Click-away commits the label draft (Esc is the revert path).
      commitLabel()
    default:
      onClose()
    }
  }
}

// MARK: - Graph config draft + strip (moved out of BoardCardView, commit semantics unchanged)

/// The graph config's editable state — labels/units as free text, ranges as raw field text (so a
/// mid-edit value never fights the field), resolved back to a validated `GraphSpec` on commit.
///
/// KNOWN GOTCHA (kept exact): `spec()` carries every non-point field of `series` through Apply
/// untouched — only point-series points are rebuilt from `pointRows`. Any spec field that isn't
/// carried through the draft would be wiped on commit; preserve this behavior and its tests.
struct GraphDraft {
  var xLabel = ""
  var xUnit = ""
  var yLabel = ""
  var yUnit = ""
  var xMinText = "0"
  var xMaxText = "10"
  var yMinText = "0"
  var yMaxText = "10"
  var showGrid = true
  /// Carried through untouched EXCEPT for point-series points, which `pointRows` edits and `spec()`
  /// writes back. Expression series (and their tints/labels/ids) ride through here unmodified.
  var series: [CardState.GraphSeries] = []
  /// One editable row per data point across all point-bearing series — raw field text (never fights
  /// the field), resolved back on `spec()`. Deleting a row here deletes the point on Apply.
  var pointRows: [PointRow] = []

  /// A single point's editable state, tagged with the series it belongs to so `spec()` can rebuild
  /// that series' point list. `original` supplies the fallback when a coordinate field is half-typed.
  struct PointRow: Identifiable, Equatable {
    let id = UUID()
    var seriesID: UUID
    var xText: String
    var yText: String
    var label: String
    var tint: Int?
    var original: CardState.GraphPoint
  }

  init() {}

  init(spec: CardState.GraphSpec) {
    xLabel = spec.xLabel
    xUnit = spec.xUnit
    yLabel = spec.yLabel
    yUnit = spec.yUnit
    xMinText = GraphDraft.format(spec.xMin)
    xMaxText = GraphDraft.format(spec.xMax)
    yMinText = GraphDraft.format(spec.yMin)
    yMaxText = GraphDraft.format(spec.yMax)
    showGrid = spec.showGrid
    series = spec.series
    for s in spec.series {
      for p in s.points ?? [] {
        pointRows.append(PointRow(seriesID: s.id,
                                  xText: GraphDraft.format(p.x),
                                  yText: GraphDraft.format(p.y),
                                  label: p.label, tint: p.tint, original: p))
      }
    }
  }

  /// Resolve the draft into a spec — non-numeric or max<=min ranges fall back to the defaults, so a
  /// half-typed field never commits a broken axis. Point-series points are rebuilt from `pointRows`
  /// (invalid coords fall back to the row's original values); expression series pass through untouched.
  func spec() -> CardState.GraphSpec {
    let (xMin, xMax) = GraphDraft.range(xMinText, xMaxText, fallback: (0, 10))
    let (yMin, yMax) = GraphDraft.range(yMinText, yMaxText, fallback: (0, 10))
    var resolved = CardState.GraphSpec(
      xLabel: xLabel.trimmingCharacters(in: .whitespacesAndNewlines),
      xUnit: xUnit.trimmingCharacters(in: .whitespacesAndNewlines),
      yLabel: yLabel.trimmingCharacters(in: .whitespacesAndNewlines),
      yUnit: yUnit.trimmingCharacters(in: .whitespacesAndNewlines),
      xMin: xMin, xMax: xMax, yMin: yMin, yMax: yMax, showGrid: showGrid)
    resolved.series = resolvedSeries()
    return resolved
  }

  /// Rebuild each point-bearing series' `points` from the draft rows in row order, keeping expression
  /// series and their order intact. A row whose X/Y won't parse keeps its original coordinate.
  private func resolvedSeries() -> [CardState.GraphSeries] {
    series.map { s in
      guard s.points != nil else { return s }
      var updated = s
      updated.points = pointRows
        .filter { $0.seriesID == s.id }
        .map { row in
          CardState.GraphPoint(
            x: Double(row.xText.trimmingCharacters(in: .whitespaces)) ?? row.original.x,
            y: Double(row.yText.trimmingCharacters(in: .whitespaces)) ?? row.original.y,
            label: row.label.trimmingCharacters(in: .whitespacesAndNewlines),
            tint: row.tint)
        }
      return updated
    }
  }

  private static func range(_ minText: String, _ maxText: String, fallback: (Double, Double)) -> (Double, Double) {
    guard let lo = Double(minText.trimmingCharacters(in: .whitespaces)),
          let hi = Double(maxText.trimmingCharacters(in: .whitespaces)),
          hi > lo else { return fallback }
    return (lo, hi)
  }

  private static func format(_ value: Double) -> String {
    value == value.rounded() ? String(Int(value)) : String(format: "%g", value)
  }
}

/// The graph config editing UI: two rows (X, Y) of label/unit/min/max fields, a grid toggle, and an
/// accent confirm. Return commits, Esc cancels; first field focused on open. Built on the shared
/// glass field chrome with WindowChrome-consistent metrics.
struct GraphConfigStrip: View {
  @Binding var draft: GraphDraft
  let converting: Bool
  let width: CGFloat
  var onCommit: () -> Void
  var onCancel: () -> Void

  @FocusState private var focusedFirst: Bool

  private var labelFont: Font { .system(size: 12, weight: .medium) }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      axisRow(axis: "X",
              label: $draft.xLabel, labelPlaceholder: "x label".localizedUI,
              unit: $draft.xUnit, minText: $draft.xMinText, maxText: $draft.xMaxText,
              focusFirst: true)
      axisRow(axis: "Y",
              label: $draft.yLabel, labelPlaceholder: "y label".localizedUI,
              unit: $draft.yUnit, minText: $draft.yMinText, maxText: $draft.yMaxText,
              focusFirst: false)
      pointsSection
      HStack(spacing: 8) {
        Toggle(isOn: $draft.showGrid) {
          Text("Grid".localizedUI).font(labelFont).foregroundStyle(Theme.Palette.body)
        }
        .toggleStyle(.checkbox)
        Spacer()
        Button(action: onCommit) {
          Text(converting ? "Make Graph".localizedUI : "Apply".localizedUI)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Theme.Palette.accent)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
              .fill(Theme.Palette.accentFill))
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.defaultAction)
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .frame(width: width)
    .composerPopupSurface()
    .onExitCommand(perform: onCancel)
    .onAppear { DispatchQueue.main.async { focusedFirst = true } }
  }

  @ViewBuilder
  private func axisRow(axis: String,
                       label: Binding<String>, labelPlaceholder: String,
                       unit: Binding<String>, minText: Binding<String>, maxText: Binding<String>,
                       focusFirst: Bool) -> some View {
    HStack(spacing: 6) {
      Text(axis)
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(Theme.Palette.placeholder)
        .frame(width: 12, alignment: .leading)
      field(labelPlaceholder, text: label, focusFirst: focusFirst)
        .frame(maxWidth: .infinity)
      field("unit", text: unit).frame(width: 48)
      field("0", text: minText).frame(width: 52)
      field("10", text: maxText).frame(width: 52)
    }
  }

  /// The editable list of data points, shown only when the graph carries any. Each row is a tint
  /// swatch (tap cycles slots), a label field, X/Y fields, and a ✕ delete. More than 4 rows scroll
  /// inside a fixed ~4-row height.
  private static let pointRowHeight: CGFloat = 30
  private static let pointRowSpacing: CGFloat = 5

  @ViewBuilder
  private var pointsSection: some View {
    if !draft.pointRows.isEmpty {
      VStack(alignment: .leading, spacing: 5) {
        Text("Points".localizedUI)
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(Theme.Palette.placeholder)
        let rows = VStack(spacing: Self.pointRowSpacing) {
          ForEach($draft.pointRows) { $row in
            pointRow($row)
          }
        }
        if draft.pointRows.count > 4 {
          // Fixed 4-row viewport (4 rows + 3 gaps); the rest scrolls.
          ScrollView {
            rows.padding(.trailing, 2)
          }
          .frame(height: Self.pointRowHeight * 4 + Self.pointRowSpacing * 3)
        } else {
          rows
        }
      }
    }
  }

  @ViewBuilder
  private func pointRow(_ row: Binding<GraphDraft.PointRow>) -> some View {
    HStack(spacing: 6) {
      // Tap the swatch to cycle: series default → each tint slot → back to default.
      Button(action: { cycleTint(row) }) {
        pointSwatch(row.wrappedValue.tint)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help(row.wrappedValue.tint == nil ? "Series default".localizedUI : "Theme color %d".localizedUI((row.wrappedValue.tint ?? 0) + 1))
      field("label", text: row.label).frame(width: 60)
      field("0", text: row.xText).frame(width: 52)
      field("0", text: row.yText).frame(width: 52)
      Spacer(minLength: 0)
      Button(action: { draft.pointRows.removeAll { $0.id == row.wrappedValue.id } }) {
        Image(systemName: "xmark")
          .font(.system(size: 9, weight: .bold))
          .foregroundStyle(Theme.Palette.placeholder)
          .frame(width: 16, height: 16)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help("Delete point".localizedUI)
    }
    .frame(height: Self.pointRowHeight)
  }

  private func pointSwatch(_ slot: Int?) -> some View {
    let fill = Theme.tintColor(slot).map { Color(nsColor: $0) }
    return Circle()
      .fill(fill ?? Color.clear)
      .frame(width: 14, height: 14)
      .overlay(Circle().strokeBorder(fill == nil ? Theme.Palette.placeholder : Theme.Palette.panelHairline, lineWidth: 1))
  }

  /// Cycle a row's tint: nil → 0 → 1 → … → last slot → nil.
  private func cycleTint(_ row: Binding<GraphDraft.PointRow>) {
    let count = Theme.flavor.tints.count
    guard count > 0 else { return }
    switch row.wrappedValue.tint {
    case nil: row.wrappedValue.tint = 0
    case let slot? where slot + 1 < count: row.wrappedValue.tint = slot + 1
    default: row.wrappedValue.tint = nil
    }
  }

  @ViewBuilder
  private func field(_ placeholder: String, text: Binding<String>, focusFirst: Bool = false) -> some View {
    let base = TextField(placeholder, text: text)
      .textFieldStyle(.plain)
      .font(.system(size: 12))
      .foregroundStyle(Theme.Palette.body)
      .padding(.horizontal, 8)
      .padding(.vertical, 5)
      .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
        .fill(Theme.Palette.segmentedFill))
      .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
        .strokeBorder(Theme.Palette.panelHairline, lineWidth: 1))
      .onSubmit(onCommit)
    if focusFirst {
      base.focused($focusedFirst)
    } else {
      base
    }
  }
}
