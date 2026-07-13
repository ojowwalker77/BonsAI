import AppKit
import ImageIO
import SwiftMath
import SwiftUI

/// One text card on the board, with Excalidraw-style interaction:
/// • single click selects (ring + corner resize handles), • drag the body moves it,
/// • double-click edits the text, • corner handles resize,
/// • ✕ deletes. The body is the unmodified `FreeWriteEditor`; it only receives mouse events
/// while editing, so a drag on a non-editing card moves it instead of selecting text.
struct BoardCardView: View {
  let card: CardState
  @ObservedObject var interaction: CardInteraction
  let isSelected: Bool
  let isEditing: Bool
  /// Board zoom — gesture translations are divided by it so moves/resizes track the cursor.
  let scale: CGFloat
  let board: BoardViewModel
  /// True only in the select tool. When false (any drawing tool) the card is pointer-transparent,
  /// so a drag starting over it falls through to the canvas and draws a new element instead of
  /// grabbing this card — selection/move/resize belong to the select tool alone.
  let selectable: Bool

  @State private var moveDelta: CGSize = .zero
  @GestureState private var resize: ResizeSession?
  /// Text-only side resize: changes the wrapping width while preserving font scale. Corner resize
  /// remains proportional type scaling; the two gestures intentionally solve different jobs.
  @GestureState private var textWidthResize: TextWidthResizeSession?
  @State private var hovering = false
  /// The ⌥-click Point Composer: prefilled X/Y (from the click's data coords), a label, and a tint
  /// swatch. Non-nil while the strip is up.
  @State private var pointComposer: PointComposerDraft?
  /// True when a plain (unmodified) press armed this card for a same-gesture move: one press then
  /// drag both selects (if needed) and moves the card, no separate "click to select, click again to
  /// move" step. A modified press (shift/command toggles selection) leaves this false so the drag
  /// doesn't move the card.
  @State private var armedForMove = false
  /// ⌥ was down on the arming press; the duplicate itself waits for the drag to leave the 4px
  /// dead-zone so a bare ⌥-click never spawns copies.
  @State private var duplicateDragArmed = false
  @State private var duplicateDragStarted = false
  /// The graph marker currently being dragged (series id + point index), armed on a plain press that
  /// lands on a marker of a selected graph card. While set, drags move the point, not the card.
  @State private var markerDrag: (seriesID: UUID, index: Int)?

  /// The content's corner radius, so the selection ring hugs each element shape correctly
  /// (a too-round ring around a square image is what reads as "wrong").
  private var radius: CGFloat {
    switch card.elementKind {
    case .text: 12
    case .equation: 12
    case .image: 8
    case .sticky: 14
    case .checklist, .table: 10
    case .rectangle: 8
    default: 6
    }
  }
  private var minW: CGFloat { card.minimumSize.width }
  private var minH: CGFloat { card.minimumSize.height }
  private var zoom: CGFloat { max(scale, 0.01) }
  private var isTextElement: Bool { card.elementKind == .text }
  private var isEquationElement: Bool { card.elementKind == .equation }
  private var isGraphElement: Bool { card.elementKind == .graph }
  /// An empty text card is just a place to write, not a placed object — so it shows no chrome.
  private var isEmptyText: Bool { isTextElement && interaction.text.trimmed.isEmpty }
  /// Suppress chrome (ring, handles, delete ✕) on an empty text card ONLY while it's being edited —
  /// a bare writing caret needs no box. Once merely selected (e.g. picked by marquee), an empty text
  /// card must show its selection chrome so it's visibly deletable rather than an invisible ghost.
  private var suppressEmptyChrome: Bool { isEmptyText && isEditing }

  /// The frame to draw right now — base frame plus any in-flight move or resize.
  private var liveFrame: CGRect {
    if let resize { return applyResize(resize.corner, translation: resize.translation, to: card.frame) }
    if let textWidthResize {
      return textWidthFrame(textWidthResize.edge, translation: textWidthResize.translation, in: card.frame)
    }
    var f = card.frame
    f.origin.x += moveDelta.width / zoom
    f.origin.y += moveDelta.height / zoom
    f.origin.x += interaction.dragDelta.width
    f.origin.y += interaction.dragDelta.height
    return f
  }

  var body: some View {
    cardBody
      .opacity(card.isArchived ? 0.4 : 1)   // superseded ideas fade but stay for lineage
      .frame(width: liveFrame.width * zoom, height: liveFrame.height * zoom, alignment: .topLeading)
      .background(surface)
      .overlay(graphDropRing)
      .overlay(selectionChrome)
      .overlay(deleteButton, alignment: .topTrailing)
      .overlay(lockBadge, alignment: .topLeading)
      .overlay(pointComposerPopover, alignment: .bottom)
      .offset(x: liveFrame.minX * zoom, y: liveFrame.minY * zoom)
      .onHover { hovering = $0 }
      .onChange(of: interaction.text) { oldValue, newValue in
        // FreeWriteEditor writes serialized text here. Keeping the plain-text cache current lets
        // static cards and persistence read it without materializing an NSTextView controller.
        interaction.cachePlainText(newValue)
        board.noteEdited(cardID: card.id, previousText: oldValue)
      }
      .onChange(of: isSelected) { _, selected in
        // The Point Composer belongs to a selected graph; drop it if the card loses selection.
        if !selected { pointComposer = nil }
      }
      .onChange(of: card.tint) { _, _ in applyEditorTint() }
      .onChange(of: isEditing) { _, editing in
        // The inline text editor mounts a beat after editing flips on; recolor once it exists.
        if editing { DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { applyEditorTint() } }
      }
      .onReceive(NotificationCenter.default.publisher(for: .composerAddGraphPoint)) { note in
        // The ⌘K "Add point to graph…" command targets a graph card by id; only that card responds,
        // ensures it's selected, and opens the composer seeded at the middle of its axis ranges.
        guard isGraphElement, note.object as? UUID == card.id else { return }
        board.select(card.id)
        let spec = card.graph ?? CardState.GraphSpec()
        let mid = CardState.GraphPoint(x: (spec.xMin + spec.xMax) / 2, y: (spec.yMin + spec.yMax) / 2)
        openPointComposer(at: CardState.GraphPoint(
          x: Self.roundToStep(mid.x, span: spec.xMax - spec.xMin),
          y: Self.roundToStep(mid.y, span: spec.yMax - spec.yMin)))
      }
  }

  // MARK: Body (editor + move/select catcher)

  /// TEXT edits inline, on the board — writing is the core act and it stays in place; only the
  /// structured editors (equation, graph, labels) present in the centered `EditingStage`, and the
  /// writing sheet remains an explicit ⇧⌘F summon. So: a text card being edited mounts the live
  /// editor right here; every other kind renders statically while its stage floats above (the graph
  /// carve-outs — ⌥-click points, marker drag — are gestures, not edit sessions, and stay live).
  private var cardBody: some View {
    ZStack(alignment: .topLeading) {
      if isEditing, isTextElement {
        FreeWriteEditor(
          text: $interaction.text,
          initialAttributedText: interaction.attributedSnapshot,
          initialInk: interaction.ink,
          placeholder: "Brain dump...".localizedUI,
          onCountChange: { interaction.count = $0 },
          onSelectionChange: { interaction.selection = $0 },
          onEscape: { interaction.controller.resignFocus() },
          onFocusChange: { active in
            if active {
              board.beginEditing(card.id)
            } else if !interaction.appSearch.isOpen, !interaction.mentions.isOpen {
              // The editor only truly stopped editing if focus left for a real reason (a
              // click-away) — not because our own inline search field or mention menu took
              // first responder. Tearing down editing there would kill the very popup the
              // user is picking from.
              board.endEditing(card.id)
            }
          },
          onLayoutChange: { naturalWidth, contentHeight in
            // The editor's own layout drives the live hug — width from its unwrapped text, height
            // from its laid-out text, both in board units (the editor lays out at board size and
            // is scaled by zoom). Sizing from a parallel NSString measurement clipped the top line
            // (the twin wraps ~10pt before the view); see `fitTextEditing`.
            board.fitTextEditing(card.id, naturalEditorWidth: naturalWidth, editorContentHeight: contentHeight)
          },
          fontScale: card.textScale,
          boardContext: { board.lintContext(excluding: card.id) },
          definedVariables: { board.definedVariableNames },
          cardTint: { card.tint },
          mentions: interaction.mentions,
          appSearch: interaction.appSearch,
          controller: interaction.controller,
          lint: interaction.lint,
          refine: interaction.refine,
          store: DumpStore.shared
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        // The live editor keeps its native (board-size) layout and is scaled to fill the card.
        // Its text softens only while you're actively editing this one card — every other card
        // is layout-zoomed and stays crisp. Anchored top-left to line up with the static render.
        .frame(width: liveFrame.width, height: liveFrame.height, alignment: .topLeading)
        .scaleEffect(zoom, anchor: .topLeading)
      } else {
        // Non-editing cards render from the serialized plain text (tokens like "@github"), so
        // the chip renderer can rebuild the styled chips — `interaction.text` is the visible
        // string, where a chip has already collapsed to its bare label. Fonts/padding scale with
        // zoom so the text is laid out at screen size (crisp), not stretched.
        CanvasElementContent(card: card, text: interaction.plainText, ink: board.ink(for: card), definedVars: board.definedVariableNames, failedCommands: board.failedShellCommands, zoom: zoom * card.textScale, graphSelected: isGraphElement && isSelected && !isEditing, graphDropTarget: isGraphElement && board.equationDropTargetID == card.id)
          .padding(.horizontal, (isTextElement ? 16 : 0) * zoom)
          .padding(.vertical, (isTextElement ? 18 : 0) * zoom)
          .allowsHitTesting(false)
          // An in-flight corner drag on a text card previews as a GEOMETRIC transform: the text
          // keeps its base layout and scales as a whole. Re-laying it out at a new font size every
          // gesture frame flickered and shed glyph fragments (1.4.5 feedback). Both the layout
          // frame and the scale pin top-leading — the preview frame already moved its origin for
          // the drag's anchor corner, so its top-left IS the scaled content's top-left.
          .frame(width: staticLayoutSize.width * zoom, height: staticLayoutSize.height * zoom, alignment: .topLeading)
          .scaleEffect(resizeScaleFactor, anchor: .topLeading)
      }

      // Select on mouse-down so handles appear immediately. SwiftUI's separate
      // single/double tap recognizers wait out the double-click interval first.
      CardPointerCatcher(
        onPress: { modifiers, localPoint in
          if card.elementKind == .checklist, modifiers.isEmpty {
            let rowHeight = 30 * zoom
            let index = Int(max(0, localPoint.y - 16 * zoom) / rowHeight)
            if card.checklist?.indices.contains(index) == true {
              board.toggleChecklistItem(card.id, index: index)
              armedForMove = false
              return .consumed
            }
          }
          if card.elementKind == .text, modifiers.isEmpty {
            let line = Int(max(0, localPoint.y - 18 * zoom) / (24 * zoom))
            let lines = interaction.plainText.components(separatedBy: "\n")
            if lines.indices.contains(line), lines[line].hasPrefix("- [") {
              board.toggleTextChecklistLine(card.id, lineIndex: line)
              armedForMove = false
              return .consumed
            }
          }
          // Graph cards intercept ⌥-click (add/remove a data point) and — when selected — a plain
          // press that starts on a marker (drag that marker instead of the card). A consumed press
          // suppresses select/move for this gesture.
          if let disposition = graphPressDisposition(modifiers: modifiers, localPoint: localPoint) {
            armedForMove = false
            return disposition
          }
          // Shift- and Command-click both TOGGLE this card's membership in the selection (shift no
          // longer pure-unions), so clicking an already-picked card in a multi-selection drops it.
          let toggling = modifiers.contains(.shift) || modifiers.contains(.command)
          // A plain press selects (if needed) AND arms the move, so one press + drag moves the
          // card in a single gesture. The 4px drag dead-zone keeps a plain click from nudging it.
          armedForMove = !toggling
          // ⌥-drag duplicates: armed here, triggered when the drag leaves the dead-zone, so a
          // bare ⌥-click stays a plain select. Graphs never reach this line with ⌥ held — their
          // disposition consumed it above for data points.
          duplicateDragArmed = !toggling && modifiers.contains(.option)
          if toggling || !isSelected {
            board.select(card.id, toggling: toggling)
          }
          return .passthrough
        },
        onDoubleClick: enterEditing,
        onDragChanged: updateMovePreview,
        onDragEnded: commitMove,
        onMarkerDrag: updateMarkerDrag,
        onMarkerDragEnded: endMarkerDrag
      )
      .allowsHitTesting(!isEditing && selectable)

      // Selected graph cards get a live interaction layer ABOVE the catcher: the ✕-legend (its
      // small top-right region claims clicks) and a passive hover crosshair/readout. Plot-area
      // presses (⌥-click, marker drag) still fall through to the catcher below.
      if isGraphElement, isSelected, !isEditing, selectable {
        GraphInteractionOverlay(spec: card.graph ?? CardState.GraphSpec(), board: board, graphID: card.id)
      }
    }
  }

  // MARK: Graph drop ring

  /// The accent ring a graph card shows while a parseable equation is dragged over it — a 2pt stroke
  /// just inside the frame (the plot-rect lightening is drawn inside GraphCardView).
  @ViewBuilder
  private var graphDropRing: some View {
    if isGraphElement, board.equationDropTargetID == card.id {
      RoundedRectangle(cornerRadius: radius, style: .continuous)
        .strokeBorder(Theme.Palette.accent, lineWidth: 2)
        .padding(1)
        .allowsHitTesting(false)
    }
  }

  /// The ⌥-click Point Composer strip — X/Y/label fields and a tint swatch row, floating below the
  /// card on the same glass recipe. Shown whenever `pointComposer` is armed. This is a GESTURE
  /// affordance (⌥-click on a selected graph's plot), NOT an edit session, so it stays in the card
  /// rather than moving to the EditingStage — the owner's explicit carve-out.
  @ViewBuilder
  private var pointComposerPopover: some View {
    if pointComposer != nil {
      PointComposerStrip(
        draft: Binding(get: { pointComposer ?? PointComposerDraft() },
                       set: { pointComposer = $0 }),
        width: max(min(liveFrame.width * zoom, 380), 300),
        onCommit: commitPointComposer,
        onCancel: cancelPointComposer)
        .offset(y: liveFrame.height * zoom / 2 + 30)
    }
  }

  /// Double-click opens the card's editing session — the centered `EditingStage` (keyed off
  /// `board.editingCardID`) takes it from here: seeding its draft, showing the right editor, and
  /// owning focus/commit/Esc. This just arms edit mode; freehand/image kinds have no stage, so the
  /// canvas guards `beginEditing` for them (a double-click there does nothing).
  private func enterEditing() {
    board.beginEditing(card.id)
    // Text edits inline — hand the caret to the just-mounted in-card editor. Stage kinds focus
    // their own fields on appear.
    if isTextElement {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { interaction.controller.focus() }
    }
  }

  /// Recolor the LIVE editor's text to the card's tint: every run except chips (marked with
  /// `.mentionToken`) and per-range ink (marked with `.inkSlot`) takes the ink, and the typing
  /// attributes follow so new text matches. Inked spans keep their own color so a whole-card tint
  /// never stomps range ink.
  private func applyEditorTint() {
    guard isEditing, isTextElement,
          let tv = interaction.controller.coordinator?.textView, let storage = tv.textStorage else { return }
    let color = Theme.tintColor(card.tint) ?? Theme.nsBodyText
    let full = NSRange(location: 0, length: storage.length)
    storage.beginEditing()
    storage.enumerateAttributes(in: full, options: []) { attrs, range, _ in
      guard attrs[.mentionToken] == nil, attrs[.inkSlot] == nil else { return }
      storage.addAttribute(.foregroundColor, value: color, range: range)
    }
    storage.endEditing()
    tv.typingAttributes[.foregroundColor] = color
    tv.insertionPointColor = Theme.tintColor(card.tint) ?? Theme.Palette.nsAccent
  }

  private func commitMove(_ translation: CGSize) {
    moveDelta = .zero
    board.clearEquationDropTarget()
    // Retire guides on every drag end — including the click and ⌥-duplicate branches below that
    // never reach the single-card snap commit.
    board.clearSnapGuides()
    let wasDuplicating = duplicateDragStarted
    duplicateDragStarted = false
    duplicateDragArmed = false
    guard armedForMove else { return }
    // An ⌥-drag moved the freshly inserted copies through the board preview (the selection is the
    // copies, not this card), so it always commits through finishMovePreview — whose undo folds
    // into the duplicate's checkpoint.
    if wasDuplicating {
      board.finishMovePreview(commit: true)
      return
    }
    // A plain click (no real drag) on a card inside a multi-selection collapses the selection to
    // just this card — resolved here on mouse-UP, so a genuine group drag (translation ≥ 4px) still
    // moves the whole group. The press left the group intact precisely so this decision waits.
    if hypot(translation.width, translation.height) < 4 {
      if board.selectedCardIDs.count > 1, board.selectedCardIDs.contains(card.id) {
        board.select(card.id)
      }
      return
    }
    guard !card.locked else { return }
    if board.selectedCardIDs.contains(card.id), board.selectedCardIDs.count > 1 {
      board.finishMovePreview(commit: true)
    } else {
      // Snap the committed frame through the same helper the preview used, so what landed on screen
      // is what commits (preview==commit). The helper also clears its guides via the setFrame path
      // below, but we clear explicitly so a no-op commit still retires the hairlines.
      let proposed = CGSize(width: translation.width / zoom, height: translation.height / zoom)
      let snapped = board.snappedDelta(for: [card.id], proposed: proposed, tolerance: 8 / zoom)
      board.clearSnapGuides()
      board.setFrame(card.id, CGRect(
        x: card.x + snapped.width,
        y: card.y + snapped.height,
      width: card.w, height: card.h))
      // The single-card path skips finishMovePreview, so it needs its own equation→graph drop.
      if isEquationElement { board.absorbEquationDropIfNeeded(card.id) }
    }
  }

  private func updateMovePreview(_ translation: CGSize) {
    guard armedForMove, !card.locked else { return }
    // ⌥-drag: once past the click dead-zone, drop in-place copies and hand the rest of the gesture
    // to the board preview — the copies are the selection now, so this card stays put underneath.
    if duplicateDragArmed, !duplicateDragStarted, hypot(translation.width, translation.height) >= 4 {
      board.beginDragDuplicate()
      duplicateDragStarted = true
    }
    if duplicateDragStarted {
      board.updateMovePreview(by: CGSize(width: translation.width / zoom, height: translation.height / zoom), tolerance: 8 / zoom)
      return
    }
    if board.selectedCardIDs.contains(card.id), board.selectedCardIDs.count > 1 {
      board.updateMovePreview(by: CGSize(width: translation.width / zoom, height: translation.height / zoom), tolerance: 8 / zoom)
    } else {
      // Single card: snap in board space through the shared helper (which publishes the guides),
      // then scale back to screen space — `liveFrame` divides `moveDelta` by zoom, so the card
      // sticks to exactly the snapped position the commit will land on.
      let proposed = CGSize(width: translation.width / zoom, height: translation.height / zoom)
      let snapped = board.snappedDelta(for: [card.id], proposed: proposed, tolerance: 8 / zoom)
      moveDelta = CGSize(width: snapped.width * zoom, height: snapped.height * zoom)
    }
    // A lone equation dragged onto a graph gets a drop-target highlight; the absorb itself is the
    // engine's on the move-commit. Only equations bother computing this (updateEquationDropTarget bails otherwise).
    if isEquationElement, !(board.selectedCardIDs.contains(card.id) && board.selectedCardIDs.count > 1) {
      board.updateEquationDropTarget(movedID: card.id, center: CGPoint(x: liveFrame.midX, y: liveFrame.midY))
    }
  }

  // MARK: Graph plot interaction (⌥-click points, marker drag)

  /// The graph plot geometry for a catcher-local point. The catcher fills the card frame at screen
  /// scale (× zoom) while GraphCardView renders its plot inside a 2pt inset, so we size the geometry
  /// to the card frame (screen space, minus the 4pt padding) and shift the point in by 2pt. Returns
  /// the geometry and the plot-space (pre-inset) point.
  private func graphGeometry(forCatcher point: CGPoint) -> (geom: GraphGeometry, local: CGPoint)? {
    guard isGraphElement, let spec = card.graph else { return nil }
    let size = CGSize(width: liveFrame.width * zoom - 4, height: liveFrame.height * zoom - 4)
    guard size.width > 1, size.height > 1 else { return nil }
    return (GraphGeometry(spec: spec, size: size), CGPoint(x: point.x - 2, y: point.y - 2))
  }

  /// The series id + index of a marker within 10 view points of a catcher-local point, or nil.
  private func markerHit(atCatcher point: CGPoint) -> (seriesID: UUID, index: Int)? {
    guard let (geom, local) = graphGeometry(forCatcher: point), let spec = card.graph else { return nil }
    for series in spec.series {
      for (index, p) in (series.points ?? []).enumerated() {
        let vp = geom.viewPoint(p)
        if hypot(vp.x - local.x, vp.y - local.y) <= 14 { return (series.id, index) }
      }
    }
    return nil
  }

  /// Decide whether a graph card should intercept this press. ⌥-click adds a point (or removes the
  /// one under the cursor) and consumes the event; a plain press on a marker of a SELECTED graph card
  /// arms a marker drag. Returns nil when the press should fall through to normal select/move.
  private func graphPressDisposition(modifiers: EventModifiers, localPoint: CGPoint) -> CardPointerCatcher.PressDisposition? {
    guard isGraphElement, let (geom, local) = graphGeometry(forCatcher: localPoint) else { return nil }
    if modifiers.contains(.option) {
      if let hit = markerHit(atCatcher: localPoint) {
        // ⌥-click on an existing marker keeps the fast remove.
        board.removeGraphPoint(card.id, seriesID: hit.seriesID, index: hit.index)
      } else if geom.contains(local) {
        // ⌥-click on empty plot opens the Point Composer, prefilled from the click's data coords,
        // instead of adding a point instantly.
        openPointComposer(at: roundedPoint(geom.clampedData(local), geom: geom))
      } else {
        return nil
      }
      return .consumed
    }
    if isSelected, let hit = markerHit(atCatcher: localPoint) {
      board.registerUndoCheckpoint()
      markerDrag = hit
      return .marker
    }
    return nil
  }

  private func updateMarkerDrag(_ localPoint: CGPoint) {
    guard let markerDrag, let (geom, local) = graphGeometry(forCatcher: localPoint) else { return }
    // Preserve the dragged marker's own label and tint — only its coordinates move.
    var moved = geom.clampedData(local)
    if let points = card.graph?.series.first(where: { $0.id == markerDrag.seriesID })?.points,
       points.indices.contains(markerDrag.index) {
      moved.label = points[markerDrag.index].label
      moved.tint = points[markerDrag.index].tint
    }
    board.setGraphPoint(card.id, seriesID: markerDrag.seriesID, index: markerDrag.index,
                        to: roundedPoint(moved, geom: geom), undoable: false)
  }

  private func endMarkerDrag() { markerDrag = nil }

  /// Round a dragged/added point to the axes' tick-step precision (2 significant decimals of the
  /// step) so a placed point reads as a clean value rather than a long float.
  private func roundedPoint(_ point: CardState.GraphPoint, geom: GraphGeometry) -> CardState.GraphPoint {
    CardState.GraphPoint(x: Self.roundToStep(point.x, span: geom.xMax - geom.xMin),
                         y: Self.roundToStep(point.y, span: geom.yMax - geom.yMin),
                         label: point.label, tint: point.tint)
  }

  private static func roundToStep(_ value: Double, span: Double) -> Double {
    guard span > 0 else { return value }
    // The tick step (1/2/5 × 10ⁿ over ~5 ticks); round to a hundredth of it for 2 extra decimals.
    let exponent = floor(log10(span / 5))
    let step = pow(10, exponent)
    let quantum = step / 100
    guard quantum > 0 else { return value }
    return (value / quantum).rounded() * quantum
  }

  // MARK: Point Composer (⌥-click)

  /// Open the Point Composer for a fresh point at `seed`'s (already tick-rounded) coordinates.
  private func openPointComposer(at seed: CardState.GraphPoint) {
    pointComposer = PointComposerDraft(seed: seed)
  }

  /// Confirm the composer: resolve its fields (invalid X/Y fall back to the seeded coords), append the
  /// point, and dismiss. A same-gesture undo checkpoint isn't needed — `addGraphPoint` registers one.
  private func commitPointComposer() {
    guard let draft = pointComposer else { return }
    board.addGraphPoint(card.id, at: draft.resolved())
    pointComposer = nil
  }

  private func cancelPointComposer() {
    pointComposer = nil
  }

  // MARK: Selection ring + resize handles

  /// Px the selection ring sits outside the content, so it frames the element with a little
  /// breathing room instead of crowding it (and the handles ride that same expanded rect).
  private let selectionGap: CGFloat = 5

  @ViewBuilder
  private var selectionChrome: some View {
    // An empty text card stays bare — a writing spot, not a boxed object. While you type into
    // a text card it's chromeless too; the ring returns only once it's a placed object you
    // select to move or resize. Shapes keep their ring while editing.
    if (isSelected || isEditing) && !suppressEmptyChrome {
      let showRing = !isTextElement || (isSelected && !isEditing)
      // Image cards draw their own rounded border, so a ring sitting `selectionGap` px outside reads
      // as an ugly double border with a gap. Hug the image's own edge instead — a single clean
      // accent outline. Other elements (text, shapes, lines) keep the offset ring.
      let hugsContent = card.elementKind == .image
      let ringGap: CGFloat = hugsContent ? 1 : selectionGap
      let ringRadius: CGFloat = hugsContent ? radius : radius + selectionGap
      // Handles only grab in the select tool — in a drawing tool a corner drag should draw, not resize.
      let showHandles = isSelected && !isEditing && !card.locked && selectable
      GeometryReader { geo in
        ZStack {
          if showRing {
            RoundedRectangle(cornerRadius: ringRadius, style: .continuous)
              .strokeBorder(Theme.Palette.accent.opacity(isEditing ? 0.9 : 0.7), lineWidth: hugsContent ? 1.5 : 1)
              .frame(width: geo.size.width + ringGap * 2, height: geo.size.height + ringGap * 2)
              .position(x: geo.size.width / 2, y: geo.size.height / 2)
              .allowsHitTesting(false)
          }
          if showHandles {
            ForEach(Corner.allCases, id: \.self) { corner in
              handleDot
                .position(handlePoint(corner, in: geo.size))
                .gesture(resizeGesture(corner))
                // A diagonal resize cursor over each corner handle, restored on exit. Pushing/popping
                // keeps the cursor correct even as SwiftUI reuses the handle views across cards.
                .onHover { inside in
                  if inside { corner.resizeCursor.push() } else { NSCursor.pop() }
                }
            }
            if isTextElement {
              ForEach(HorizontalEdge.allCases, id: \.self) { edge in
                textWidthHandle
                  .position(textWidthHandlePoint(edge, in: geo.size))
                  .gesture(textWidthResizeGesture(edge))
                  .onHover { inside in
                    if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                  }
                  .help("Drag to change text wrapping width".localizedUI)
              }
            }
          }
        }
      }
    }
  }

  private func handlePoint(_ corner: Corner, in size: CGSize) -> CGPoint {
    switch corner {
    case .topLeading: CGPoint(x: -selectionGap, y: -selectionGap)
    case .topTrailing: CGPoint(x: size.width + selectionGap, y: -selectionGap)
    case .bottomLeading: CGPoint(x: -selectionGap, y: size.height + selectionGap)
    case .bottomTrailing: CGPoint(x: size.width + selectionGap, y: size.height + selectionGap)
    }
  }

  private func textWidthHandlePoint(_ edge: HorizontalEdge, in size: CGSize) -> CGPoint {
    CGPoint(x: edge == .leading ? -selectionGap : size.width + selectionGap, y: size.height / 2)
  }

  /// A small white square with a hairline accent edge and a soft shadow — reads as a crisp,
  /// premium resize handle on the dark glass rather than a flat blue block.
  private var handleDot: some View {
    RoundedRectangle(cornerRadius: 2.5, style: .continuous)
      .fill(Color.white)
      .frame(width: 8, height: 8)
      .overlay(RoundedRectangle(cornerRadius: 2.5, style: .continuous).strokeBorder(Theme.Palette.accent.opacity(0.9), lineWidth: 1))
      .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
      .padding(9)
      .contentShape(Rectangle())
  }

  /// A vertical pill distinguishes reflow handles from the four square scale handles. The visible
  /// mark stays quiet while its padded hit target remains easy to acquire with a pointer.
  private var textWidthHandle: some View {
    Capsule()
      .fill(Color.white)
      .frame(width: 6, height: 18)
      .overlay(Capsule().strokeBorder(Theme.Palette.accent.opacity(0.9), lineWidth: 1))
      .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
      .padding(.horizontal, 10)
      .padding(.vertical, 7)
      .contentShape(Rectangle())
  }

  private func textWidthResizeGesture(_ edge: HorizontalEdge) -> some Gesture {
    DragGesture(minimumDistance: 3, coordinateSpace: .local)
      .updating($textWidthResize) { value, state, _ in
        state = TextWidthResizeSession(edge: edge, translation: value.translation)
      }
      .onEnded { value in
        board.setFrame(card.id, textWidthFrame(edge, translation: value.translation, in: card.frame))
      }
  }

  private func resizeGesture(_ corner: Corner) -> some Gesture {
    DragGesture(minimumDistance: 4, coordinateSpace: .local)
      .updating($resize) { value, state, _ in state = ResizeSession(corner: corner, translation: value.translation) }
      .onEnded { value in
        if isTextElement {
          // Text cards SCALE their font (Apple Freeform), not reflow a box (issue #77): commit the
          // new absolute scale, then correct the frame to hug the text at that scale with the drag's
          // anchor corner (opposite the handle) kept fixed. One undo restores scale + frame.
          let factor = textResizeFactor(corner, translation: value.translation, base: card.frame)
          let newScale = Double(card.textScale * factor)
          let fitted = BoardViewModel.fittedTextSize(board.plainText(for: card), fontScale: CGFloat(newScale))
          board.scaleTextCard(card.id, fontScale: newScale,
                              frame: anchoredFrame(handle: corner, size: fitted, in: card.frame))
        } else {
          board.setFrame(card.id, applyResize(corner, translation: value.translation, to: card.frame))
        }
      }
  }

  /// The live font-scale factor from an in-flight corner drag on THIS text card (issue #77) — 1
  /// unless a resize is scaling it. Feeds both the preview frame (`applyResize`) and the content's
  /// `scaleEffect`, so the text visibly scales during the drag without relayout.
  private var resizeScaleFactor: CGFloat {
    guard isTextElement, let resize else { return 1 }
    return textResizeFactor(resize.corner, translation: resize.translation, base: card.frame)
  }

  /// The size the static content LAYS OUT at: the live frame — except during a text-card resize
  /// preview, where content keeps the base frame's layout and `scaleEffect` stretches it into the
  /// preview box (see cardBody).
  private var staticLayoutSize: CGSize {
    (isTextElement && resize != nil) ? card.frame.size : liveFrame.size
  }

  /// Reflow a text card at a user-chosen width, keeping the opposite side anchored and deriving
  /// height from the existing text metrics. Font scale is deliberately untouched.
  private func textWidthFrame(_ edge: HorizontalEdge, translation: CGSize, in base: CGRect) -> CGRect {
    let dx = translation.width / zoom
    let proposedWidth = edge == .trailing ? base.width + dx : base.width - dx
    let width = max(proposedWidth, CardState.textMinSize.width)
    let x = edge == .leading ? base.maxX - width : base.minX
    let text = board.plainText(for: card)
    let height = text.trimmed.isEmpty
      ? max(base.height, CardState.textMinSize.height)
      : BoardViewModel.fittedTextHeight(text, width: width, fontScale: card.textScale)
    return CGRect(x: x, y: base.minY, width: width, height: height)
  }

  /// Proportional font-scale factor from a corner drag on a text card: aspect-locked to the drag's
  /// dominant axis, then clamped so the RESULTING `fontScale` stays in 0.4…6.0. All math in board
  /// space (translations divided by `zoom`).
  private func textResizeFactor(_ corner: Corner, translation t: CGSize, base: CGRect) -> CGFloat {
    guard base.width > 0, base.height > 0 else { return 1 }
    let dx = t.width / zoom, dy = t.height / zoom
    let widthSign: CGFloat = (corner == .topTrailing || corner == .bottomTrailing) ? 1 : -1
    let heightSign: CGFloat = (corner == .bottomLeading || corner == .bottomTrailing) ? 1 : -1
    let ratio = abs(dx) >= abs(dy)
      ? (base.width + widthSign * dx) / base.width
      : (base.height + heightSign * dy) / base.height
    let current = card.textScale
    let clamped = min(max(current * ratio, 0.4), 6.0)
    return clamped / current
  }

  /// A frame of `size` that keeps the corner OPPOSITE `handle` (the drag anchor) pinned where it sits
  /// in `base`, so scaling grows/shrinks toward the handle the way Freeform does.
  private func anchoredFrame(handle: Corner, size: CGSize, in base: CGRect) -> CGRect {
    switch handle {
    case .bottomTrailing: return CGRect(x: base.minX, y: base.minY, width: size.width, height: size.height)
    case .topLeading:     return CGRect(x: base.maxX - size.width, y: base.maxY - size.height, width: size.width, height: size.height)
    case .topTrailing:    return CGRect(x: base.minX, y: base.maxY - size.height, width: size.width, height: size.height)
    case .bottomLeading:  return CGRect(x: base.maxX - size.width, y: base.minY, width: size.width, height: size.height)
    }
  }

  /// New frame for a corner drag, clamped to the minimum size by pushing the moving edge back. Text
  /// cards instead scale their font (issue #77): the live preview frame is `base` scaled about the
  /// anchor corner by `textResizeFactor`, so the box tracks the font growing under the handle.
  private func applyResize(_ corner: Corner, translation t: CGSize, to base: CGRect) -> CGRect {
    if isTextElement {
      let factor = textResizeFactor(corner, translation: t, base: base)
      return anchoredFrame(handle: corner, size: CGSize(width: base.width * factor, height: base.height * factor), in: base)
    }
    let dx = t.width / zoom, dy = t.height / zoom
    var minX = base.minX, minY = base.minY, maxX = base.maxX, maxY = base.maxY
    switch corner {
    case .topLeading: minX += dx; minY += dy
    case .topTrailing: maxX += dx; minY += dy
    case .bottomLeading: minX += dx; maxY += dy
    case .bottomTrailing: maxX += dx; maxY += dy
    }
    if maxX - minX < minW {
      if corner == .topLeading || corner == .bottomLeading { minX = maxX - minW } else { maxX = minX + minW }
    }
    if maxY - minY < minH {
      if corner == .topLeading || corner == .topTrailing { minY = maxY - minH } else { maxY = minY + minH }
    }
    // Shift constrains box shapes to a square: grow the smaller side to match the larger, anchored
    // at the corner opposite the handle. Read live off the current flags, so pressing/releasing
    // Shift mid-resize snaps the very next update.
    if card.elementKind.constrainsToSquare, NSEvent.modifierFlags.contains(.shift) {
      let side = max(maxX - minX, maxY - minY)
      switch corner {
      case .topLeading: minX = maxX - side; minY = maxY - side
      case .topTrailing: maxX = minX + side; minY = maxY - side
      case .bottomLeading: minX = maxX - side; maxY = minY + side
      case .bottomTrailing: maxX = minX + side; maxY = minY + side
      }
    }
    return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
  }

  // MARK: Delete

  @ViewBuilder
  private var deleteButton: some View {
    if isSelected && !isEditing && !card.locked && !suppressEmptyChrome && selectable {
      Button(action: { board.delete(card.id) }) {
        Image(systemName: "xmark")
          .font(.system(size: 9, weight: .bold))
          .foregroundStyle(Color.white.opacity(0.9))
          .frame(width: 18, height: 18)
          .background(Circle().fill(Color.black.opacity(0.55)))
          .overlay(Circle().strokeBorder(Color.white.opacity(0.16), lineWidth: 0.5))
          .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
          .contentShape(Circle())
      }
      .buttonStyle(.plain)
    .help("Delete card".localizedUI)
      .offset(x: selectionGap + 4, y: -(selectionGap + 4))
    }
  }

  @ViewBuilder
  private var lockBadge: some View {
    if card.locked {
      Image(systemName: "lock.fill")
        .font(.system(size: 10, weight: .bold))
        .foregroundStyle(Color.white.opacity(0.82))
        .frame(width: 20, height: 20)
        .background(Circle().fill(Color.black.opacity(0.45)))
        .overlay(Circle().strokeBorder(Color.white.opacity(0.16), lineWidth: 1))
        .offset(x: -7, y: -7)
        .allowsHitTesting(false)
    }
  }

  // MARK: Surface

  // Text writes directly on the canvas — no filled "text box" behind it. Shapes and images
  // draw their own fills in CanvasElementContent, so every card's frame stays transparent here.
  private var surface: some View { Color.clear }
}

// MARK: - Element rendering

private struct CanvasElementContent: View {
  let card: CardState
  /// Serialized plain text (`@github`, `[image: …]`, literal prose) for text cards.
  let text: String
  /// Per-range text ink over `text` (serialized-offset spans), resolved to colors at render.
  var ink: [InkRun] = []
  /// Board-scoped variable names, for styling `$name` references defined in other cards.
  var definedVars: Set<String> = []
  /// Commands that failed on the last copy — their tokens render amber.
  var failedCommands: Set<String> = []
  /// Board zoom — fonts scale by it so text is laid out (and stays crisp) at screen size.
  var zoom: CGFloat = 1
  /// Graph-card display flags. `graphSelected` hands the ✕-legend to the interactive overlay (drawn
  /// in cardBody); `graphDropTarget` lightens the plot for an incoming equation. Both false on export.
  var graphSelected: Bool = false
  var graphDropTarget: Bool = false

  /// The card's tint slot resolved against the ACTIVE flavor — semantic, so the same element
  /// re-colors when the theme changes.
  private var tint: Color? {
    guard let slot = card.tint, Theme.flavor.tints.indices.contains(slot) else { return nil }
    return Color(nsColor: Theme.flavor.tints[slot])
  }

  var body: some View {
    ZStack {
      Group {
        switch card.elementKind {
        case .text:
          Group {
            if text.trimmed.isEmpty {
              Text("Brain dump...".localizedUI)
                .font(ComposerPreferences.appSwiftUIFont(size: Theme.Typography.body.pointSize * zoom))
                .lineSpacing(Theme.Typography.bodyLineSpacing * zoom)
                .foregroundStyle(Theme.Palette.placeholder)
            } else if Self.containsChecklist(text) {
              InlineChecklistText(text: text, zoom: zoom, tint: tint)
            } else {
              ComposerChipText(tint: tint, plain: text, ink: ink, definedVars: definedVars, failedCommands: failedCommands, zoom: zoom)
            }
          }
          // The card height was measured by the AppKit editor at 100% zoom, but this static text
          // is laid out by SwiftUI at fontSize × zoom — the two don't agree pixel-for-pixel and
          // wrapping isn't scale-linear, so a fitted height can fall a line short at some zooms.
          // Let the text take the height it needs instead of clipping: a few px of overflow past
          // the card edge beats silently dropping the last line.
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case .rectangle:
          ShapeBox(kind: .rectangle, tint: tint)
        case .ellipse:
          ShapeBox(kind: .ellipse, tint: tint)
        case .diamond:
          ShapeBox(kind: .diamond, tint: tint)
        case .line:
          LineShape(arrow: false, points: card.points ?? CardState.defaultLinePoints(), tint: tint)
        case .arrow:
          LineShape(arrow: true, points: card.points ?? CardState.defaultLinePoints(), tint: tint)
        case .freehand:
          FreehandShape(points: card.points ?? CardState.defaultFreehandPoints(), tint: tint)
        case .image:
          ImageObjectPlaceholder(path: card.imagePath)
            .overlay(alignment: .bottomTrailing) {
              // A captured screenshot that's been read on-device carries text into the prompt; mark
              // it so it doesn't look like an inert image.
              if let understanding = card.imageUnderstanding, !understanding.isEmpty {
                Image(systemName: "text.viewfinder")
                  .font(.system(size: 11, weight: .semibold))
                  .foregroundStyle(.white)
                  .padding(5)
                  .background(Color.black.opacity(0.55), in: Circle())
                  .padding(6)
                  .help("Read on-device - this screenshot adds text to the compiled prompt".localizedUI)
              }
            }
        case .equation:
          EquationView(latex: card.latex ?? "", tint: tint, zoom: zoom)
        case .graph:
          GraphCardView(spec: card.graph ?? CardState.GraphSpec(), tint: tint,
                        isDropTarget: graphDropTarget, interactiveLegend: graphSelected)
        case .sticky:
          StickyNoteView(title: card.stickyTitle ?? "", bodyText: text, tint: tint, zoom: zoom)
        case .checklist:
          ChecklistView(items: card.checklist ?? [], tint: tint, zoom: zoom)
        case .table:
          SimpleTableView(spec: card.table ?? CardState.TableSpec(), tint: tint, zoom: zoom)
        }
      }

      if !text.trimmed.isEmpty {
        switch card.elementKind {
        case .rectangle, .ellipse, .diamond:
          // A diagram node: the label fills the box (the box is the boundary).
          NodeLabel(text: text.trimmed, zoom: zoom, tint: tint)
        case .arrow, .line:
          // A connector label: a floating pill so it stays legible over the canvas.
          CanvasLabel(text: text.trimmed, zoom: zoom)
        default:
          EmptyView()
        }
      }
    }
  }

  private static func containsChecklist(_ text: String) -> Bool {
    text.components(separatedBy: "\n").contains { $0.hasPrefix("- [ ] ") || $0.lowercased().hasPrefix("- [x] ") }
  }
}

private struct InlineChecklistText: View {
  let text: String
  let zoom: CGFloat
  let tint: Color?
  var body: some View {
    VStack(alignment: .leading, spacing: 3 * zoom) {
      ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
        if line.hasPrefix("- [ ] ") || line.lowercased().hasPrefix("- [x] ") {
          let checked = line.lowercased().hasPrefix("- [x] ")
          HStack(spacing: 8 * zoom) {
            Image(systemName: checked ? "checkmark.circle.fill" : "circle")
              .foregroundStyle(checked ? (tint ?? Theme.Palette.accent) : Theme.Palette.menuDesc)
            Text(String(line.dropFirst(6))).strikethrough(checked)
          }
          .foregroundStyle(checked ? Theme.Palette.menuDesc : (tint ?? Theme.Palette.body))
        } else {
          Text(line).foregroundStyle(tint ?? Theme.Palette.body)
        }
      }
    }
    .font(ComposerPreferences.appSwiftUIFont(size: Theme.Typography.body.pointSize * zoom))
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }
}

private struct StickyNoteView: View {
  let title: String
  let bodyText: String
  let tint: Color?
  let zoom: CGFloat
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text(title.trimmed.isEmpty ? "Untitled note".localizedUI : title)
        .font(ComposerPreferences.appSwiftUIFont(size: 18 * zoom, weight: .semibold))
        .foregroundStyle(title.trimmed.isEmpty ? Theme.Palette.placeholder : Theme.Palette.body)
        .lineLimit(2)
        .fixedSize(horizontal: false, vertical: true)

      Rectangle()
        .fill(Theme.Palette.body.opacity(0.13))
        .frame(height: max(0.5, 0.75 * zoom))
        .padding(.vertical, 12 * zoom)

      Text(bodyText.trimmed.isEmpty ? "Write something…".localizedUI : bodyText)
        .font(ComposerPreferences.appSwiftUIFont(size: 15 * zoom))
        .foregroundStyle(bodyText.trimmed.isEmpty ? Theme.Palette.placeholder : Theme.Palette.body.opacity(0.88))
        .lineSpacing(3 * zoom)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .padding(18 * zoom)
    .background(stickyFill, in: RoundedRectangle(cornerRadius: 14 * zoom, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 14 * zoom, style: .continuous)
        .strokeBorder(Theme.Palette.body.opacity(Theme.flavor.isDark ? 0.12 : 0.08), lineWidth: 1)
    }
    .shadow(color: Theme.Palette.elementShadow.opacity(0.45), radius: 8 * zoom, y: 3 * zoom)
  }

  private var stickyFill: Color {
    (tint ?? Color.yellow).opacity(Theme.flavor.isDark ? 0.22 : 0.20)
  }
}

private struct ChecklistView: View {
  let items: [CardState.ChecklistItem]
  let tint: Color?
  let zoom: CGFloat
  var body: some View {
    VStack(alignment: .leading, spacing: 8 * zoom) {
      ForEach(items) { item in
        HStack(alignment: .firstTextBaseline, spacing: 9 * zoom) {
          Image(systemName: item.isChecked ? "checkmark.square.fill" : "square")
            .foregroundStyle(item.isChecked ? (tint ?? Theme.Palette.accent) : Theme.Palette.menuDesc)
          Text(item.text).strikethrough(item.isChecked).foregroundStyle(item.isChecked ? Theme.Palette.menuDesc : Theme.Palette.body)
        }
        .font(ComposerPreferences.appSwiftUIFont(size: 15 * zoom))
        .frame(minHeight: 22 * zoom)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .padding(16 * zoom)
    .background(Theme.Palette.raisedTint, in: RoundedRectangle(cornerRadius: 10 * zoom))
  }
}

private struct SimpleTableView: View {
  let spec: CardState.TableSpec
  let tint: Color?
  let zoom: CGFloat
  var body: some View {
    VStack(spacing: 0) {
      tableRow(spec.columns, header: true, rowIndex: nil)
      ForEach(Array(spec.rows.enumerated()), id: \.offset) { index, row in
        tableRow(normalized(row), header: false, rowIndex: index)
      }
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .background(Theme.Palette.raisedTint.opacity(0.72))
    .clipShape(RoundedRectangle(cornerRadius: 10 * zoom, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 10 * zoom, style: .continuous)
        .strokeBorder(Theme.Palette.panelHairline, lineWidth: 1)
    }
    .shadow(color: Theme.Palette.elementShadow.opacity(0.28), radius: 6 * zoom, y: 2 * zoom)
  }

  private func normalized(_ row: [String]) -> [String] {
    Array((row + Array(repeating: "", count: max(0, spec.columns.count - row.count))).prefix(spec.columns.count))
  }

  private func tableRow(_ values: [String], header: Bool, rowIndex: Int?) -> some View {
    HStack(spacing: 0) {
      ForEach(Array(values.enumerated()), id: \.offset) { index, value in
        Text(value.isEmpty && header ? "Column \(index + 1)" : value)
          .font(ComposerPreferences.appSwiftUIFont(size: (header ? 12.5 : 13) * zoom,
                                                    weight: header ? .semibold : .regular))
          .foregroundStyle(header ? (tint ?? Theme.Palette.body) : Theme.Palette.body.opacity(0.88))
          .lineLimit(2)
          .frame(maxWidth: .infinity, minHeight: (header ? 40 : 38) * zoom, alignment: .leading)
          .padding(.horizontal, 12 * zoom)
          .overlay(alignment: .trailing) {
            if index < values.count - 1 {
              Rectangle().fill(Theme.Palette.separator.opacity(0.5)).frame(width: 0.5)
            }
          }
      }
    }
    .background {
      if header {
        (tint ?? Theme.Palette.accent).opacity(Theme.flavor.isDark ? 0.16 : 0.10)
      } else if let rowIndex, rowIndex.isMultiple(of: 2) {
        Theme.Palette.body.opacity(Theme.flavor.isDark ? 0.025 : 0.018)
      }
    }
    .overlay(alignment: .bottom) {
      Rectangle().fill(Theme.Palette.separator.opacity(0.55)).frame(height: 0.5)
    }
  }
}

/// The centered label inside a diagram-node box. No pill background — the surrounding shape is the
/// container — and it wraps/scales to fit rather than truncating mid-word.
private struct NodeLabel: View {
  let text: String
  var zoom: CGFloat = 1
  var tint: Color?

  var body: some View {
    Text(text)
      // Must match the face `BoardViewModel.fittedShapeSize` measures with, or boxes mis-fit.
      .font(ComposerPreferences.appSwiftUIFont(size: 14 * zoom, weight: .semibold))
      .multilineTextAlignment(.center)
      .lineLimit(5)
      .minimumScaleFactor(0.82)
      // Board ink (or the element's tint) — ink on paper casts no shadow (elementShadow is clear
      // on light themes).
      .foregroundStyle(tint ?? Theme.Palette.body)
      .shadow(color: Theme.Palette.elementShadow, radius: 3, y: 1)
      .padding(.horizontal, 12 * zoom)
      .padding(.vertical, 8 * zoom)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .allowsHitTesting(false)
  }
}

// MARK: - Chip-aware static text (non-editing cards)

/// Renders a card's serialized plain text with its mention chips styled — brand icon, brand
/// color, and the `▾` affordance on app chips — so a card looks the same whether or not it's
/// being edited. Built as concatenated `Text` runs so it wraps natively and stays cheap; image
/// placeholders show a small inline glyph (the real attachment only lives in the live editor).
private struct ComposerChipText: View {
  /// Base ink override (the card's tint); chips keep their brand colors.
  var tint: Color? = nil
  let plain: String
  /// Per-range text ink (serialized-offset spans); each run recolors its characters over the base.
  var ink: [InkRun] = []
  /// Board-scoped variable names, so a `$name` reference styles even when defined in another card.
  var definedVars: Set<String> = []
  /// Commands that failed on the last copy — their `$(…)` tokens render amber instead of green.
  var failedCommands: Set<String> = []
  /// Board zoom — the base font + chip icons scale by it so the text is laid out at screen size.
  var zoom: CGFloat = 1

  var body: some View {
    composed
      .font(ComposerPreferences.appSwiftUIFont(size: Theme.Typography.body.pointSize * zoom))
      .lineSpacing(Theme.Typography.bodyLineSpacing * zoom)
      .foregroundStyle(tint ?? Theme.Palette.body)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  /// One styled span over the plain text: an `@mention`/image token, or a copy-time shell token.
  private enum Span { case mention(String); case shell(ShellTemplate.Kind) }

  // Called from `body`, so the main-actor `MentionStyleCache` access in `styledRun` is safe.
  @MainActor private var composed: Text {
    let ns = plain as NSString

    // Merge mention spans and shell-token spans into one ordered, non-overlapping list.
    var spans: [(range: NSRange, span: Span)] = []
    for range in Self.tokenRanges(in: plain) { spans.append((range, .mention(ns.substring(with: range)))) }
    for expression in ShellTemplate.expressions(in: plain, definedNames: definedVars) {
      spans.append((expression.range, .shell(expression.kind)))
    }
    spans.sort { $0.range.location < $1.range.location }

    // Markdown spans over the whole plain text, styled into every non-token gap. One scan per
    // render; the ranges are UTF-16 offsets shared with the token spans.
    let markdown = MarkdownStyle.spans(in: plain)
    func gapRun(_ range: NSRange) -> Text {
      Text(MarkdownStyle.rendered(
        slice: ns.substring(with: range), sliceRange: range, spans: markdown,
        baseSize: Theme.Typography.body.pointSize, zoom: zoom, ink: ink))
    }

    var out = Text(verbatim: "")
    var cursor = 0
    for (range, span) in spans {
      if range.location < cursor { continue }   // overlap (rare): keep the first, skip the rest
      if range.location > cursor {
        out = out + gapRun(NSRange(location: cursor, length: range.location - cursor))
      }
      switch span {
      case let .mention(raw): out = out + Self.styledRun(for: raw, zoom: zoom)
      case let .shell(kind): out = out + Self.shellRun(kind, raw: ns.substring(with: range), zoom: zoom, failed: failedCommands)
      }
      cursor = range.location + range.length
    }
    if cursor < ns.length {
      out = out + gapRun(NSRange(location: cursor, length: ns.length - cursor))
    }
    return out
  }

  /// A copy-time shell token, tinted in place — green monospaced for a `$(…)` command, violet for a
  /// variable definition or `$name` reference. The literal syntax is kept (that's why it was chosen);
  /// only its color and weight change (bold), so it reads as live without a background swatch.
  @MainActor private static func shellRun(_ kind: ShellTemplate.Kind, raw: String, zoom: CGFloat, failed: Set<String>) -> Text {
    // Pin to the card's actual body point size (× zoom) — SwiftUI's semantic `.body` is smaller than
    // `Theme.Typography.body` (the user-adjustable editor font), which shrank the tokens.
    let size = Theme.Typography.body.pointSize * zoom
    // A command that failed on the last copy reads amber, so you can see which `$(…)` to fix.
    let didFail = { if case let .command(command) = kind { return failed.contains(command) }; return false }()
    var content = AttributedString(raw)
    content.font = ShellTokenStyle.isCode(kind)
      ? .system(size: size, weight: .bold, design: .monospaced)
      : .system(size: size, weight: .bold)
    content.foregroundColor = Color(nsColor: didFail ? ShellTokenStyle.warning : ShellTokenStyle.tint(for: kind))
    return Text(content)
  }

  /// Matches any catalog mention token (longest id first so `@build-ios-apps` wins over a
  /// shorter prefix), with an optional `:payload`, plus `[image: …]` placeholders.
  private static let tokenRegex: NSRegularExpression? = {
    let ids = MentionCatalog.all.map { NSRegularExpression.escapedPattern(for: $0.id) }
      .sorted { $0.count > $1.count }
      .joined(separator: "|")
    return try? NSRegularExpression(pattern: "(?:\(ids))(?::[^\\s]+)?|\\[image:[^\\]]*\\]")
  }()

  private static func tokenRanges(in text: String) -> [NSRange] {
    guard let regex = tokenRegex else { return [] }
    let ns = text as NSString
    return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map(\.range)
  }

  @MainActor private static func styledRun(for raw: String, zoom: CGFloat) -> Text {
    if raw.hasPrefix("[image:") {
      return Text(Image(systemName: "photo")).foregroundColor(Theme.Palette.placeholder)
    }
    let parsed = AppToken.parse(raw)
    let appID = parsed?.appID ?? raw
    let item = MentionCatalog.all.first { $0.id == appID }
    let isApp = item?.kind == .app
    let label = isApp ? AppToken.label(appID: appID, selection: parsed?.selection) : (item?.label ?? raw)
    let cache = MentionStyleCache.shared
    let color = Color(nsColor: cache.color(for: appID) ?? Theme.Palette.nsAccent)

    var chip = Text(verbatim: "")
    // Build the inline icon at the zoomed size so the brand mark stays crisp alongside the text.
    if let icon = cache.inlineImage(for: appID, side: (15 * zoom).rounded()) {
      chip = chip + Text(Image(nsImage: icon)).baselineOffset(-2 * zoom) + Text(verbatim: "\u{2009}")
    }
    chip = chip + Text(verbatim: label).foregroundColor(color)
    if isApp { chip = chip + Text(verbatim: "\u{2009}\u{25BE}").foregroundColor(color.opacity(0.5)) }
    return chip
  }
}

private struct CanvasLabel: View {
  let text: String
  var zoom: CGFloat = 1

  var body: some View {
    Text(text)
      .font(ComposerPreferences.appSwiftUIFont(size: 14 * zoom, weight: .semibold))
      .lineLimit(2)
      .multilineTextAlignment(.center)
      .foregroundStyle(Theme.Palette.body)
      .padding(.horizontal, 9 * zoom)
      .padding(.vertical, 5 * zoom)
      .background(
        // Solid fill — a translucent chip lets its own drop shadow bleed through and muddies it.
        RoundedRectangle(cornerRadius: 7, style: .continuous)
          .fill(Theme.Palette.labelChipFill)
          .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .strokeBorder(Theme.Palette.panelHairline, lineWidth: 1))
      )
      .shadow(color: .black.opacity(0.12), radius: 4, y: 1)
      .padding(8)
      .allowsHitTesting(false)
  }
}

private struct ShapeBox: View {
  let kind: BoxShapeKind
  var tint: Color?

  var body: some View {
    BoxShape(kind: kind)
      .fill(tint.map { $0.opacity(Theme.flavor.isDark ? 0.16 : 0.10) } ?? Theme.Palette.elementFill)
      .overlay(BoxShape(kind: kind).stroke(tint ?? Theme.Palette.elementStroke, lineWidth: 2))
      .shadow(color: Theme.Palette.elementShadow, radius: 10, y: 4)
      .padding(2)
  }
}

private enum BoxShapeKind {
  case rectangle
  case ellipse
  case diamond
}

private struct BoxShape: Shape {
  let kind: BoxShapeKind

  func path(in rect: CGRect) -> Path {
    switch kind {
    case .rectangle:
      return RoundedRectangle(cornerRadius: 8, style: .continuous).path(in: rect)
    case .ellipse:
      return Ellipse().path(in: rect)
    case .diamond:
      var path = Path()
      path.move(to: CGPoint(x: rect.midX, y: rect.minY))
      path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
      path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
      path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
      path.closeSubpath()
      return path
    }
  }
}

private struct LineShape: View {
  let arrow: Bool
  let points: [CanvasPoint]
  var tint: Color?

  var body: some View {
    GeometryReader { geo in
      Path { path in
        let normalizedStart = points.first?.cgPoint ?? CGPoint(x: 0.06, y: 0.88)
        let normalizedEnd = points.dropFirst().first?.cgPoint ?? CGPoint(x: 0.94, y: 0.12)
        let start = CGPoint(x: normalizedStart.x * geo.size.width, y: normalizedStart.y * geo.size.height)
        let end = CGPoint(x: normalizedEnd.x * geo.size.width, y: normalizedEnd.y * geo.size.height)
        path.move(to: start)
        path.addLine(to: end)
        if arrow {
          let angle = atan2(end.y - start.y, end.x - start.x)
          let head: CGFloat = 15
          for side in [CGFloat.pi * 0.82, -CGFloat.pi * 0.82] {
            let p = CGPoint(
              x: end.x + cos(angle + side) * head,
              y: end.y + sin(angle + side) * head
            )
            path.move(to: end)
            path.addLine(to: p)
          }
        }
      }
      .stroke(tint ?? Theme.Palette.elementStroke, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
      .shadow(color: Theme.Palette.elementShadow, radius: 6, y: 3)
    }
  }
}

private struct FreehandShape: View {
  let points: [CanvasPoint]
  var tint: Color?

  var body: some View {
    GeometryReader { geo in
      Path { path in
        let mapped = points.map { CGPoint(x: $0.x * geo.size.width, y: $0.y * geo.size.height) }
        guard let first = mapped.first else { return }
        path.move(to: first)
        for point in mapped.dropFirst() { path.addLine(to: point) }
      }
      .stroke(tint ?? Theme.Palette.elementStroke, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
      .shadow(color: Theme.Palette.elementShadow, radius: 6, y: 3)
    }
  }
}

// MARK: - Graph card

/// The plot rectangle + data⇄view mapping for a graph card, computed identically wherever it's
/// needed (curve/marker rendering, hover snapping, and the CardPointerCatcher's ⌥-click / marker
/// drag). One source of truth so a marker never lands off its own dot.
struct GraphGeometry {
  static let leftGutter: CGFloat = 30
  static let bottomGutter: CGFloat = 24
  static let topGutter: CGFloat = 14
  static let rightGutter: CGFloat = 14

  let plot: CGRect
  let xMin: Double
  let xMax: Double
  let yMin: Double
  let yMax: Double

  /// `size` is the graph content's size in its own local space (before the outer 2pt padding, which
  /// the GeometryReader below already excludes). For CardPointerCatcher hit-testing the point must be
  /// in that same local space (see `plotPoint(inCatcher:size:)`).
  init(spec: CardState.GraphSpec, size: CGSize) {
    plot = CGRect(
      x: Self.leftGutter,
      y: Self.topGutter,
      width: max(size.width - Self.leftGutter - Self.rightGutter, 1),
      height: max(size.height - Self.topGutter - Self.bottomGutter, 1))
    (xMin, xMax) = spec.xMax > spec.xMin ? (spec.xMin, spec.xMax) : (spec.xMin, spec.xMin + 10)
    (yMin, yMax) = spec.yMax > spec.yMin ? (spec.yMin, spec.yMax) : (spec.yMin, spec.yMin + 10)
  }

  func viewX(_ value: Double) -> CGFloat {
    plot.minX + CGFloat((value - xMin) / (xMax - xMin)) * plot.width
  }
  func viewY(_ value: Double) -> CGFloat {
    plot.maxY - CGFloat((value - yMin) / (yMax - yMin)) * plot.height
  }
  func viewPoint(_ p: CardState.GraphPoint) -> CGPoint { CGPoint(x: viewX(p.x), y: viewY(p.y)) }

  func dataX(_ x: CGFloat) -> Double {
    xMin + Double((x - plot.minX) / plot.width) * (xMax - xMin)
  }
  func dataY(_ y: CGFloat) -> Double {
    yMax - Double((y - plot.minY) / plot.height) * (yMax - yMin)
  }
  func clampedData(_ p: CGPoint) -> CardState.GraphPoint {
    CardState.GraphPoint(x: min(max(dataX(p.x), xMin), xMax),
                         y: min(max(dataY(p.y), yMin), yMax))
  }

  func contains(_ point: CGPoint) -> Bool { plot.contains(point) }
}

/// Parsed-expression cache keyed by the raw LaTeX string, so a resize/zoom/re-render never re-parses
/// the same expression. A boxed optional distinguishes "cached as unparseable" from "not yet tried".
private enum GraphExpressionCache {
  private final class Box { let value: GraphExpression?; init(_ v: GraphExpression?) { value = v } }
  private static let cache: NSCache<NSString, Box> = {
    let c = NSCache<NSString, Box>()
    c.countLimit = 256
    return c
  }()

  static func expression(for latex: String) -> GraphExpression? {
    let key = latex as NSString
    if let box = cache.object(forKey: key) { return box.value }
    let parsed = GraphExpression(latex: latex)
    cache.setObject(Box(parsed), forKey: key)
    return parsed
  }
}

/// A two-axis graph card: labeled, tick-marked X and Y axes rendered into the card frame with the
/// same stroke/arrowhead geometry a converted line/arrow carried, so the conversion feels
/// continuous. Everything scales off the frame, so the generic corner-resize just works. Series
/// (expression curves + point markers), a legend, the equation drop-target ring, and — when the
/// card is selected — a hover crosshair/readout layer on top.
struct GraphCardView: View {
  let spec: CardState.GraphSpec
  var tint: Color?
  var isDropTarget: Bool = false
  /// True when the selected live card's interactive overlay draws the ✕-bearing legend, so this
  /// view's read-only legend steps aside. False on the static/export path and unselected cards.
  var interactiveLegend: Bool = false

  // Plot gutters — room for tick labels (left/bottom) and arrowheads (top/right).
  private let leftGutter: CGFloat = GraphGeometry.leftGutter
  private let bottomGutter: CGFloat = GraphGeometry.bottomGutter
  private let topGutter: CGFloat = GraphGeometry.topGutter
  private let rightGutter: CGFloat = GraphGeometry.rightGutter
  private let tickLength: CGFloat = 4
  private let headLength: CGFloat = 15   // matches LineShape

  private var stroke: Color { tint ?? Theme.Palette.elementStroke }

  private var xRange: (min: Double, max: Double) {
    spec.xMax > spec.xMin ? (spec.xMin, spec.xMax) : (spec.xMin, spec.xMin + 10)
  }
  private var yRange: (min: Double, max: Double) {
    spec.yMax > spec.yMin ? (spec.yMin, spec.yMax) : (spec.yMin, spec.yMin + 10)
  }

  private var xTitle: String { Self.axisTitle(label: spec.xLabel, unit: spec.xUnit) }
  private var yTitle: String { Self.axisTitle(label: spec.yLabel, unit: spec.yUnit) }

  /// Resolve a series' tint slot to a color, falling back to the accent (never the card's own stroke,
  /// so an untinted series reads as "a plotted line" distinct from the axes).
  private func seriesColor(_ series: CardState.GraphSeries) -> Color { GraphFormat.seriesColor(series) }

  var body: some View {
    GeometryReader { geo in
      let plot = CGRect(
        x: leftGutter,
        y: topGutter,
        width: max(geo.size.width - leftGutter - rightGutter, 1),
        height: max(geo.size.height - topGutter - bottomGutter, 1))
      let origin = CGPoint(x: plot.minX, y: plot.maxY)
      let xTicks = Self.niceTicks(min: xRange.min, max: xRange.max)
      let yTicks = Self.niceTicks(min: yRange.min, max: yRange.max)

      let geom = GraphGeometry(spec: spec, size: geo.size)

      ZStack {
        // Drop-target: while a parseable equation hovers this graph, the plot rect lightens so the
        // "release here" affordance reads before the accent ring below.
        if isDropTarget {
          Rectangle()
            .fill(Theme.Palette.elementFill.opacity(0.5))
            .frame(width: plot.width, height: plot.height)
            .position(x: plot.midX, y: plot.midY)
            .allowsHitTesting(false)
        }

        // Grid sits behind the axes, clipped to the plot rect.
        if spec.showGrid {
          Path { path in
            for value in xTicks {
              let x = plot.minX + CGFloat((value - xRange.min) / (xRange.max - xRange.min)) * plot.width
              path.move(to: CGPoint(x: x, y: plot.minY))
              path.addLine(to: CGPoint(x: x, y: plot.maxY))
            }
            for value in yTicks {
              let y = plot.maxY - CGFloat((value - yRange.min) / (yRange.max - yRange.min)) * plot.height
              path.move(to: CGPoint(x: plot.minX, y: y))
              path.addLine(to: CGPoint(x: plot.maxX, y: y))
            }
          }
          .stroke(Theme.Palette.panelHairline, lineWidth: 1)
          .clipped()
        }

        // Axes with arrowheads on both ends, matching LineShape's geometry.
        Path { path in
          path.move(to: origin)
          path.addLine(to: CGPoint(x: plot.maxX, y: origin.y))   // X axis
          addArrowHead(to: &path, tip: CGPoint(x: plot.maxX, y: origin.y), angle: 0)
          path.move(to: origin)
          path.addLine(to: CGPoint(x: origin.x, y: plot.minY))   // Y axis
          addArrowHead(to: &path, tip: CGPoint(x: origin.x, y: plot.minY), angle: -.pi / 2)
        }
        .stroke(stroke, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
        .shadow(color: Theme.Palette.elementShadow, radius: 6, y: 3)

        // Tick marks (just outside each axis). Ticks yield to the arrowheads — one that would land
        // under a head is skipped (marks + labels; the grid keeps its line), so the axis title owns
        // that corner instead of piling onto the terminal number.
        Path { path in
          for value in xTicks {
            let x = plot.minX + CGFloat((value - xRange.min) / (xRange.max - xRange.min)) * plot.width
            guard x <= plot.maxX - headLength - 6 else { continue }
            path.move(to: CGPoint(x: x, y: origin.y))
            path.addLine(to: CGPoint(x: x, y: origin.y + tickLength))
          }
          for value in yTicks {
            let y = plot.maxY - CGFloat((value - yRange.min) / (yRange.max - yRange.min)) * plot.height
            guard y >= plot.minY + headLength + 6 else { continue }
            path.move(to: CGPoint(x: origin.x, y: y))
            path.addLine(to: CGPoint(x: origin.x - tickLength, y: y))
          }
        }
        .stroke(stroke, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))

        // Tick labels — muted, monospaced digits.
        ForEach(Array(xTicks.enumerated()), id: \.offset) { _, value in
          let x = plot.minX + CGFloat((value - xRange.min) / (xRange.max - xRange.min)) * plot.width
          if x <= plot.maxX - headLength - 6 {
            tickLabel(value)
              .position(x: x, y: origin.y + tickLength + 7)
          }
        }
        ForEach(Array(yTicks.enumerated()), id: \.offset) { _, value in
          let y = plot.maxY - CGFloat((value - yRange.min) / (yRange.max - yRange.min)) * plot.height
          if y >= plot.minY + headLength + 6 {
            tickLabel(value)
              .frame(width: leftGutter - tickLength - 3, alignment: .trailing)
              .position(x: (leftGutter - tickLength - 3) / 2, y: y)
          }
        }

        // Axis titles sit in the corners the arrowheads freed up: X trailing under its head, Y just
        // right of its head (leading-aligned so the text grows away from the tick-label gutter).
        if !xTitle.isEmpty {
          Text(xTitle)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Theme.Palette.body)
            .lineLimit(1)
            .fixedSize()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .padding(.trailing, 4)
            .padding(.bottom, 2)
            .allowsHitTesting(false)
        }
        if !yTitle.isEmpty {
          Text(yTitle)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Theme.Palette.body)
            .lineLimit(1)
            .fixedSize()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .offset(x: origin.x + 14, y: plot.minY - 8)
            .allowsHitTesting(false)
        }

        // Series: expression curves (clipped to the plot) under their point markers.
        ForEach(spec.series) { series in
          if let latex = series.expression?.trimmingCharacters(in: .whitespacesAndNewlines),
             !latex.isEmpty, let expr = GraphExpressionCache.expression(for: latex) {
            curvePath(expr, geom: geom)
              .stroke(seriesColor(series), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
              .clipShape(Rectangle().path(in: plot))
              .allowsHitTesting(false)
          }
        }
        ForEach(spec.series) { series in
          if let points = series.points {
            let color = seriesColor(series)
            ForEach(Array(points.enumerated()), id: \.offset) { _, point in
              marker(point, color: color)
                .position(geom.viewPoint(point))
                .allowsHitTesting(false)
            }
          }
        }

        // Read-only legend at the plot's top-right, one chip per series. On the selected live card the
        // interactive overlay (in cardBody, above the pointer catcher) draws the ✕-bearing legend
        // instead, so this one steps aside to avoid a double-draw.
        if !spec.series.isEmpty, !interactiveLegend {
          GraphLegend(series: spec.series, color: seriesColor)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .padding(.top, plot.minY + 2)
            .padding(.trailing, rightGutter + 4)
            .allowsHitTesting(false)
        }
      }
    }
    .padding(2)
  }

  /// Sample the expression across the plot width every ~2 view points; break the stroke (move, not
  /// line) at a non-finite value or one more than a plot-height beyond either y-edge, so an asymptote
  /// doesn't draw a vertical spike across the card.
  private func curvePath(_ expr: GraphExpression, geom: GraphGeometry) -> Path {
    Path { path in
      let plot = geom.plot
      var started = false
      var vx = plot.minX
      while vx <= plot.maxX {
        let value = expr.evaluate(geom.dataX(vx))
        let vy = geom.viewY(value)
        let offCard = !value.isFinite || vy < plot.minY - plot.height || vy > plot.maxY + plot.height
        if offCard {
          started = false
        } else if started {
          path.addLine(to: CGPoint(x: vx, y: vy))
        } else {
          path.move(to: CGPoint(x: vx, y: vy))
          started = true
        }
        vx += 2
      }
    }
  }

  /// A point marker: a bare dot when unlabeled, or a numbered/labeled outlined circle (hand-drawn
  /// numbered-event style) that grows to fit its label.
  @ViewBuilder
  private func marker(_ point: CardState.GraphPoint, color seriesColor: Color) -> some View {
    // A per-point tint overrides the series color; nil inherits it.
    let color = Theme.tintColor(point.tint).map { Color(nsColor: $0) } ?? seriesColor
    if point.label.isEmpty {
      Circle()
        .fill(color)
        .frame(width: 11, height: 11)
        .overlay(Circle().strokeBorder(Theme.Palette.elementFill, lineWidth: 2))
    } else {
      let diameter = max(28, CGFloat(point.label.count) * 8 + 14)
      ZStack {
        Circle().fill(Theme.Palette.elementFill)
        Circle().strokeBorder(color, lineWidth: 2)
        Text(point.label)
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(Theme.Palette.body)
          .lineLimit(1)
          .padding(.horizontal, 4)
      }
      .frame(width: diameter, height: diameter)
    }
  }

  private func tickLabel(_ value: Double) -> some View {
    Text(Self.tickText(value))
      .font(.system(size: 9, design: .monospaced))
      .monospacedDigit()
      .foregroundStyle(Theme.Palette.placeholder)
      .lineLimit(1)
      .fixedSize()
  }

  /// The LineShape arrowhead: two segments at ±0.82π off the line angle, `headLength` long.
  private func addArrowHead(to path: inout Path, tip: CGPoint, angle: CGFloat) {
    for side in [CGFloat.pi * 0.82, -CGFloat.pi * 0.82] {
      path.move(to: tip)
      path.addLine(to: CGPoint(x: tip.x + cos(angle + side) * headLength,
                               y: tip.y + sin(angle + side) * headLength))
    }
  }

  private static func axisTitle(label: String, unit: String) -> String {
    let l = label.trimmingCharacters(in: .whitespacesAndNewlines)
    let u = unit.trimmingCharacters(in: .whitespacesAndNewlines)
    if l.isEmpty && u.isEmpty { return "" }
    if u.isEmpty { return l }
    if l.isEmpty { return "(\(u))" }
    return "\(l) (\(u))"
  }

  /// Drop a trailing `.0` so integer ticks read cleanly.
  private static func tickText(_ value: Double) -> String {
    let rounded = (value * 1000).rounded() / 1000
    if rounded == rounded.rounded() { return String(Int(rounded)) }
    return String(format: "%g", rounded)
  }

  /// A "nice" tick sequence (1/2/5 × 10ⁿ step) targeting ~4–6 ticks across the range.
  private static func niceTicks(min lo: Double, max hi: Double) -> [Double] {
    guard hi > lo else { return [lo] }
    let step = niceStep((hi - lo) / 5)
    guard step > 0 else { return [lo, hi] }
    let first = (lo / step).rounded(.up) * step
    var ticks: [Double] = []
    var v = first
    // Guard the loop and cap the count so a degenerate range can't spin.
    while v <= hi + step * 0.001 && ticks.count < 32 {
      ticks.append(v)
      v += step
    }
    return ticks
  }

  private static func niceStep(_ raw: Double) -> Double {
    guard raw > 0 else { return 0 }
    let exponent = floor(log10(raw))
    let base = pow(10, exponent)
    let fraction = raw / base
    let nice: Double = fraction <= 1 ? 1 : (fraction <= 2 ? 2 : (fraction <= 5 ? 5 : 10))
    return nice * base
  }
}

/// Series-color resolution and coordinate/label formatting shared by the plot and its interactive
/// overlay, so a legend chip and a hover readout always agree on color and precision.
enum GraphFormat {
  static func seriesColor(_ series: CardState.GraphSeries) -> Color {
    Theme.tintColor(series.tint).map { Color(nsColor: $0) } ?? Theme.Palette.accent
  }

  /// Format a coordinate to the axis' tick-step precision, appending the unit (space-separated) when
  /// one is set — e.g. `3.2 s`.
  static func coordText(_ value: Double, unit: String, min lo: Double, max hi: Double) -> String {
    let span = hi > lo ? hi - lo : 10
    var text = formatToStep(value, step: niceStep(span / 5))
    let u = unit.trimmingCharacters(in: .whitespacesAndNewlines)
    if !u.isEmpty { text += " \(u)" }
    return text
  }

  private static func formatToStep(_ value: Double, step: Double) -> String {
    guard step > 0 else { return String(format: "%g", value) }
    let decimals = max(0, Int(ceil(-log10(step))))
    let rounded = (value / step).rounded() * step
    if decimals == 0 { return String(Int(rounded.rounded())) }
    return String(format: "%.\(decimals)f", rounded)
  }

  private static func niceStep(_ raw: Double) -> Double {
    guard raw > 0 else { return 0 }
    let exponent = floor(log10(raw))
    let base = pow(10, exponent)
    let fraction = raw / base
    let nice: Double = fraction <= 1 ? 1 : (fraction <= 2 ? 2 : (fraction <= 5 ? 5 : 10))
    return nice * base
  }

  static func legendText(_ label: String) -> String {
    let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count > 18 else { return trimmed }
    return "\(trimmed.prefix(8))…\(trimmed.suffix(8))"
  }
}

/// The legend column: one swatch + middle-truncated label per series, with an optional ✕ (when the
/// card is selected) that drops the series. Read-only inside the plot; interactive in the overlay.
private struct GraphLegend: View {
  let series: [CardState.GraphSeries]
  var color: (CardState.GraphSeries) -> Color
  var onRemove: ((UUID) -> Void)? = nil

  var body: some View {
    VStack(alignment: .trailing, spacing: 3) {
      ForEach(series) { s in
        HStack(spacing: 5) {
          RoundedRectangle(cornerRadius: 1)
            .fill(color(s))
            .frame(width: 14, height: 2)
          Text(GraphFormat.legendText(s.label))
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(Theme.Palette.placeholder)
            .lineLimit(1)
          if let onRemove {
            LegendRemoveButton { onRemove(s.id) }
          }
        }
      }
    }
  }
}

/// The legend chip's ✕: secondary ink, accent on hover. Drops the series without opening a panel.
private struct LegendRemoveButton: View {
  var action: () -> Void
  @State private var hovering = false

  var body: some View {
    Button(action: action) {
      Image(systemName: "xmark")
        .font(.system(size: 8, weight: .bold))
        .foregroundStyle(hovering ? Theme.Palette.accent : Theme.Palette.placeholder)
        .frame(width: 12, height: 12)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
  }
}

/// The selected graph card's interactive layer, hosted in `cardBody` ABOVE the pointer catcher (which
/// owns ⌥-click and marker drags). It draws the ✕-bearing legend (occupying only its top-right corner,
/// so plot-area presses still fall through to the catcher) and a hover crosshair + readout chip. The
/// hover tracker sits under the legend so it never eats the ✕; it does not consume clicks (SwiftUI
/// hover is passive), so the AppKit catcher below still receives every mouse-down in the plot.
private struct GraphInteractionOverlay: View {
  let spec: CardState.GraphSpec
  let board: BoardViewModel
  let graphID: UUID

  @State private var hover: HoverReadout?

  private struct HoverReadout: Equatable {
    var view: CGPoint
    var x: Double
    var y: Double
    var color: Color?
  }

  var body: some View {
    GeometryReader { geo in
      let geom = GraphGeometry(spec: spec, size: CGSize(width: geo.size.width - 4, height: geo.size.height - 4))
      // Shift into the plot's own space (the plot renders inside GraphCardView's 2pt inset).
      ZStack(alignment: .topLeading) {
        if let hover {
          hoverLayer(hover, geom: geom).offset(x: 2, y: 2)
        }
        // Hover tracker fills the plot rect only; `onContinuousHover` is passive so the catcher keeps
        // its clicks. Placed before the legend so the ✕ stays clickable.
        Color.clear
          .contentShape(Rectangle())
          .frame(width: geom.plot.width, height: geom.plot.height)
          .offset(x: geom.plot.minX + 2, y: geom.plot.minY + 2)
          .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case .active(let location):
              let local = CGPoint(x: location.x - 2, y: location.y - 2)
              hover = geom.contains(local) ? readout(at: local, geom: geom) : nil
            case .ended:
              hover = nil
            }
          }
        if !spec.series.isEmpty {
          GraphLegend(series: spec.series, color: GraphFormat.seriesColor,
                      onRemove: { board.removeGraphSeries(graphID, seriesID: $0) })
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .padding(.top, geom.plot.minY + 2 + 2)
            .padding(.trailing, GraphGeometry.rightGutter + 4 + 2)
        }
      }
    }
  }

  /// Snap the raw pointer to the nearest expression curve (within 8 view points vertically) or marker
  /// (within 10 view points), else read the raw data coordinate.
  private func readout(at location: CGPoint, geom: GraphGeometry) -> HoverReadout {
    var best: (distance: CGFloat, readout: HoverReadout)?
    func consider(_ candidate: HoverReadout, distance: CGFloat, limit: CGFloat) {
      guard distance <= limit else { return }
      if best == nil || distance < best!.distance { best = (distance, candidate) }
    }
    for series in spec.series {
      let color = GraphFormat.seriesColor(series)
      if let latex = series.expression?.trimmingCharacters(in: .whitespacesAndNewlines),
         !latex.isEmpty, let expr = GraphExpressionCache.expression(for: latex) {
        let value = expr.evaluate(geom.dataX(location.x))
        if value.isFinite {
          let vy = geom.viewY(value)
          consider(HoverReadout(view: CGPoint(x: location.x, y: vy),
                                x: geom.dataX(location.x), y: value, color: color),
                   distance: abs(vy - location.y), limit: 8)
        }
      }
      for point in series.points ?? [] {
        let vp = geom.viewPoint(point)
        // A per-point tint colors this marker's readout; nil inherits the series color.
        let pointColor = Theme.tintColor(point.tint).map { Color(nsColor: $0) } ?? color
        consider(HoverReadout(view: vp, x: point.x, y: point.y, color: pointColor),
                 distance: hypot(vp.x - location.x, vp.y - location.y), limit: 14)
      }
    }
    if let best { return best.readout }
    return HoverReadout(view: location, x: geom.dataX(location.x), y: geom.dataY(location.y), color: nil)
  }

  @ViewBuilder
  private func hoverLayer(_ readout: HoverReadout, geom: GraphGeometry) -> some View {
    let plot = geom.plot
    Path { path in
      path.move(to: CGPoint(x: plot.minX, y: readout.view.y))
      path.addLine(to: CGPoint(x: plot.maxX, y: readout.view.y))
      path.move(to: CGPoint(x: readout.view.x, y: plot.minY))
      path.addLine(to: CGPoint(x: readout.view.x, y: plot.maxY))
    }
    .stroke(Theme.Palette.panelHairline, lineWidth: 1)
    .clipShape(Rectangle().path(in: plot))
    .allowsHitTesting(false)

    let text = "(\(GraphFormat.coordText(readout.x, unit: spec.xUnit, min: spec.xMin, max: spec.xMax)), " +
               "\(GraphFormat.coordText(readout.y, unit: spec.yUnit, min: spec.yMin, max: spec.yMax)))"
    let flipX = readout.view.x > plot.maxX - 90
    let flipY = readout.view.y < plot.minY + 26
    Text(text)
      .font(.system(size: 10, design: .monospaced))
      .foregroundStyle(readout.color ?? Theme.Palette.body)
      .padding(.horizontal, 7)
      .padding(.vertical, 4)
      .composerPopupSurface()
      .fixedSize()
      .alignmentGuide(.leading) { d in flipX ? d.width : 0 }
      .alignmentGuide(.top) { d in flipY ? 0 : d.height }
      .position(x: readout.view.x + (flipX ? -12 : 12),
                y: readout.view.y + (flipY ? 12 : -12))
      .allowsHitTesting(false)
  }
}

/// The ⌥-click Point Composer's editable state: X/Y as raw field text (so a mid-edit value never
/// fights the field), a label, and a tint slot. `seed` remembers the click's coordinates so a
/// half-typed field falls back to them on commit rather than to zero.
private struct PointComposerDraft: Equatable {
  var xText = ""
  var yText = ""
  var label = ""
  /// Per-point tint slot into the active flavor's tints; nil inherits the series color.
  var tint: Int? = nil
  private var seedX: Double = 0
  private var seedY: Double = 0

  init() {}

  init(seed: CardState.GraphPoint) {
    seedX = seed.x
    seedY = seed.y
    xText = PointComposerDraft.format(seed.x)
    yText = PointComposerDraft.format(seed.y)
  }

  /// Resolve to a point — a non-numeric X or Y falls back to the seeded coordinate, so a half-typed
  /// field never commits a broken point.
  func resolved() -> CardState.GraphPoint {
    let x = Double(xText.trimmingCharacters(in: .whitespaces)) ?? seedX
    let y = Double(yText.trimmingCharacters(in: .whitespaces)) ?? seedY
    return CardState.GraphPoint(x: x, y: y,
                                label: label.trimmingCharacters(in: .whitespacesAndNewlines),
                                tint: tint)
  }

  private static func format(_ value: Double) -> String {
    value == value.rounded() ? String(Int(value)) : String(format: "%g", value)
  }
}

/// The shared glass-strip field chrome (segmented fill + hairline border), so the config popover, the
/// Point Composer, and the draft point rows all wear the exact same field.
private struct GraphFieldChrome: ViewModifier {
  func body(content: Content) -> some View {
    content
      .textFieldStyle(.plain)
      .font(.system(size: 12))
      .foregroundStyle(Theme.Palette.body)
      .padding(.horizontal, 8)
      .padding(.vertical, 5)
      .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
        .fill(Theme.Palette.segmentedFill))
      .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
        .strokeBorder(Theme.Palette.panelHairline, lineWidth: 1))
  }
}

private extension View {
  func graphFieldChrome() -> some View { modifier(GraphFieldChrome()) }
}

/// A tap-to-pick tint swatch row for a data point: a neutral "series default" swatch (nil) followed by
/// each of the active flavor's tint slots — mirroring the selection bar's enumeration. The selected
/// swatch wears an accent ring.
private struct PointTintSwatchRow: View {
  @Binding var tint: Int?

  var body: some View {
    HStack(spacing: 6) {
      swatch(nil)
      ForEach(Theme.flavor.tints.indices, id: \.self) { slot in
        swatch(slot)
      }
    }
  }

  private func swatch(_ slot: Int?) -> some View {
    Button(action: { tint = slot }) {
      swatchCircle(slot, selected: tint == slot)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(slot == nil ? "Series default".localizedUI : "Theme color %d".localizedUI((slot ?? 0) + 1))
  }

  /// A 14pt swatch. The "series default" (nil) reads as a neutral outlined ring; each slot fills with
  /// its resolved tint. The active pick gets an accent ring just outside.
  @ViewBuilder
  private func swatchCircle(_ slot: Int?, selected: Bool) -> some View {
    let fill = Theme.tintColor(slot).map { Color(nsColor: $0) }
    Circle()
      .fill(fill ?? Color.clear)
      .frame(width: 14, height: 14)
      .overlay(Circle().strokeBorder(fill == nil ? Theme.Palette.placeholder : Theme.Palette.panelHairline, lineWidth: 1))
      .overlay(
        Circle()
          .strokeBorder(selected ? Theme.Palette.accent : Color.clear, lineWidth: 1.5)
          .frame(width: 20, height: 20)
      )
      .frame(width: 20, height: 20)
  }
}

/// The ⌥-click Point Composer strip: one row of X/Y/label fields, a tint swatch row, and an accent
/// "Add Point" confirm. The label field is focused on open (the coords are usually already right).
/// Return commits, Esc cancels. Same glass recipe/metrics as `GraphConfigStrip`.
private struct PointComposerStrip: View {
  @Binding var draft: PointComposerDraft
  let width: CGFloat
  var onCommit: () -> Void
  var onCancel: () -> Void

  @FocusState private var labelFocused: Bool

  private var labelFont: Font { .system(size: 12, weight: .medium) }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 6) {
        Text("X").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.Palette.placeholder)
        TextField("0", text: $draft.xText).graphFieldChrome().onSubmit(onCommit).frame(width: 52)
        Text("Y").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.Palette.placeholder)
        TextField("0", text: $draft.yText).graphFieldChrome().onSubmit(onCommit).frame(width: 52)
        TextField("label".localizedUI, text: $draft.label)
          .graphFieldChrome().onSubmit(onCommit)
          .focused($labelFocused)
          .frame(width: 70)
        Spacer(minLength: 0)
      }
      HStack(spacing: 8) {
        PointTintSwatchRow(tint: $draft.tint)
        Spacer()
        Button(action: onCommit) {
          Text("Add Point".localizedUI)
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
    .onAppear { DispatchQueue.main.async { labelFocused = true } }
  }
}

private struct ImageObjectPlaceholder: View {
  let path: String?
  @State private var image: NSImage?
  /// When set (offscreen PNG export), image decoding is synchronous: `ImageRenderer` never runs
  /// the async `.task`, so the on-canvas placeholder would be captured instead of the picture.
  /// The provider hands back a fully-decoded `NSImage` for `path` on the spot.
  @Environment(\.exportImageProvider) private var exportImageProvider

  /// The image to draw. During export it resolves synchronously from the provider; on the live
  /// canvas it's the async-loaded thumbnail held in `@State`.
  private var resolvedImage: NSImage? {
    if let exportImageProvider, let path { return exportImageProvider(path) }
    return image
  }

  var body: some View {
    Group {
      if let image = resolvedImage {
      Image(nsImage: image)
        .resizable()
        .scaledToFill()
        // Clamp to the card frame so `scaledToFill` fills-and-crops within the card instead of
        // overflowing it — the image's rounded border (and the selection ring) then hug the frame.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
          .strokeBorder(Theme.Palette.panelHairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
      } else {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(Theme.Palette.elementFill)
          .overlay {
            VStack(spacing: 8) {
              Image(systemName: "photo")
                .font(.system(size: 24, weight: .medium))
              Text(path.map { ($0 as NSString).lastPathComponent } ?? "Image".localizedUI)
                .font(.caption.weight(.medium))
                .lineLimit(1)
            }
            .foregroundStyle(Theme.Palette.chromeText)
            .padding(10)
          }
          .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(Theme.Palette.chromeDivider, style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])))
          .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
      }
    }
    // `.task(id:)` runs on appear AND whenever `path` changes, and is cancelled on disappear — so a
    // card reloaded from a saved board (or culled and re-added while panning) reliably re-decodes,
    // instead of the old `.onAppear` + stored-path guard silently dropping the result.
    .task(id: path) {
      // Export resolves synchronously through the provider — no async decode needed.
      guard exportImageProvider == nil else { return }
      guard let path else { image = nil; return }
      let loaded: NSImage? = await withCheckedContinuation { continuation in
        CanvasImageCache.shared.load(path: path) { continuation.resume(returning: $0) }
      }
      if !Task.isCancelled { image = loaded }
    }
  }
}

/// Offscreen-export hook: when present, image cards resolve their picture synchronously from this
/// closure instead of the async `CanvasImageCache`, so a one-shot `ImageRenderer` capture shows the
/// real image rather than the loading placeholder. Nil on the live canvas — normal async loading.
private struct ExportImageProviderKey: EnvironmentKey {
  static let defaultValue: ((String) -> NSImage?)? = nil
}

extension EnvironmentValues {
  var exportImageProvider: ((String) -> NSImage?)? {
    get { self[ExportImageProviderKey.self] }
    set { self[ExportImageProviderKey.self] = newValue }
  }
}

// MARK: - Equation (LaTeX) rendering

/// A LaTeX math-mode equation, typeset natively by SwiftMath (CoreText, not a web view) into an
/// NSImage that fills the card aspect-fit. Ink is the card's tint (or board body ink); an empty
/// card shows a hint, and unparseable source falls back to the raw LaTeX rather than a blank card.
struct EquationView: View {
  /// Raw math-mode source — no `$` delimiters (that's what `CardState.latex` stores).
  let latex: String
  /// The card's tint resolved against the active flavor, or nil for default body ink.
  var tint: Color?
  /// Board zoom — quantized before it reaches the renderer so a pinch doesn't re-typeset per frame.
  var zoom: CGFloat = 1

  /// Base display size at 100%; scales with the quantized zoom like the text body does.
  private static let baseFontSize: CGFloat = 24

  /// Zoom snapped to 0.25 steps and clamped 0.25…4. Deliberate: the render is keyed off this, so
  /// it re-typesets only when you cross a step (crisp at rest) instead of on every pinch frame.
  private var quantizedZoom: CGFloat {
    min(max((zoom / 0.25).rounded() * 0.25, 0.25), 4)
  }
  private var fontSize: CGFloat { Self.baseFontSize * quantizedZoom }

  /// The ink as an NSColor — the flavor's tint slots are already NSColors, and body ink has an
  /// NSColor twin. Never a hard-coded color, so both light and dark flavors read correctly.
  private var inkColor: NSColor {
    tint.map { NSColor($0) } ?? Theme.nsBodyText
  }

  private var trimmed: String { latex.trimmingCharacters(in: .whitespacesAndNewlines) }

  var body: some View {
    Group {
      if trimmed.isEmpty {
        // An empty equation card awaiting input — same placeholder weight as the text card's hint.
        Text("E = mc\u{00B2}")
          .font(.system(size: Theme.Typography.body.pointSize * zoom))
          .foregroundStyle(Theme.Palette.placeholder)
      } else if let image = EquationImageCache.shared.image(latex: trimmed, ink: inkColor, fontSize: fontSize) {
        Image(nsImage: image)
          .resizable()
          .aspectRatio(contentMode: .fit)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .padding(10)
      } else {
        // Parse failure: show the raw source (never crash, never blank) with a warning glyph.
        HStack(alignment: .firstTextBaseline, spacing: 4 * zoom) {
          Image(systemName: "exclamationmark.triangle")
            .font(.system(size: 11 * zoom))
          Text(trimmed)
            .font(.system(size: 12 * zoom, design: .monospaced))
            .lineLimit(3)
        }
        .foregroundStyle(Theme.Palette.placeholder)
        .padding(10)
        .help("LaTeX didn't parse".localizedUI)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

/// A bounded cache of rendered equation images, modeled on `CanvasImageCache`. Keyed by
/// latex + resolved-ink + quantized font size: theme switches rebuild the canvas so stale-flavor
/// entries are naturally abandoned, but the ink is in the key so a live tint change still
/// re-renders. Rendering is cheap and synchronous (CoreText), so unlike the thumbnail cache this
/// one renders on the calling thread and just memoizes the result.
private final class EquationImageCache {
  static let shared = EquationImageCache()
  private let cache = NSCache<NSString, NSImage>()

  private init() {
    cache.countLimit = 256
  }

  /// The rendered image, or nil if the LaTeX doesn't parse (an empty string never reaches here).
  func image(latex: String, ink: NSColor, fontSize: CGFloat) -> NSImage? {
    // Include ink components (not just the object) so a tint change re-renders; fontSize is already
    // quantized by the caller, so the key is stable at rest.
    let inkKey = ink.usingColorSpace(.deviceRGB) ?? ink
    let key = "\(fontSize)|\(inkKey.redComponent),\(inkKey.greenComponent),\(inkKey.blueComponent),\(inkKey.alphaComponent)|\(latex)" as NSString
    if let cached = cache.object(forKey: key) { return cached }
    guard let image = Self.render(latex: latex, ink: ink, fontSize: fontSize) else { return nil }
    cache.setObject(image, forKey: key)
    return image
  }

  /// Typeset at 2× the target size for Retina crispness (the view aspect-fits it back down).
  private static func render(latex: String, ink: NSColor, fontSize: CGFloat) -> NSImage? {
    let mathImage = MTMathImage(latex: latex, fontSize: fontSize * 2, textColor: ink,
                                labelMode: .display, textAlignment: .center)
    let (error, image) = mathImage.asImage()
    guard error == nil, let image, image.size.width > 0, image.size.height > 0 else { return nil }
    return image
  }
}

/// A bounded, asynchronous thumbnail cache. The previous cache kept the full source image for
/// every visited card and decoded it synchronously from `body`, which made panning into a board
/// of large screenshots both a main-thread hitch and an unbounded memory grower.
private final class CanvasImageCache {
  static let shared = CanvasImageCache()
  private let cache = NSCache<NSString, NSImage>()
  private let decodeQueue = DispatchQueue(label: "dev.jow.Composer.canvas-image-decode", qos: .userInitiated)
  private var pending: [String: [(NSImage?) -> Void]] = [:]

  private static let maximumPixelDimension = 1_536

  private init() {
    cache.countLimit = 48
    cache.totalCostLimit = 48 * 1_024 * 1_024
  }

  func load(path: String, completion: @escaping (NSImage?) -> Void) {
    let key = path as NSString
    if let cached = cache.object(forKey: key) {
      completion(cached)
      return
    }
    if pending[path] != nil {
      pending[path, default: []].append(completion)
      return
    }
    pending[path] = [completion]
    decodeQueue.async { [weak self] in
      let decoded = Self.decodeThumbnail(at: path)
      DispatchQueue.main.async {
        guard let self else { return }
        if let image = decoded?.image {
          self.cache.setObject(image, forKey: key, cost: decoded?.cost ?? 0)
        }
        let callbacks = self.pending.removeValue(forKey: path) ?? []
        callbacks.forEach { $0(decoded?.image) }
      }
    }
  }

  private static func decodeThumbnail(at path: String) -> (image: NSImage, cost: Int)? {
    guard let url = AssetStore.resolve(path) else { return nil }
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: maximumPixelDimension,
      kCGImageSourceShouldCacheImmediately: true,
    ]
    guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
    let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    return (image, cgImage.bytesPerRow * cgImage.height)
  }
}

// MARK: - Immediate pointer catcher

private struct CardPointerCatcher: NSViewRepresentable {
  /// How a press was handled: `.passthrough` runs the normal select/move gesture, `.consumed`
  /// swallows the click (⌥-click on a graph — no select/move/drag), `.marker` swallows select/move
  /// but routes subsequent drags to the marker-drag callbacks instead of the card move.
  enum PressDisposition { case passthrough, consumed, marker }

  var onPress: (EventModifiers, CGPoint) -> PressDisposition
  var onDoubleClick: () -> Void
  var onDragChanged: (CGSize) -> Void
  var onDragEnded: (CGSize) -> Void
  var onMarkerDrag: (CGPoint) -> Void = { _ in }
  var onMarkerDragEnded: () -> Void = {}

  func makeNSView(context: Context) -> CatcherView {
    let view = CatcherView()
    view.callbacks = callbacks
    return view
  }

  func updateNSView(_ nsView: CatcherView, context: Context) {
    nsView.callbacks = callbacks
  }

  private var callbacks: CatcherView.Callbacks {
    CatcherView.Callbacks(
      onPress: onPress,
      onDoubleClick: onDoubleClick,
      onDragChanged: onDragChanged,
      onDragEnded: onDragEnded,
      onMarkerDrag: onMarkerDrag,
      onMarkerDragEnded: onMarkerDragEnded
    )
  }

  final class CatcherView: NSView {
    struct Callbacks {
      var onPress: (EventModifiers, CGPoint) -> PressDisposition = { _, _ in .passthrough }
      var onDoubleClick: () -> Void = {}
      var onDragChanged: (CGSize) -> Void = { _ in }
      var onDragEnded: (CGSize) -> Void = { _ in }
      var onMarkerDrag: (CGPoint) -> Void = { _ in }
      var onMarkerDragEnded: () -> Void = {}
    }

    var callbacks = Callbacks()
    /// Drag origin in WINDOW space. The catcher lives inside the card's own moving/scaling
    /// layer, so reading translation in its local space feeds the move back into itself and the
    /// card jitters (and leaves ghost trails). Window space stays put as the card moves.
    private var dragStart: NSPoint?
    private var lastTranslation: CGSize = .zero
    /// A small dead-zone so a click with a touch of jitter doesn't read as a move.
    private var passedThreshold = false
    /// Set when the press was consumed (⌥-click) or armed a marker drag — the normal card move is
    /// suppressed for the whole gesture, and drags route to the marker-drag callbacks when `.marker`.
    private var disposition: PressDisposition = .passthrough

    override var isFlipped: Bool { true }

    // While Space is held the whole board pans, starting anywhere — including over a card. Going
    // transparent to hit-testing here lets the press fall through to the viewport's pan handler
    // instead of this catcher grabbing it (which killed space-pan wherever a card sat).
    override func hitTest(_ point: NSPoint) -> NSView? {
      CanvasKeyState.shared.isSpaceDown ? nil : super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
      let local = convert(event.locationInWindow, from: nil)
      dragStart = event.locationInWindow
      lastTranslation = .zero
      passedThreshold = false
      disposition = callbacks.onPress(EventModifiers(event.modifierFlags), local)
      // A consumed press (⌥-click) is a one-shot: no drag, no double-click.
      if disposition == .consumed { dragStart = nil; return }
      if event.clickCount >= 2 {
        dragStart = nil
        callbacks.onDragChanged(.zero)
        callbacks.onDoubleClick()
      }
    }

    override func mouseDragged(with event: NSEvent) {
      guard let dragStart else { return }
      let p = event.locationInWindow
      if !passedThreshold {
        guard hypot(p.x - dragStart.x, p.y - dragStart.y) >= 4 else { return }
        passedThreshold = true
      }
      if disposition == .marker {
        callbacks.onMarkerDrag(convert(p, from: nil))
        return
      }
      // Window y is up; the board is y-down, so negate dy. Divided by zoom downstream.
      let translation = CGSize(width: p.x - dragStart.x, height: dragStart.y - p.y)
      lastTranslation = translation
      callbacks.onDragChanged(translation)
    }

    override func mouseUp(with event: NSEvent) {
      guard dragStart != nil else { return }
      dragStart = nil
      passedThreshold = false
      if disposition == .marker {
        callbacks.onMarkerDragEnded()
        disposition = .passthrough
        return
      }
      callbacks.onDragEnded(lastTranslation)
      callbacks.onDragChanged(.zero)
      lastTranslation = .zero
    }

    // A non-editing card sits above the board's scroll surface, so without these the cursor
    // hovering a card would dead-end two-finger scroll / pinch. Forward them to the canvas so
    // panning and zooming work everywhere; the card is still draggable once you grab it.
    override func scrollWheel(with event: NSEvent) {
      NotificationCenter.default.post(
        name: .composerCanvasScroll, object: nil,
        userInfo: ["dx": event.scrollingDeltaX, "dy": event.scrollingDeltaY])
    }

    // Pinch-zoom is handled board-wide by PinchZoomCatcher's event monitor, so cards don't need to
    // forward magnify (which anchored inconsistently at the viewport center).
  }
}

// MARK: - Corner geometry

private enum Corner: CaseIterable, Hashable {
  case topLeading, topTrailing, bottomLeading, bottomTrailing

  func point(in size: CGSize) -> CGPoint {
    switch self {
    case .topLeading: CGPoint(x: 0, y: 0)
    case .topTrailing: CGPoint(x: size.width, y: 0)
    case .bottomLeading: CGPoint(x: 0, y: size.height)
    case .bottomTrailing: CGPoint(x: size.width, y: size.height)
    }
  }

  /// The diagonal resize cursor for this corner. `NSCursor.frameResize(position:directions:)` is
  /// macOS 15+, so older systems fall back to a crosshair rather than the (nonexistent) diagonal.
  var resizeCursor: NSCursor {
    if #available(macOS 15.0, *) {
      let position: NSCursor.FrameResizePosition = {
        switch self {
        case .topLeading: .topLeft
        case .topTrailing: .topRight
        case .bottomLeading: .bottomLeft
        case .bottomTrailing: .bottomRight
        }
      }()
      return NSCursor.frameResize(position: position, directions: .all)
    }
    return .crosshair
  }
}

private struct ResizeSession: Equatable {
  let corner: Corner
  var translation: CGSize
}

private enum HorizontalEdge: CaseIterable, Hashable {
  case leading, trailing
}

private struct TextWidthResizeSession: Equatable {
  let edge: HorizontalEdge
  var translation: CGSize
}

private extension EventModifiers {
  init(_ flags: NSEvent.ModifierFlags) {
    var modifiers: EventModifiers = []
    if flags.contains(.shift) { modifiers.insert(.shift) }
    if flags.contains(.command) { modifiers.insert(.command) }
    if flags.contains(.option) { modifiers.insert(.option) }
    if flags.contains(.control) { modifiers.insert(.control) }
    self = modifiers
  }
}
