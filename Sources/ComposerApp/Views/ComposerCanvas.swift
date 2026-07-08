import AppKit
import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// The entire app surface: a pan/zoom board of text cards on a chromeless glass card, with a
/// top tool toolbar and a left action rail floating in the gutters. Per-card editor chrome
/// (mentions, connector search, the semantic linter) is routed to the active card; board-level
/// actions (Compile, Copy) span every card.
struct ComposerCanvas: View {
  @StateObject private var store = DumpStore.shared
  @StateObject private var board = BoardViewModel()
  @ObservedObject private var engineCapabilities = EngineCapabilityStore.shared
  @ObservedObject private var userFacingErrors = UserFacingErrorStore.shared

  @State private var tool: CanvasTool = .select
  @State private var isWorking = false
  @State private var toast: Toast?
  @State private var lastViewportSize: CGSize = .zero
  @State private var selectionRect: CGRect?
  /// True while an EXTERNAL image drag (Finder etc.) is hovering the canvas — drives the
  /// drop-target treatment. In-canvas card drags never set this (onDrop's isTargeted only
  /// fires for external content).
  @State private var isImageDropTargeted = false
  @State private var freehandDraft: [CGPoint]?
  @State private var elementDraft: DragSegment?
  /// While drawing a line/arrow, the card its live end will bind to on release — highlighted so the
  /// bind is visible before commit. Shares `board.bindCandidate` with the commit path, so the
  /// preview and the actual binding can never disagree.
  @State private var bindTargetID: UUID?
  @State private var isSpacePressed = false
  @State private var viewportThrottle = ViewportEventThrottle()
  /// Observed for the agent's *coarse* state (isRunning / grounding) so the toolbar and ⌘K palette
  /// stay in sync. The streaming transcript lives on `agent.transcript`, which the canvas does NOT
  /// observe, so per-token updates re-render only the dock — never the board.
  @ObservedObject private var agent = CanvasAgent.shared
  @ObservedObject private var updater = UpdaterController.shared
  @State private var showAgent = false
  /// The ⌘K command palette (board switcher + buried board-level actions) is showing.
  @State private var showPalette = false
  /// The tint swatch row in the bottom bar is expanded.
  @State private var tintPickerOpen = false
  /// The board picker opens on hover; a short grace timer stops it flickering while the pointer
  /// crosses the gap between the pill and the list. While a row is renaming or confirming a
  /// delete, the panel is pinned open regardless of hover.
  @State private var boardPickerOpen = false
  @State private var boardPickerPinned = false
  @State private var boardPickerCloseWork: DispatchWorkItem?
  /// The export pill grows on hover into a list of export formats (same mechanic as the board
  /// picker). Open immediate, close deferred so the glyph→row gap doesn't flicker.
  @State private var exportMenuOpen = false
  @State private var exportMenuCloseWork: DispatchWorkItem?
  /// Measured rest-label width of the Export pill; its expanded list pins to this so hovering
  /// only grows the surface downward, never sideways. (The board picker uses the fixed
  /// `WindowChrome.boardPillWidth` instead — its label length varies with the board name.)
  @State private var exportRestWidth: CGFloat = 0
  /// Inline rename of the CURRENT board, entered from the title row's secondary-click menu.
  /// While editing, the picker pins open so hover-out can't close it mid-edit.
  @State private var renamingCurrentBoard = false
  @State private var currentBoardDraft = ""
  @FocusState private var currentBoardNameFocused: Bool
  /// The card that held the caret when the palette was summoned, captured before the palette's
  /// search field steals first responder — so a cancel can hand editing back to it.
  @State private var paletteReturnCardID: UUID?

  // Board transform. Pointer locations are normalized back into board space so selection,
  // placement, and dragging keep working at every zoom level.
  @State private var scale: CGFloat = 1
  @State private var pan: CGSize = .zero
  @State private var panLive: CGSize = .zero

  /// The ⇧⌘F writing sheet's card. Separate from `editingCardID` on purpose: text edits inline on
  /// the board; the centered sheet is an explicit summon, not what double-click does.
  @State private var focusedCardID: UUID?

  /// The promotion seam's one live offer (freehand→shape, text→equation/cards, axes→graph) — the
  /// floating chip near the recognized card. At most one at a time; nil hides the chip. Armed at the
  /// human-gesture hooks (freehand/draw commit, edit end, single selection) and dismissed on any new
  /// gesture, selection change, undo/redo, board switch, or Esc — plus the auto-dismiss timer below.
  @State private var promotion: PromotionOffer?
  /// The 6s auto-dismiss for the live chip; invalidated whenever the offer changes or clears so a
  /// stale timer can never retract a newer chip.
  @State private var promotionDismissWork: DispatchWorkItem?
  /// A pending intent to open the label stage straight in graph-config mode (axes→graph promotion),
  /// consumed by `EditingStage` on appear then cleared.
  @State private var openGraphConfigCardID: UUID?

  private let service = HeadlessPromptService()
  private let cardPasteboardType = NSPasteboard.PasteboardType("dev.jow.Composer.cards")

  private var effectiveScale: CGFloat { scale }

  var body: some View {
    GeometryReader { proxy in canvasRoot(proxy: proxy) }
    .ignoresSafeArea()
    .animation(Theme.Motion.accessory, value: isWorking)
    .animation(Theme.Motion.accessory, value: store.isHistoryOpen)
    .animation(Theme.Motion.accessory, value: store.compiledDraft)
    .animation(Theme.Motion.accessory, value: showPalette)
    .onChange(of: userFacingErrors.latest) { _, notice in
      if notice != nil { showLatestReportedError() }
    }
    .onChange(of: isWorking) { _, working in
      NotificationCenter.default.post(name: .composerBusyChanged, object: nil, userInfo: ["busy": working])
    }
  }

  @ViewBuilder
  private func canvasRoot(proxy: GeometryProxy) -> some View {
    let inner = proxy.size
    ZStack(alignment: .topLeading) {
      ZStack(alignment: .topLeading) {
        ComposerPanelBackground()
        boardContent(viewportSize: inner)
        compiledOverlay
        toastView
      }
      .frame(width: inner.width, height: inner.height, alignment: .topLeading)

      // Active-card overlays resolve through screen → window space, so they live in
      // full-window coordinates and keep working while the board itself is transformed.
      if let editing = board.editingInteraction {
        ActiveCardOverlays(
          card: editing,
          size: proxy.size,
          isWorking: isWorking,
          currentTint: board.cards.first(where: { $0.id == editing.id })?.tint,
          onRefine: { refineSelection($0, card: editing) },
          onFormat: { editing.controller.applyMarkdown($0) },
          onTint: { slot in
            // A live text selection inks just that range; a bare caret falls back to whole-card tint.
            if editing.controller.applyInk(slot) {
              board.noteInkChanged(cardID: editing.id)
            } else {
              board.setTint(slot, for: editing.id)
            }
          },
          onApplyFix: { editing.controller.applyLintFix(range: $0.range, expecting: $0.phrase, with: $1) },
          askEngine: resolvedChatEngine(),
          onEscalate: { askAgent(about: $0, card: editing) }
        )
        .id(editing.id)
      }

      // Floating chrome: board identity top-left (the pill IS the board manager), agent top-right,
      // everything hands-on (tools, zoom, settings) in one bottom command bar.
      // The promotion chip floats above the cards but below the command bar/pills and the agent dock
      // — it's a whisper over the canvas, not chrome that competes with the tools.
      promotionOverlay(in: inner)
      boardSwitcherPill(in: proxy.size)
      boardActionsPill(in: proxy.size)
      bottomCommandBar(fit: inner)
      dockOverlay(in: proxy.size)
      editingStageOverlay(in: proxy.size)
      commandPaletteOverlay(in: proxy.size)
      commandBridge
    }
    .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
    .onAppear {
      lastViewportSize = inner
      enterEditingForEntry()
      CanvasBridge.shared.register(board)
      showLatestReportedError()
      for text in CaptureInbox.shared.drainPending() {
        ingestQuickCapture(text)
      }
    }
    .onChange(of: inner) { _, value in lastViewportSize = value }
    // Promotion lifecycle: a tool change starts a fresh intent, so any live chip is stale.
    .onChange(of: tool) { _, _ in dismissPromotion() }
    // Editing a card owns the screen; while a stage is open the chip must not hover behind it. When
    // a text card's edit session ENDS (editingCardID → nil), evaluate it for a text promotion.
    .onChange(of: board.editingCardID) { previous, current in
      if current != nil { dismissPromotion() }
      else if let previous { evaluateTextPromotion(previous) }
    }
    // Selection change away from the offer's card retracts it; a single text selection can arm one.
    .onChange(of: board.selectedCardIDs) { _, _ in promotionSelectionChanged() }
  }

  // MARK: Board content (pan / zoom / place)

  private var commandBridge: some View {
    ZStack {
      navigationCommandBridge
      boardEditCommandBridge
      zoomCommandBridge
      spaceKeyBridge
    }
    .frame(width: 0, height: 0)
  }

  private var commandAnchor: some View {
    Color.clear.frame(width: 0, height: 0)
  }

  private var navigationCommandBridge: some View {
    commandAnchor
      .onReceive(NotificationCenter.default.publisher(for: .composerCompileBoard)) { _ in runCompile() }
      .onReceive(NotificationCenter.default.publisher(for: .composerShowSettings)) { _ in openSettings() }
      .onReceive(NotificationCenter.default.publisher(for: .composerCaptureCompleted)) { note in
        guard let path = note.userInfo?["path"] as? String else { return }
        addCapturedImage(path: path)
      }
      .onReceive(NotificationCenter.default.publisher(for: .composerPrevDump)) { _ in handlePrevDump() }
      .onReceive(NotificationCenter.default.publisher(for: .composerNextDump)) { _ in handleNextDump() }
      .onReceive(NotificationCenter.default.publisher(for: .composerNewDump)) { _ in handleNewDump() }
  }

  private var boardEditCommandBridge: some View {
    commandAnchor
      .onReceive(NotificationCenter.default.publisher(for: .composerDeleteSelection)) { _ in handleDeleteSelection() }
      .onReceive(NotificationCenter.default.publisher(for: .composerDuplicateSelection)) { _ in handleDuplicateSelection() }
      .onReceive(NotificationCenter.default.publisher(for: .composerCopySelection)) { _ in handleCopySelection() }
      .onReceive(NotificationCenter.default.publisher(for: .composerPasteSelection)) { _ in handlePasteSelection() }
      .onReceive(NotificationCenter.default.publisher(for: .composerSelectAllCards)) { _ in handleSelectAllCards() }
      .onReceive(NotificationCenter.default.publisher(for: .composerEscapeBoard)) { _ in handleEscapeBoard() }
      .onReceive(NotificationCenter.default.publisher(for: .composerUndoBoard)) { _ in handleUndoBoard() }
      .onReceive(NotificationCenter.default.publisher(for: .composerRedoBoard)) { _ in handleRedoBoard() }
      .onReceive(NotificationCenter.default.publisher(for: .composerGroupSelection)) { _ in handleGroupSelection() }
      .onReceive(NotificationCenter.default.publisher(for: .composerUngroupSelection)) { _ in handleUngroupSelection() }
      .onReceive(NotificationCenter.default.publisher(for: .composerLockSelection)) { _ in handleLockSelection() }
      .onReceive(NotificationCenter.default.publisher(for: .composerUnlockSelection)) { _ in handleUnlockSelection() }
  }

  private var zoomCommandBridge: some View {
    commandAnchor
      .onReceive(NotificationCenter.default.publisher(for: .composerZoomOut)) { _ in zoom(0.8, anchoredAt: zoomAnchor) }
      .onReceive(NotificationCenter.default.publisher(for: .composerZoomIn)) { _ in zoom(1.25, anchoredAt: zoomAnchor) }
      .onReceive(NotificationCenter.default.publisher(for: .composerZoomReset)) { _ in withAnimation(Theme.Motion.accessory) { scale = 1 } }
      .onReceive(NotificationCenter.default.publisher(for: .composerZoomFit)) { note in
        let all = (note.userInfo?["scope"] as? String) == "all"
        withAnimation(Theme.Motion.accessory) { fitBoard(in: lastViewportSize, forceAll: all) }
      }
  }

  private var spaceKeyBridge: some View {
    commandAnchor
      .onReceive(NotificationCenter.default.publisher(for: .composerSpaceKeyChanged)) { notification in
        handleSpaceKey(notification)
      }
      // Scroll / pinch forwarded from a card under the cursor — keep the board panning & zooming.
      .onReceive(NotificationCenter.default.publisher(for: .composerCanvasScroll)) { note in
        let dx = (note.userInfo?["dx"] as? CGFloat) ?? 0
        let dy = (note.userInfo?["dy"] as? CGFloat) ?? 0
        handleScroll(CGSize(width: dx, height: dy))
      }
      .onReceive(NotificationCenter.default.publisher(for: .composerEnterEditing)) { _ in
        enterEditingForEntry()
      }
      .onReceive(NotificationCenter.default.publisher(for: .composerSelectTool)) { note in
        if let index = note.userInfo?["index"] as? Int { selectTool(index: index) }
      }
      .onReceive(NotificationCenter.default.publisher(for: .composerToggleAgent)) { _ in
        toggleAgent()
      }
      .onReceive(NotificationCenter.default.publisher(for: .composerTogglePalette)) { _ in
        togglePalette()
      }
      .onReceive(NotificationCenter.default.publisher(for: .composerToggleFocus)) { _ in
        toggleFocus()
      }
      .onReceive(NotificationCenter.default.publisher(for: .composerQuickCapture)) { note in
        if let text = note.object as? String {
          ingestQuickCapture(text)
        }
      }
  }

  private func ingestQuickCapture(_ text: String) {
    guard board.captureExternalText(text) != nil else { return }
      show(Toast(text: "Captured on board".localizedUI, symbol: "leaf.fill", tint: .accentColor))
  }

  /// The agent and Settings share the single overlay slot, driven by `showAgent` /
  /// `store.isSettingsOpen` — they float over the canvas as glass panels.
  private func toggleAgent() {
    withAnimation(Theme.Motion.accessory) {
      if showAgent {
        showAgent = false
      } else {
        showAgent = true
        store.isSettingsOpen = false
      }
    }
  }

  private func selectTool(index: Int) {
    let order: [CanvasTool] = [.select, .text, .rectangle, .ellipse, .diamond, .line, .arrow, .freehand, .equation]
    guard index >= 1, index <= order.count else { return }
    tool = order[index - 1]
  }

  private func boardContent(viewportSize: CGSize) -> some View {
    ZStack(alignment: .topLeading) {
      BoardViewportInput(
        tool: tool,
        isSpacePressed: isSpacePressed,
        onTap: handleTap,
        onDoubleTap: handleDoubleTap,
        onSelectionChanged: { rect in selectionRect = rect; if promotion != nil { dismissPromotion() } },
        onSelectionEnded: selectCards(inViewportRect:modifiers:),
        onFreehandChanged: { freehandDraft = $0; if promotion != nil { dismissPromotion() } },
        onFreehandEnded: commitFreehandDraft,
        onElementDraftChanged: onElementDraftChanged,
        onElementDraftEnded: commitElementDraft,
        onElementDraftCancelled: { elementDraft = nil; bindTargetID = nil },
        onPanChanged: { panLive = $0; if promotion != nil { dismissPromotion() } },
        onPanEnded: { delta in
          pan.width += delta.width
          pan.height += delta.height
          panLive = .zero
        },
        onScroll: handleScroll,
        onZoom: handleZoom
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)

      // The card layer is isolated and `Equatable` so SwiftUI skips rebuilding every card when only a
      // transient gesture changed (draw / freehand / selection rect / pan / zoom). The live pan
      // offset is applied OUTSIDE it, so panning slides the already-built layer instead of
      // re-evaluating a single card — this is what closes the "feels heavy" gap with the capture
      // overlay. Off-screen cards are still culled before the layer builds them.
      BoardCardLayer(
        cards: visibleCards(in: viewportSize),
        board: board,
        selectedCardIDs: board.selectedCardIDs,
        editingCardID: board.editingCardID,
        primarySelectedCardID: board.primarySelectedCardID,
        scale: effectiveScale,
        // Only the select tool may grab a card. In a drawing tool the card is click-through, so a
        // drag that starts over it draws a new element instead of selecting/moving the card.
        selectable: tool == .select,
        failedShellCommands: board.failedShellCommands,
        equationDropTargetID: board.equationDropTargetID
      )
      .equatable()
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      // Layout-based zoom: each card sizes/positions itself in screen space (frame × scale) and
      // renders its text at the zoomed font, so it stays crisp instead of being a stretched bitmap.
      // Only `pan` translates the whole layer; the scale lives inside the cards now.
      .offset(x: pan.width + panLive.width, y: pan.height + panLive.height)

      selectionRectView
      freehandDraftView
      elementDraftView
      snapGuidesOverlay

      // Board-wide pinch-to-zoom, so it works no matter what's under the cursor (card, dock,
      // toolbar, editing text view). Transparent to clicks; only listens for magnify.
      PinchZoomCatcher(onZoom: handleZoom)
        .allowsHitTesting(false)

      imageDropTargetOverlay
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    // Accept image files dragged in from Finder etc. onto the board. The delegate's isTargeted
    // only fires for EXTERNAL content, so this never fights in-canvas card drags or editor drops.
    .onDrop(
      of: [.fileURL],
      delegate: ImageFileDropDelegate(
        isTargeted: $isImageDropTargeted,
        onDrop: handleImageFileDrop
      )
    )
  }

  /// The drop-target treatment shown while an external image drag hovers the canvas: a dashed
  /// accent outline inset from the edges over a subtle accent wash, plus one centered chrome pill
  /// prompting the drop. Pointer-transparent so it never eats the drop.
  @ViewBuilder
  private var imageDropTargetOverlay: some View {
    if isImageDropTargeted {
      ZStack {
        RoundedRectangle(cornerRadius: WindowChrome.radius, style: .continuous)
          .fill(Theme.Palette.accent.opacity(0.06))
          .overlay(
            RoundedRectangle(cornerRadius: WindowChrome.radius, style: .continuous)
              .strokeBorder(
                Theme.Palette.accent.opacity(0.55),
                style: StrokeStyle(lineWidth: 2, dash: [8, 6])
              )
          )
          .padding(WindowChrome.edgeInset)

        HStack(spacing: WindowChrome.itemSpacing) {
          Image(systemName: "photo.badge.plus")
            .font(WindowChrome.iconFont)
            .foregroundStyle(Theme.Palette.chromeGlyph)
            Text("Drop to add".localizedUI)
            .font(WindowChrome.labelFont)
            .foregroundStyle(Theme.Palette.chromeText)
            .padding(.trailing, WindowChrome.labelPadH)
        }
        .frame(height: WindowChrome.controlHeight)
        .padding(.leading, WindowChrome.labelPadH)
        .chromePill()
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .allowsHitTesting(false)
      .transition(.opacity)
      .animation(.easeOut(duration: 0.15), value: isImageDropTargeted)
    }
  }

  @ViewBuilder
  private var elementDraftView: some View {
    if let draft = elementDraft, let kind = tool.elementKind {
      // Highlight the card the arrow/line will bind to, drawn UNDER the draft segment so the segment
      // stays crisp on top. The card frame is mapped into viewport space with the exact card-layer
      // transform (frame × scale, offset by pan + panLive), so the ring lines up with the card.
      if let target = bindTargetID, let card = board.cards.first(where: { $0.id == target }) {
        let rect = CGRect(
          x: card.frame.minX * effectiveScale + pan.width + panLive.width,
          y: card.frame.minY * effectiveScale + pan.height + panLive.height,
          width: card.frame.width * effectiveScale,
          height: card.frame.height * effectiveScale)
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .strokeBorder(Theme.Palette.accent.opacity(0.8), lineWidth: 2)
          .frame(width: rect.width, height: rect.height)
          .position(x: rect.midX, y: rect.midY)
          .allowsHitTesting(false)
      }
      ElementDraftPreview(kind: kind, start: draft.start, end: draft.end)
        .allowsHitTesting(false)
    }
  }

  /// Quiet alignment hairlines while a card MOVE drag snaps. Board→viewport maps with the exact
  /// card-layer transform (× effectiveScale, offset by pan + panLive); each guide spans its own
  /// start→end with a small overshoot so the alignment reads at a glance. 1pt accent lines at 0.6,
  /// pointer-transparent, and NEVER animated — snapping must feel instant.
  @ViewBuilder
  private var snapGuidesOverlay: some View {
    if !board.snapGuides.isEmpty {
      let overshoot: CGFloat = 8
      Path { path in
        for guide in board.snapGuides {
          let position = guide.position * effectiveScale + originOffset(for: guide.axis)
          let start = guide.start * effectiveScale + originOffset(perpendicularTo: guide.axis) - overshoot
          let end = guide.end * effectiveScale + originOffset(perpendicularTo: guide.axis) + overshoot
          switch guide.axis {
          case .vertical:   // a line at x == position, spanning y
            path.move(to: CGPoint(x: position, y: start))
            path.addLine(to: CGPoint(x: position, y: end))
          case .horizontal: // a line at y == position, spanning x
            path.move(to: CGPoint(x: start, y: position))
            path.addLine(to: CGPoint(x: end, y: position))
          }
        }
      }
      .stroke(Theme.Palette.accent.opacity(0.6), lineWidth: 1)
      .allowsHitTesting(false)
    }
  }

  /// The pan translation along a guide's own axis (vertical guide → x pan, horizontal → y pan).
  private func originOffset(for axis: SnapEngine.Axis) -> CGFloat {
    switch axis {
    case .vertical:   return pan.width + panLive.width
    case .horizontal: return pan.height + panLive.height
    }
  }

  /// The pan translation perpendicular to a guide's axis (used to place its span endpoints).
  private func originOffset(perpendicularTo axis: SnapEngine.Axis) -> CGFloat {
    switch axis {
    case .vertical:   return pan.height + panLive.height
    case .horizontal: return pan.width + panLive.width
    }
  }

  @ViewBuilder
  private var selectionRectView: some View {
    if let rect = selectionRect, rect.width > 1, rect.height > 1 {
      RoundedRectangle(cornerRadius: 2, style: .continuous)
        .fill(Theme.Palette.accent.opacity(0.10))
        .overlay(RoundedRectangle(cornerRadius: 2, style: .continuous)
          .strokeBorder(Theme.Palette.accent.opacity(0.72), lineWidth: 1))
        .frame(width: rect.width, height: rect.height)
        .position(x: rect.midX, y: rect.midY)
        .allowsHitTesting(false)
    }
  }

  @ViewBuilder
  private var freehandDraftView: some View {
    if let points = freehandDraft, points.count > 1 {
      Path { path in
        guard let first = points.first else { return }
        path.move(to: first)
        for point in points.dropFirst() { path.addLine(to: point) }
      }
      .stroke(currentTintColor ?? Theme.Palette.inkStroke, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
      .shadow(color: .black.opacity(0.22), radius: 5, y: 2)
      .allowsHitTesting(false)
    }
  }

  /// The active tint resolved against the current flavor (nil = default ink).
  private var currentTintColor: Color? {
    guard let slot = board.currentTint, Theme.flavor.tints.indices.contains(slot) else { return nil }
    return Color(nsColor: Theme.flavor.tints[slot])
  }

  /// A tap on empty board: place a card (Text tool) or clear selection (Select tool).
  private func handleTap(at point: CGPoint, modifiers: EventModifiers) {
    if tool == .select {
      if !modifiers.contains(.shift), !modifiers.contains(.command) { board.deselectAll() }
      return
    }

    guard let kind = tool.elementKind else { return }
    // A bare click with a line/arrow/freehand tool places nothing (no default diagonal shape drops
    // out of nowhere) and keeps the tool active so the next drag draws. Only box shapes and text
    // are click-to-place; lines are drawn by dragging start→end.
    if kind == .line || kind == .arrow || kind == .freehand { return }
    let boardPoint = CGPoint(x: (point.x - pan.width) / effectiveScale,
                             y: (point.y - pan.height) / effectiveScale)
    let id = board.addElement(kind, at: boardPoint)
    tool = .select
    // Text and equation both drop straight into edit mode — an empty card is useless until you
    // type. The editor now lives in the centered `EditingStage` (keyed off `editingCardID`), which
    // owns its own focus delay, so both kinds just arm edit mode after the card mounts.
    if kind == .text || kind == .equation {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
        board.beginEditing(id)
      }
    }
  }

  /// Double-clicking empty canvas drops a text element there and starts editing — the default
  /// "just start writing" gesture, regardless of the active tool.
  private func handleDoubleTap(at point: CGPoint) {
    let id = board.addCard(at: boardPoint(forViewport: point))
    tool = .select
    // Text edits inline: begin editing, then hand the caret to the in-card editor once it mounts.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
      board.beginEditing(id)
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { board.interaction(for: id).controller.focus() }
    }
  }

  /// The draft segment changed (viewport space). Store it, and for a line/arrow resolve the card its
  /// live end would bind to — under the CURRENT drag endpoint, converted to board space — so the
  /// highlight tracks the cursor and matches exactly what `bindArrowIfPossible` will do on commit.
  private func onElementDraftChanged(_ start: CGPoint, _ current: CGPoint) {
    if promotion != nil { dismissPromotion() }
    elementDraft = DragSegment(start: start, end: current)
    if tool == .line || tool == .arrow {
      bindTargetID = board.bindCandidate(at: boardPoint(forViewport: current), excluding: [])
    } else {
      bindTargetID = nil
    }
  }

  /// Commit a shape/line drawn by dragging from `start` to `end` (viewport space → board space).
  private func commitElementDraft(_ start: CGPoint, _ end: CGPoint) {
    defer { elementDraft = nil; bindTargetID = nil }
    // Esc mid-drag cleared the draft; the pending mouse-up must then commit nothing.
    guard elementDraft != nil else { return }
    guard let kind = tool.elementKind else { return }
    if let id = board.addDrawnElement(kind, from: boardPoint(forViewport: start), to: boardPoint(forViewport: end)) {
      tool = .select
      // A perpendicular partner means this pair of lines/arrows reads as axes — offer a graph.
      if kind == .line || kind == .arrow { offerGraphPromotion(id) }
    }
  }

  private func commitFreehandDraft(_ viewportPoints: [CGPoint]) {
    defer { freehandDraft = nil }
    // Esc mid-stroke cleared the draft; the pending mouse-up must then commit nothing.
    guard freehandDraft != nil else { return }
    guard viewportPoints.count > 1 else { return }
    let boardPoints = viewportPoints.map(boardPoint(forViewport:))
    let minX = boardPoints.map(\.x).min() ?? 0
    let minY = boardPoints.map(\.y).min() ?? 0
    let maxX = boardPoints.map(\.x).max() ?? minX
    let maxY = boardPoints.map(\.y).max() ?? minY
    var frame = CGRect(x: minX, y: minY, width: max(maxX - minX, 1), height: max(maxY - minY, 1))
    frame = frame.insetBy(dx: -8, dy: -8)
    let minSize = CardState.lineMinSize
    if frame.width < minSize.width {
      let extra = (minSize.width - frame.width) / 2
      frame.origin.x -= extra
      frame.size.width += extra * 2
    }
    if frame.height < minSize.height {
      let extra = (minSize.height - frame.height) / 2
      frame.origin.y -= extra
      frame.size.height += extra * 2
    }
    let normalized = boardPoints.map {
      CanvasPoint(
        x: Double(($0.x - frame.minX) / frame.width),
        y: Double(($0.y - frame.minY) / frame.height)
      )
    }
    if let id = board.addFreehandStroke(frame: frame, points: normalized) {
      tool = .select
      // The flagship promotion: a confidently recognized stroke offers to become that clean shape.
      offerFreehandPromotion(id, boardPoints: boardPoints)
    }
  }

  private func selectCards(inViewportRect rect: CGRect, modifiers: EventModifiers) {
    defer { selectionRect = nil }
    let s = max(effectiveScale, 0.01)
    let boardRect = CGRect(
      x: (rect.minX - pan.width) / s,
      y: (rect.minY - pan.height) / s,
      width: rect.width / s,
      height: rect.height / s
    )
    board.select(
      in: boardRect,
      extending: modifiers.contains(.shift),
      toggling: modifiers.contains(.command)
    )
  }

  // MARK: Floating chrome

  /// The current board's display name for the standard-window pill (never empty, capped so the
  /// pill hugs its content instead of stretching).
  private var currentBoardName: String {
    let name = store.current?.title.trimmed ?? ""
    guard !name.isEmpty else { return "Untitled".localizedUI }
    return name.count > 32 ? String(name.prefix(32)) + "\u{2026}" : name
  }

  /// The board pill floats top-left after the traffic lights. At rest it is just the current
  /// board's name; hovering grows it into the board manager — every board with rename/delete,
  /// plus a New board row.
  private func boardSwitcherPill(in size: CGSize) -> some View {
    boardPickerMenu
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .padding(.top, WindowChrome.edgeInset)
      .padding(.leading, WindowChrome.trafficLightInset)
      .zIndex(60)
  }

  /// "Welcome Board" (13 characters) is the cap for the rest label: longer names trim with an
  /// ellipsis so the pill never grows past it.
  private var boardPickerTitle: String {
    let name = currentBoardName
    return name.count > 13 ? String(name.prefix(13)) + "…" : name
  }

  /// The picker's title row: the current board's trimmed name. A secondary click pops the
  /// management options — Rename swaps the label for an inline field; Delete removes the current
  /// board (hidden while it's the only one). This is the ONLY home for current-board management:
  /// the expanded list deliberately shows just the other boards.
  @ViewBuilder
  private func currentBoardTitleRow(canDelete: Bool) -> some View {
    if renamingCurrentBoard {
      TextField("Board name".localizedUI, text: $currentBoardDraft)
        .textFieldStyle(.plain)
        .font(WindowChrome.labelFont)
        .foregroundStyle(Theme.Palette.body)
        .multilineTextAlignment(.center)
        .focused($currentBoardNameFocused)
        .onSubmit(commitCurrentBoardRename)
        .onExitCommand(perform: cancelCurrentBoardRename)
        .frame(width: WindowChrome.boardPillWidth, height: WindowChrome.controlHeight)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.Palette.rowFill))
        // Defer a runloop tick: focusing straight from onAppear can miss while the row swaps in.
        .onAppear { DispatchQueue.main.async { currentBoardNameFocused = true } }
        // Clicking away (focus leaves the field) commits, so the rename isn't lost.
        .onChange(of: currentBoardNameFocused) { _, focused in if !focused { commitCurrentBoardRename() } }
    } else {
      Text(boardPickerTitle)
        .font(WindowChrome.labelFont)
        .foregroundStyle(Theme.Palette.body)
        .lineLimit(1)
        .frame(width: WindowChrome.boardPillWidth, height: WindowChrome.controlHeight)
        .contentShape(Rectangle())
        .contextMenu {
          Button("Rename Board".localizedUI) { beginCurrentBoardRename() }
          if canDelete, let id = store.currentID {
            Button("Delete Board".localizedUI, role: .destructive) { deleteBoard(id) }
          }
        }
    }
  }

  private func beginCurrentBoardRename() {
    currentBoardDraft = currentBoardName
    renamingCurrentBoard = true
    boardPickerPinned = true
  }

  private func commitCurrentBoardRename() {
    guard renamingCurrentBoard else { return }   // guard so focus-loss doesn't re-fire after cancel
    renamingCurrentBoard = false
    boardPickerPinned = false
    let name = currentBoardDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    if let id = store.currentID, !name.isEmpty { renameBoard(id, to: name) }
  }

  private func cancelCurrentBoardRename() {
    renamingCurrentBoard = false
    boardPickerPinned = false
  }

  /// The board picker is ONE glass container. At rest it is just the current board's name; on
  /// hover the same surface grows downward into the board manager — the OTHER boards with
  /// rename/delete (the title row already names the current one), plus a New board row. No second
  /// popover, no gap: the pill itself expands. Pill and menu share ONE fixed width
  /// (`boardPillWidth`, sized to the 13-char name cap), so a short name never crushes the menu
  /// and hovering only ever grows the surface downward — never sideways.
  private var boardPickerMenu: some View {
    let others = store.dumps.filter { $0.persistentModelID != store.currentID }
    return VStack(alignment: .leading, spacing: WindowChrome.itemSpacing) {
      currentBoardTitleRow(canDelete: !others.isEmpty)

      if boardPickerOpen {
        // Same fixed width as the rest label so the surface only grows below.
        VStack(alignment: .leading, spacing: WindowChrome.itemSpacing) {
          Divider().overlay(Theme.Palette.separator).padding(.horizontal, 2)

          // Only the OTHER boards — the title row above already shows the current one.
          if !others.isEmpty {
            ScrollView {
              LazyVStack(alignment: .leading, spacing: WindowChrome.itemSpacing) {
                ForEach(others, id: \.persistentModelID) { dump in
                  BoardPickerRow(
                    title: dump.title.isEmpty ? "Untitled".localizedUI : String(dump.title.prefix(40)),
                    isCurrent: false,
                    onPick: {
                      boardPickerOpen = false
                      pickBoard(dump.persistentModelID)
                    },
                    onRename: { renameBoard(dump.persistentModelID, to: $0) },
                    onDelete: { deleteBoard(dump.persistentModelID) },
                    onManaging: { boardPickerPinned = $0 }
                  )
                }
              }
            }
            .frame(maxHeight: 320)
            .fixedSize(horizontal: false, vertical: true)

            Divider().overlay(Theme.Palette.separator).padding(.horizontal, 2)
          }
          newBoardRow
        }
        .frame(width: WindowChrome.boardPillWidth)
      }
    }
    .padding(.horizontal, WindowChrome.padH)
    .padding(.vertical, WindowChrome.padV)
    .composerPopupSurface()
    .onHover { setBoardPickerHover($0) }
    .animation(.easeOut(duration: 0.16), value: boardPickerOpen)
    .help(boardPickerOpen ? "" : "Switch board".localizedUI)
  }

  /// Full-width "New board" action pinned under the list.
  private var newBoardRow: some View {
    Button {
      boardPickerOpen = false
      newBoard()
    } label: {
      HStack(spacing: 6) {
        Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
        Text("New board".localizedUI).font(WindowChrome.labelFont)
      }
      .foregroundStyle(Theme.Palette.body)
      .frame(maxWidth: .infinity)
      .frame(height: 30)
      .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.Palette.rowFill))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help("New board  ⌘N".localizedUI)
  }

  /// Opening is immediate; closing waits a beat so crossing the pill→list gap doesn't flicker.
  /// A pinned panel (inline rename / delete confirm in progress) never closes on hover-out.
  private func setBoardPickerHover(_ hovering: Bool) {
    boardPickerCloseWork?.cancel()
    boardPickerCloseWork = nil
    if hovering {
      if !boardPickerOpen { Haptics.hover() }
      boardPickerOpen = true
    } else {
      let work = DispatchWorkItem { if !boardPickerPinned { boardPickerOpen = false } }
      boardPickerCloseWork = work
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
    }
  }

  /// The top-right chrome: an Export pill (hover-expands, like the board picker) to the LEFT of the
  /// agent pill. `.top` alignment keeps the agent pill anchored while the export pill grows down.
  /// When a scheduled check finds a new release, an Update pill appears at the far left — the one
  /// accent-tinted control in the chrome, so it reads as the single signal, not decoration.
  private func boardActionsPill(in size: CGSize) -> some View {
    HStack(alignment: .top, spacing: WindowChrome.itemSpacing) {
      if let version = updater.availableUpdateVersion {
        updatePill(version: version)
      }
      exportMenu
      SidebarAgentButton(active: showAgent) { toggleAgent() }
        .chromePill()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
    .padding(.top, WindowChrome.edgeInset)
    .padding(.trailing, WindowChrome.edgeInset)
    .animation(Theme.Motion.accessory, value: updater.availableUpdateVersion)
  }

  /// The gentle-reminder surface for a waiting update: same pill grammar as its siblings, accent
  /// ink for the one-signal rule. Click-through opens Sparkle's update flow in focus.
  private func updatePill(version: String) -> some View {
    Button(action: { updater.checkForUpdates() }) {
      HStack(spacing: 5) {
        Image(systemName: "arrow.down.circle")
          .font(WindowChrome.iconFont)
        Text("Update".localizedUI)
          .font(WindowChrome.labelFont)
          .lineLimit(1)
      }
      .foregroundStyle(Theme.Palette.accent)
      .padding(.horizontal, WindowChrome.labelPadH)
      .frame(height: WindowChrome.controlHeight)
      .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .onHover { if $0 { Haptics.hover() } }
    .chromePill()
    .help("BonsAI %@ is ready - click to install".localizedUI(version))
    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .trailing)))
  }

  /// The export pill is ONE glass container. At rest it is the "Export" label; on hover the same
  /// surface grows downward into a list of export formats — no popover, no gap, mirroring the board
  /// picker's hover mechanic exactly. Width-locked to the rest label (like the picker), so the rows
  /// are short format names: the pill only ever grows below.
  private var exportMenu: some View {
    let hasCards = !board.cards.isEmpty
    return VStack(alignment: .leading, spacing: WindowChrome.itemSpacing) {
      // "Export Board", not "Export": the rows are width-locked to this rest label (the pill only
      // grows downward), so the label must be wide enough that "Copy PNG"/"Save PNG…" don't truncate.
      Text("Export Board".localizedUI)
        .font(WindowChrome.labelFont)
        .foregroundStyle(Theme.Palette.body)
        .lineLimit(1)
        .padding(.horizontal, WindowChrome.labelPadH)
        .frame(height: WindowChrome.controlHeight)
        .background(GeometryReader { g in
          Color.clear
            .onAppear { exportRestWidth = g.size.width }
            .onChange(of: g.size.width) { _, w in exportRestWidth = w }
        })

      if exportMenuOpen {
        // Width-locked to the rest label so the surface only grows below.
        VStack(alignment: .leading, spacing: WindowChrome.itemSpacing) {
          Divider().overlay(Theme.Palette.separator).padding(.horizontal, 2)
          ExportMenuRow(label: "Copy PNG".localizedUI, help: "Copy board as PNG to the clipboard".localizedUI, enabled: hasCards) {
            exportMenuOpen = false
            copyBoardAsPNG()
          }
          ExportMenuRow(label: "Save PNG".localizedUI, help: "Export board as PNG".localizedUI, enabled: hasCards) {
            exportMenuOpen = false
            exportBoardAsPNG()
          }
        }
        .frame(width: exportRestWidth > 0 ? exportRestWidth : nil)
      }
    }
    .padding(.horizontal, WindowChrome.padH)
    .padding(.vertical, WindowChrome.padV)
    .composerPopupSurface()
    .onHover { setExportMenuHover($0) }
    .animation(.easeOut(duration: 0.16), value: exportMenuOpen)
    .help(exportMenuOpen ? "" : "Export board".localizedUI)
  }

  /// Opening is immediate; closing waits a beat so crossing the glyph→row gap doesn't flicker —
  /// identical to `setBoardPickerHover`.
  private func setExportMenuHover(_ hovering: Bool) {
    exportMenuCloseWork?.cancel()
    exportMenuCloseWork = nil
    if hovering {
      if !exportMenuOpen { Haptics.hover() }
      exportMenuOpen = true
    } else {
      let work = DispatchWorkItem { exportMenuOpen = false }
      exportMenuCloseWork = work
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
    }
  }

  /// Standard-window mode: ONE bottom-center command bar carrying everything hands-on —
  /// zoom · tools · settings — tldraw-style, so the top stays calm (identity left,
  /// AI actions right) and the bottom is a single strong grouping instead of scattered pills.
  /// Grounding moved into the agent chat (AgentDock) and the ⌘K palette.
  private func bottomCommandBar(fit innerSize: CGSize) -> some View {
    return HStack(spacing: WindowChrome.itemSpacing) {
      SidebarButton(symbol: "minus.magnifyingglass", help: "Zoom out".localizedUI) { zoom(0.8, anchoredAt: zoomAnchor) }
      Button(action: { withAnimation(Theme.Motion.accessory) { scale = 1 } }) {
        Text("\(Int((effectiveScale * 100).rounded()))%")
          .font(WindowChrome.labelFont.monospacedDigit())
          .foregroundStyle(Theme.Palette.chromeText)
          .frame(width: 44, height: WindowChrome.controlHeight)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help("Reset to 100%".localizedUI)
      SidebarButton(symbol: "plus.magnifyingglass", help: "Zoom in".localizedUI) { zoom(1.25, anchoredAt: zoomAnchor) }
      SidebarButton(symbol: "arrow.up.left.and.down.right.magnifyingglass", help: "Fit board".localizedUI) {
        withAnimation(Theme.Motion.accessory) { fitBoard(in: innerSize) }
      }

      barDivider

      CanvasToolbar(tool: $tool)

      barDivider

      tintControl

      barDivider

      SidebarButton(symbol: "gearshape", help: "Settings  ⌘,".localizedUI,
                    active: store.isSettingsOpen) { toggleSettings() }
    }
    .chromePill()
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    .padding(.bottom, WindowChrome.edgeInset)
  }

  private var barDivider: some View {
    Rectangle().fill(Theme.Palette.chromeDivider)
      .frame(width: 1, height: 20)
      .padding(.horizontal, 4)
  }

  /// The element tint: a swatch of the current color that expands into the theme's tint row.
  /// Picking a slot colors NEW elements and re-tints the current selection; tints are stored as
  /// slot indexes, so they re-resolve when the theme changes.
  @ViewBuilder
  private var tintControl: some View {
    Button(action: { withAnimation(.easeOut(duration: 0.14)) { tintPickerOpen.toggle() } }) {
      tintSwatch(for: board.currentTint, diameter: 14)
        .frame(width: WindowChrome.controlHeight, height: WindowChrome.controlHeight)
        .background(
          Circle().fill(tintPickerOpen ? Theme.Palette.hoverWash : Color.clear)
        )
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { if $0 { Haptics.hover() } }
      .help("Element color - applies to new elements and the selection".localizedUI)

    if tintPickerOpen {
      HStack(spacing: 5) {
        tintOption(nil)
        ForEach(Theme.flavor.tints.indices, id: \.self) { slot in
          tintOption(slot)
        }
      }
      .transition(.opacity)
    }
  }

  private func tintOption(_ slot: Int?) -> some View {
    let selected = board.currentTint == slot
    return Button(action: { pickTint(slot) }) {
      tintSwatch(for: slot, diameter: 16)
        .overlay(
          Circle()
            .strokeBorder(selected ? Theme.Palette.accent : Color.clear, lineWidth: 2)
            .frame(width: 22, height: 22)
        )
        .frame(width: 26, height: WindowChrome.controlHeight)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { if $0 { Haptics.hover() } }
    .help(slot == nil ? "Default ink".localizedUI : "Theme color %d".localizedUI((slot ?? 0) + 1))
  }

  private func tintSwatch(for slot: Int?, diameter: CGFloat) -> some View {
    let color: Color = {
      guard let slot, Theme.flavor.tints.indices.contains(slot) else { return Theme.Palette.elementStroke }
      return Color(nsColor: Theme.flavor.tints[slot])
    }()
    return Circle()
      .fill(color)
      .frame(width: diameter, height: diameter)
      .overlay(Circle().strokeBorder(Theme.Palette.panelHairline, lineWidth: 1))
  }

  private func pickTint(_ slot: Int?) {
    board.currentTint = slot
    board.setTintForSelection(slot)
    withAnimation(.easeOut(duration: 0.14)) { tintPickerOpen = false }
  }

  // MARK: Editing stage — the centered surface for structured edits (+ the ⇧⌘F writing sheet)

  /// ⇧⌘F: the current text card expands into the centered writing sheet — the stage's text surface,
  /// summoned EXPLICITLY. Double-click writes inline on the board (writing is the core act and it
  /// stays in place); the sheet is opt-in. Candidate logic unchanged: the editing interaction, else
  /// the primary selection, else the first text card. A second press drops back to the board.
  private func toggleFocus() {
    if focusedCardID != nil { closeFocus(); return }
    let candidate = board.editingInteraction?.id
      ?? board.primarySelectedCardID
      ?? board.cards.first(where: { $0.elementKind == .text })?.id
    guard let id = candidate,
          board.cards.first(where: { $0.id == id })?.elementKind == .text else { return }
    // Hand the single editor over: capture the inline editor's state and unmount it first.
    board.interaction(for: id).captureEditorState()
    board.endEditing(id)
    withAnimation(Theme.Motion.accessory) { focusedCardID = id }
  }

  private func closeFocus() {
    guard let id = focusedCardID else { return }
    board.interaction(for: id).captureEditorState()
    withAnimation(Theme.Motion.accessory) { focusedCardID = nil }
    board.scheduleSave()
  }

  /// The unified editing surface for STRUCTURED edits — equation, graph, shape/line label — plus
  /// the ⇧⌘F writing sheet (`focusedCardID`). Text otherwise edits inline on the board and never
  /// opens a stage from `editingCardID`; freehand/image never open one at all.
  @ViewBuilder
  private func editingStageOverlay(in size: CGSize) -> some View {
    if let id = focusedCardID,
       let card = board.cards.first(where: { $0.id == id }), card.elementKind == .text {
      EditingStage(
        board: board,
        card: card,
        interaction: board.interaction(for: id),
        size: size,
        isWorking: isWorking,
        askEngine: resolvedChatEngine(),
        onClose: { closeFocus() }
      )
      .id(id)
    } else if let id = board.editingCardID,
       let card = board.cards.first(where: { $0.id == id }),
       card.elementKind != .freehand, card.elementKind != .image, card.elementKind != .text {
      EditingStage(
        board: board,
        card: card,
        interaction: board.interaction(for: id),
        size: size,
        isWorking: isWorking,
        askEngine: resolvedChatEngine(),
        // Axes→graph promotion opens the label stage straight in graph-config mode; consume the
        // one-shot intent so a later manual edit of the same card doesn't reopen it.
        openGraphConfigOnAppear: openGraphConfigCardID == id,
        onGraphConfigConsumed: { if openGraphConfigCardID == id { openGraphConfigCardID = nil } },
        onClose: { board.endEditing(id) }
      )
      .id(id)
    }
  }

  // MARK: Promotion chip (the promotion seam's floating affordance)

  /// The live promotion chip, floating just above its card's top edge in viewport space so it tracks
  /// pan/zoom, clamped to stay on screen. Click promotes; the chip is dismissed by the same call.
  @ViewBuilder
  private func promotionOverlay(in size: CGSize) -> some View {
    if let offer = promotion,
       let card = board.cards.first(where: { $0.id == offer.cardID }) {
      let midX = card.frame.midX * effectiveScale + pan.width
      let topY = card.frame.minY * effectiveScale + pan.height - 30
      // A rough half-width for clamping; the chip re-centers itself, so keeping its anchor inside a
      // 90pt inset keeps the whole pill on screen at any pan/zoom.
      let x = min(max(midX, 90), max(90, size.width - 90))
      let y = min(max(topY, 30), max(30, size.height - 30))
      PromotionChip(offer: offer) { promote(offer) }
        .position(x: x, y: y)
        .transition(.opacity)
        .zIndex(45)
    }
  }

  /// Arm the single live offer, replacing any current one, and (re)start the 6s auto-dismiss.
  ///
  /// Arming hops to the next runloop tick: a commit path flips `tool` back to `.select`, whose
  /// `.onChange` fires `dismissPromotion()` on THIS tick — arming after it wins, so the freshly
  /// committed shape/graph offer survives its own tool reset. (Edit-end/selection paths don't touch
  /// the tool, so the hop is harmless there.)
  private func armPromotion(_ offer: PromotionOffer) {
    DispatchQueue.main.async {
      withAnimation(Theme.Motion.accessory) { promotion = offer }
      promotionDismissWork?.cancel()
      let work = DispatchWorkItem { dismissPromotion() }
      promotionDismissWork = work
      DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
    }
  }

  /// Clear the live offer and invalidate its timer — the one retraction path (auto-dismiss, new
  /// gesture, selection change, undo/redo, board switch, Esc, promote).
  private func dismissPromotion() {
    promotionDismissWork?.cancel()
    promotionDismissWork = nil
    if promotion != nil {
      withAnimation(Theme.Motion.accessory) { promotion = nil }
    }
  }

  /// Run the offer's promotion (one undo step each), then dismiss the chip.
  private func promote(_ offer: PromotionOffer) {
    switch offer.kind {
    case .freehandToShape(let kind):
      board.convertFreehand(offer.cardID, to: kind)
    case .textToEquation:
      board.convertTextToEquation(offer.cardID)
    case .textToCards:
      board.splitTextCard(offer.cardID)
    case .arrowsToGraph:
      // Reuse the existing editing-stage conversion, opened straight in graph-config mode.
      openGraphConfigCardID = offer.cardID
      board.select(offer.cardID)
      board.beginEditing(offer.cardID)
    }
    dismissPromotion()
  }

  /// After a freehand stroke commits, offer to promote it to the shape the recognizer read (nil =
  /// no confident read, no chip). `boardPoints` are the committed stroke in board space.
  private func offerFreehandPromotion(_ id: UUID, boardPoints: [CGPoint]) {
    guard let recognition = ShapeRecognizer.recognize(boardPoints) else { return }
    armPromotion(PromotionOffer(
      cardID: id,
      kind: .freehandToShape(recognition.kind),
      label: recognition.kind.promotionLabel,
      symbol: recognition.kind.promotionSymbol))
  }

  /// After a line/arrow finishes drawing, offer a graph if it found a perpendicular partner (an axis
  /// pair). Armed on the NEW element.
  private func offerGraphPromotion(_ id: UUID) {
    guard board.perpendicularPartner(of: id) != nil else { return }
    armPromotion(PromotionOffer(
      cardID: id, kind: .arrowsToGraph, label: "Make graph".localizedUI, symbol: "chart.xyaxis.line"))
  }

  /// Evaluate a text card for the equation/split promotions when its edit session ends. Precision
  /// first: equation wins over split (they can't both match — bullets are multi-line), and prose
  /// offers nothing. No-op for a card that's since gone or is no longer text.
  private func evaluateTextPromotion(_ id: UUID) {
    guard let card = board.cards.first(where: { $0.id == id }), card.elementKind == .text else { return }
    let text = board.plainText(for: card)
    if BoardViewModel.isMathLike(text) {
      armPromotion(PromotionOffer(cardID: id, kind: .textToEquation, label: "Make equation".localizedUI, symbol: "x.squareroot"))
    } else if BoardViewModel.isBulletList(text) {
      armPromotion(PromotionOffer(cardID: id, kind: .textToCards, label: "Split into cards".localizedUI, symbol: "square.on.square"))
    }
  }

  /// Selection changed: retract a chip whose card is no longer the single selection, and arm a text
  /// promotion when a promotable text card becomes the sole selected card (the second evaluation
  /// moment, alongside edit-end).
  private func promotionSelectionChanged() {
    if let offer = promotion, board.selectedCardIDs != [offer.cardID] {
      dismissPromotion()
    }
    guard board.editingCardID == nil,
          board.selectedCardIDs.count == 1,
          let id = board.selectedCardIDs.first,
          promotion?.cardID != id else { return }
    evaluateTextPromotion(id)
  }

  /// Agent floats over the canvas as a right-docked glass panel; Settings presents as a centered
  /// glass sheet over a click-away scrim. One slot — they never co-exist.
  @ViewBuilder
  private func dockOverlay(in size: CGSize) -> some View {
    if showAgent {
      let width = min(360, max(300, size.width * 0.32))
      AgentDock(agent: agent, width: width, onClose: { toggleAgent() })
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .padding(.top, size.height * 0.10)
        .padding(.trailing, WindowChrome.edgeInset)
        // Stop above the bottom command bar rather than covering its right end.
        .padding(.bottom, WindowChrome.edgeInset + WindowChrome.controlHeight + WindowChrome.padV * 2 + 8)
        .shadow(color: Theme.Shadow.panel.color, radius: Theme.Shadow.panel.radius, y: Theme.Shadow.panel.y)
        .transition(.move(edge: .trailing).combined(with: .opacity))
        .zIndex(40)
    } else if store.isSettingsOpen {
      SettingsOverlay(canvasSize: size, onClose: { toggleSettings() })
        .transition(.opacity)
        .zIndex(40)
    }
  }

  @ViewBuilder
  private var compiledOverlay: some View {
    if let draft = store.compiledDraft {
      CompiledDraftOverlay(
        text: draft,
        onCopy: {
          if copyToClipboard(draft) {
            show(Toast(text: "Copied compiled draft".localizedUI, symbol: "doc.on.doc.fill", tint: .accentColor))
          } else {
            show(Toast(text: "macOS did not accept the clipboard contents. The compiled draft was not copied.".localizedUI, symbol: "exclamationmark.triangle.fill", tint: .orange))
          }
        },
        onClose: { store.compiledDraft = nil }
      )
      .transition(.opacity)
    }
  }

  @ViewBuilder
  private var toastView: some View {
    if let toast {
      VStack(spacing: 10) {
        Spacer()
        HStack(spacing: 8) {
          Image(systemName: toast.symbol).foregroundStyle(toast.tint)
          Text(toast.text)
            .font(Theme.Typography.actionLabel)
            .foregroundStyle(Theme.Palette.body)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .composerPopupSurface()
      }
      .padding(.bottom, 24)
      .frame(maxWidth: .infinity)
      .transition(.move(edge: .bottom).combined(with: .opacity))
    }
  }

  // MARK: Zoom helpers

  /// Board zoom is clamped to 35%–200% (Fit applies its own ≤100% cap so it never enlarges).
  private func clampZoom(_ value: CGFloat) -> CGFloat { min(max(value, 0.35), 2) }

  private var viewportCenter: CGPoint {
    CGPoint(x: lastViewportSize.width / 2, y: lastViewportSize.height / 2)
  }

  /// Toolbar/keyboard zoom anchors at the pointer when it's over the canvas — the least-surprise
  /// anchor, and the one pinch already uses. With the cursor elsewhere (menu-driven zoom) it falls
  /// back to the selection's center, then the viewport center, so the board still doesn't lurch.
  private var zoomAnchor: CGPoint {
    if let pointer = pointerViewportLocation() { return pointer }
    let selected = board.cards.filter { board.selectedCardIDs.contains($0.id) }
    guard !selected.isEmpty else { return viewportCenter }
    let midX = ((selected.map(\.x).min() ?? 0) + (selected.map { $0.x + $0.w }.max() ?? 0)) / 2
    let midY = ((selected.map(\.y).min() ?? 0) + (selected.map { $0.y + $0.h }.max() ?? 0)) / 2
    return CGPoint(x: CGFloat(midX) * effectiveScale + pan.width,
                   y: CGFloat(midY) * effectiveScale + pan.height)
  }

  /// The pointer in viewport coordinates (top-left origin), or nil when it isn't over the window.
  /// The canvas fills the content view edge to edge, so the content view IS the viewport; the
  /// isFlipped check keeps this correct whether AppKit hands us a flipped hosting view or not.
  private func pointerViewportLocation() -> CGPoint? {
    guard let window = NSApp.keyWindow, let content = window.contentView else { return nil }
    let local = content.convert(window.mouseLocationOutsideOfEventStream, from: nil)
    guard content.bounds.contains(local) else { return nil }
    return CGPoint(x: local.x, y: content.isFlipped ? local.y : content.bounds.height - local.y)
  }

  /// Whether the board may pan/zoom right now. Stage edits (equation/graph/label) are modal —
  /// events that leak through the scrim (scrollWheel/magnify land on the NSViews beneath SwiftUI
  /// layers) are swallowed so they can't shift the board or tear down an in-flight draft. Inline
  /// TEXT editing lives ON the board, so pan/zoom stays live there; only the caret-anchored popups
  /// (mentions, inline search, lint) are dropped first so they don't drift off their anchor.
  private func allowPanZoom() -> Bool {
    guard let id = board.editingCardID,
          let kind = board.cards.first(where: { $0.id == id })?.elementKind else { return true }
    guard kind == .text else { return false }
    if let editing = board.editingInteraction {
      if editing.mentions.isOpen { editing.mentions.isOpen = false; editing.mentions.items = [] }
      if editing.appSearch.isOpen { editing.appSearch.isOpen = false }
      if editing.lint.activeFlagID != nil { editing.lint.activeFlagID = nil }
    }
    return true
  }

  private func zoom(_ factor: CGFloat, anchoredAt point: CGPoint) {
    guard allowPanZoom() else { return }
    let oldScale = max(scale, 0.01)
    let nextScale = clampZoom(oldScale * factor)
    guard nextScale != scale else { return }
    let boardPoint = CGPoint(
      x: (point.x - pan.width) / oldScale,
      y: (point.y - pan.height) / oldScale
    )
    scale = nextScale
    pan = CGSize(
      width: point.x - boardPoint.x * nextScale,
      height: point.y - boardPoint.y * nextScale
    )
  }

  private func handleScroll(_ delta: CGSize) {
    guard allowPanZoom() else { return }
    viewportThrottle.enqueueScroll(delta) { applied in
      pan.width += applied.width
      pan.height += applied.height
    }
  }

  private func handleZoom(_ factor: CGFloat, anchoredAt point: CGPoint) {
    viewportThrottle.enqueueZoom(factor, anchoredAt: point) { appliedFactor, anchor in
      zoom(appliedFactor, anchoredAt: anchor)
    }
  }

  private func visibleCards(in viewportSize: CGSize) -> [CardState] {
    let margin: CGFloat = 240
    let s = max(effectiveScale, 0.01)
    let currentPan = CGSize(width: pan.width + panLive.width, height: pan.height + panLive.height)
    let visible = CGRect(
      x: (-currentPan.width / s) - margin,
      y: (-currentPan.height / s) - margin,
      width: (viewportSize.width / s) + margin * 2,
      height: (viewportSize.height / s) + margin * 2
    )
    return board.cards.filter {
      $0.frame.intersects(visible) ||
      board.selectedCardIDs.contains($0.id) ||
      board.editingCardID == $0.id
    }
  }

  /// Frame the board within the card viewport at a comfortable margin. Frames the current
  /// selection when there is one (so "Fit" can zoom to what you picked), unless `forceAll` asks for
  /// the whole board — used by the agent's tidy/relayout so it never snaps to a stray selection.
  private func fitBoard(in size: CGSize, forceAll: Bool = false) {
    let selected = forceAll ? [] : board.cards.filter { board.selectedCardIDs.contains($0.id) }
    let target = selected.isEmpty ? board.cards : selected
    guard !target.isEmpty else { scale = 1; pan = .zero; return }
    let minX = target.map(\.x).min() ?? 0
    let minY = target.map(\.y).min() ?? 0
    let maxX = target.map { $0.x + $0.w }.max() ?? Double(size.width)
    let maxY = target.map { $0.y + $0.h }.max() ?? Double(size.height)
    let contentW = max(maxX - minX, 1), contentH = max(maxY - minY, 1)
    let margin: CGFloat = 40
    let avail = CGSize(width: max(size.width - 2 * margin, 1), height: max(size.height - 2 * margin, 1))
    let s = clampZoom(min(avail.width / contentW, avail.height / contentH, 1))
    scale = s
    pan = CGSize(width: margin - CGFloat(minX) * s, height: margin - CGFloat(minY) * s)
  }


  private func resetView() { scale = 1; pan = .zero; dismissPromotion() }

  // MARK: Export

  /// Render the whole board to a PNG and hand it to the save panel. The render is a real AppKit
  /// pass (`BoardExporter.renderBoardImage`) hosting the live card layer at zoom 1 offscreen, so
  /// `NSViewRepresentable`-backed card subviews draw properly and the canvas paints — the old
  /// `ImageRenderer` bailed on both. Images resolve synchronously via `exportImageProvider`.
  @MainActor
  private func exportBoardAsPNG() {
    guard let image = BoardExporter.renderBoardImage(cards: board.cards, board: board) else {
      // renderBoardImage reports its own failure; an empty board simply returns nil.
      return
    }
    BoardExporter.presentSavePanel(image: image, suggestedName: store.current?.title ?? "Board")
  }

  /// Same render as the save path, but straight onto the clipboard so the board can be pasted into
  /// Slack/a PR without a round-trip through the filesystem.
  @MainActor
  private func copyBoardAsPNG() {
    guard let image = BoardExporter.renderBoardImage(cards: board.cards, board: board) else {
      show(Toast(text: "Nothing to export".localizedUI, symbol: "exclamationmark.triangle.fill", tint: .orange))
      return
    }
    BoardExporter.copyToPasteboard(image: image)
      show(Toast(text: "PNG copied - paste anywhere".localizedUI, symbol: "doc.on.clipboard", tint: .accentColor))
  }

  // MARK: Board navigation (history stack)

  private var canNavigate: Bool {
    guard !isWorking, store.compiledDraft == nil else { return false }
    if let editing = board.editingInteraction, editing.mentions.isOpen || editing.appSearch.isOpen { return false }
    return true
  }

  private var canEditBoard: Bool {
    guard !isWorking, !store.isSettingsOpen, store.compiledDraft == nil else { return false }
    return board.editingInteraction == nil
  }

  private func handlePrevDump() { if canNavigate { gotoOlder() } }
  private func handleNextDump() { if canNavigate { gotoNewer() } }
  private func handleNewDump() { if canNavigate { newBoard() } }

  private func handleDeleteSelection() { if canEditBoard { board.deleteSelection() } }
  private func handleDuplicateSelection() { if canEditBoard { board.duplicateSelection() } }
  private func handleCopySelection() { if canEditBoard { copySelectedCards() } }
  private func handlePasteSelection() { if canEditBoard { pasteSelectedCards() } }
  private func handleSelectAllCards() { if canEditBoard { board.selectAll() } }
  private func handleEscapeBoard() {
    // The ⇧⌘F writing sheet closes first — it owns the screen while it's up.
    if focusedCardID != nil { closeFocus(); return }
    // A live promotion chip is the shallowest board-level thing Esc can dismiss — retract it and
    // swallow the keystroke so it doesn't also revert the tool or drop the selection underneath.
    if promotion != nil { dismissPromotion(); return }
    // While a card is being edited its editor owns Esc (inline text resigns focus; stage editors
    // cancel per-kind), so the board Esc cascade must not also fire.
    if board.editingInteraction != nil { return }
    // Esc mid-draw abandons the in-flight shape/freehand: clear the preview state here (the
    // InputView, listening for the same escape, drops its own drag so the pending mouse-up can't
    // commit) and swallow the keystroke so it doesn't also revert the tool underneath the cancel.
    if elementDraft != nil || freehandDraft != nil {
      elementDraft = nil
      freehandDraft = nil
      bindTargetID = nil
      return
    }
    if tool != .select {
      tool = .select
    } else if !board.selectedCardIDs.isEmpty {
      board.deselectAll()
    } else {
      dismiss()
    }
  }
  private func handleUndoBoard() { if canEditBoard { dismissPromotion(); board.undo() } }
  private func handleRedoBoard() { if canEditBoard { dismissPromotion(); board.redo() } }
  private func handleGroupSelection() { if canEditBoard { board.groupSelection() } }
  private func handleUngroupSelection() { if canEditBoard { board.ungroupSelection() } }
  private func handleLockSelection() { if canEditBoard { board.lockSelection(true) } }
  private func handleUnlockSelection() { if canEditBoard { board.lockSelection(false) } }

  private func handleSpaceKey(_ notification: Notification) {
    let down = (notification.userInfo?["down"] as? Bool) ?? false
    isSpacePressed = down
    // Mirror into the shared latch the card catchers poll — they aren't rebuilt on a space press,
    // so they can't read `isSpacePressed` through the view tree.
    CanvasKeyState.shared.isSpaceDown = down
  }

  private func gotoOlder() { board.flushSave(); store.goOlder(); board.loadFromStore(); resetView() }
  private func gotoNewer() { board.flushSave(); store.goNewer(); board.loadFromStore(); resetView() }
  private func newBoard() { board.flushSave(); store.newDump(); board.loadFromStore(); resetView(); focusFirstCard() }
  private func pickBoard(_ id: PersistentIdentifier) { board.flushSave(); store.select(id); board.loadFromStore(); resetView() }
  private func deleteBoard(_ id: PersistentIdentifier) { board.flushSave(); store.delete(id); board.loadFromStore(); resetView() }
  // Rename only touches the board's name, never its cards — no flush/reload needed.
  private func renameBoard(_ id: PersistentIdentifier, to name: String) { store.rename(id, to: name) }

  /// A fresh board's first card opens into its editing stage so the caret is ready. Only a text card
  /// has a caret-first stage; a non-text first card is left selected.
  private func focusFirstCard() {
    guard let id = board.cards.first?.id,
          board.cards.first(where: { $0.id == id })?.elementKind == .text else { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { board.beginEditing(id) }
  }

  /// On panel open: enter editing on the active (or first) text card so the caret is ready to type.
  /// The stage owns focus, so this just arms edit mode. Never steals it mid-edit or while an
  /// overlay/settings is up.
  private func enterEditingForEntry() {
    guard board.editingInteraction == nil, !store.isSettingsOpen, store.compiledDraft == nil,
          !store.isHistoryOpen else { return }
    let id = board.primarySelectedCardID ?? board.cards.first?.id
    guard let id, board.cards.first(where: { $0.id == id })?.elementKind == .text else { return }
    board.beginEditing(id)
  }

  /// The sidebar gear toggles Settings the way ⌘J / the rail toggle Agent: a second click on the
  /// gear while Settings is up closes it again. (⌘, and the menu-bar item still always open.)
  private func toggleSettings() {
    if store.isSettingsOpen {
      withAnimation(Theme.Motion.accessory) { store.isSettingsOpen = false }
    } else {
      openSettings()
    }
  }

  private func openSettings() {
    store.isHistoryOpen = false
    store.compiledDraft = nil
    withAnimation(Theme.Motion.accessory) {
      showAgent = false
      store.isSettingsOpen = true
    }
  }

  private func closeAuxiliaryPanel() {
    guard showAgent || store.isSettingsOpen else { return }
    withAnimation(Theme.Motion.accessory) {
      showAgent = false
      store.isSettingsOpen = false
    }
  }

  // MARK: Command palette (⌘K)

  /// A spotlight over the board: a faint scrim catches a click-away dismiss; the palette itself
  /// floats near the top-center, like Spotlight. Lives only in the board window's SwiftUI tree, so
  /// it never disturbs the board/dock window geometry.
  @ViewBuilder
  private func commandPaletteOverlay(in size: CGSize) -> some View {
    if showPalette {
      ZStack(alignment: .top) {
        Color.black.opacity(0.12)
          .contentShape(Rectangle())
          .onTapGesture { dismissPalette() }
        CommandPalette(
          store: store,
          commands: paletteCommands,
          onPickBoard: { id in closePalette(); pickBoard(id) },
          onRunCommand: { command in closePalette(); command.run() },
          onDismiss: { dismissPalette() }
        )
        .padding(.top, max(48, size.height * 0.12))
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
      .transition(.opacity)
      .zIndex(50)
    }
  }

  private func togglePalette() {
    if showPalette { dismissPalette(); return }
    // The compiled-draft overlay is a focused modal — dismiss it before opening the palette.
    guard store.compiledDraft == nil else { return }
    store.isHistoryOpen = false
    // Capture the editing card, then end the edit session so its stage (zIndex 70) doesn't sit over
    // the palette (zIndex 50). Cancel hands editing back by reopening the stage on the same card.
    paletteReturnCardID = board.editingCardID
    if let id = board.editingCardID { board.endEditing(id) }
    showPalette = true
  }

  /// Pick-a-board / run-an-action paths relocate focus themselves, so just close.
  private func closePalette() {
    showPalette = false
    paletteReturnCardID = nil
  }

  /// Cancel (Esc / click-away / a second ⌘K) closes the palette and hands editing back to the card
  /// you summoned it from — reopening its stage (the palette dropped the edit session so it could sit
  /// on top). Without this you'd land back on the bare board instead of mid-edit.
  private func dismissPalette() {
    showPalette = false
    guard let id = paletteReturnCardID else { return }
    paletteReturnCardID = nil
    guard let card = board.cards.first(where: { $0.id == id }) else { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
      board.beginEditing(id)
      // Stage kinds refocus their own fields on appear; the inline text editor needs the caret
      // handed back explicitly.
      if card.elementKind == .text {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { board.interaction(for: id).controller.focus() }
      }
    }
  }

  /// The buried, shortcut-less (or hard-to-reach) board-level actions, surfaced for fuzzy search.
  /// The lone selected card, or nil unless exactly one is selected. The graph commands below are
  /// single-selection gestures, so they key off this rather than the broader selection set.
  private var solelySelectedCard: CardState? {
    guard board.selectedCardIDs.count == 1, let id = board.primarySelectedCardID else { return nil }
    return board.cards.first { $0.id == id }
  }

  /// The ⌘K palette is "what the UI can't reach" — board-lifecycle actions plus the graph builders
  /// that have no on-canvas home. State-conditional: the graph commands appear only when the current
  /// selection makes them meaningful. Everything with a pill/bar/shortcut home stays out.
  private var paletteCommands: [PaletteCommand] {
    var commands: [PaletteCommand] = [
      PaletteCommand(id: "new-board", title: "New board".localizedUI, symbol: "square.and.pencil", shortcut: "⌘N") { newBoard() },
      PaletteCommand(id: "capture", title: "Capture screen to board".localizedUI, subtitle: "Read on-device into an agent-ready card".localizedUI, symbol: "text.viewfinder", shortcut: ShortcutStore.shared.captureShortcut.displayString) {
        NotificationCenter.default.post(name: .composerCaptureToBoard, object: nil)
      },
      PaletteCommand(id: "focus", title: "Focus write".localizedUI, subtitle: "Expand the current card into a writing sheet".localizedUI, symbol: "rectangle.expand.vertical", shortcut: "⇧⌘F") { toggleFocus() },
      PaletteCommand(id: "add-graph", title: "Add graph to board".localizedUI, subtitle: "Blank axes at the center of the view".localizedUI, symbol: "chart.xyaxis.line") { addGraphToBoard() },
    ]
    // Tidy: the human's reach for the agent's `relayout`. Board-wide re-flow needs ≥2 cards; the
    // selection variant appears only when ≥2 cards are selected. Symbol probes the running OS so it
    // degrades below `wand.and.sparkles`'s macOS-15 floor.
    let tidySymbol = SFSymbolName.resolve("wand.and.sparkles", fallback: "sparkles")
    if board.cards.count > 1 {
      commands.append(PaletteCommand(id: "tidy-board", title: "Tidy board".localizedUI, subtitle: "Re-flow every card into a clean layout".localizedUI, symbol: tidySymbol) { tidyBoard() })
    }
    if board.selectedCardIDs.count > 1 {
      commands.append(PaletteCommand(id: "tidy-selection", title: "Tidy selection".localizedUI, subtitle: "Re-flow the selected cards in place".localizedUI, symbol: tidySymbol) { tidySelection() })
    }
    if let card = solelySelectedCard {
      let kind = card.elementKind
      if kind == .line || kind == .arrow {
        commands.append(PaletteCommand(id: "line-to-graph", title: "Convert line to graph".localizedUI, symbol: "chart.xyaxis.line") { convertLineToGraph(card.id) })
      }
      if kind == .equation, !(card.latex ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
         board.cards.contains(where: { $0.elementKind == .graph }) {
        commands.append(PaletteCommand(id: "plot-equation", title: "Plot equation on graph".localizedUI, symbol: "function") { plotEquationOnGraph(card) })
      }
      if kind == .graph {
        commands.append(PaletteCommand(id: "graph-add-point", title: "Add point to graph...".localizedUI, symbol: "smallcircle.filled.circle") {
          NotificationCenter.default.post(name: .composerAddGraphPoint, object: card.id)
        })
      }
    }
    return commands
  }

  /// Drop a blank graph card at the viewport center (board space) and open its config so it can be
  /// labeled immediately. Placement mirrors `handleTap`'s viewport→board conversion.
  private func addGraphToBoard() {
    let id = board.addGraph(at: boardPoint(forViewport: viewportCenter))
    board.select(id)
    board.beginEditing(id)
  }

  /// Board-wide tidy: re-flow everything, then fit the result into view (with animation) the way the
  /// old palette Fit command did, so the user sees the whole cleaned board.
  private func tidyBoard() {
    board.relayout()
    withAnimation(Theme.Motion.accessory) { fitBoard(in: lastViewportSize, forceAll: true) }
  }

  /// Selection tidy re-flows only the selected cards and keeps them where they were (center held in
  /// relayoutSelection), so it does NOT fit — a corner tidies without the camera jumping.
  private func tidySelection() {
    board.relayoutSelection()
  }

  private func convertLineToGraph(_ id: UUID) {
    board.convertElementToGraph(id, spec: CardState.GraphSpec())
    board.select(id)
    board.beginEditing(id)
  }

  /// Fold the selected equation into a graph: the only `.graph` card, or when several the one whose
  /// center is nearest the equation's. Toast the outcome.
  private func plotEquationOnGraph(_ equation: CardState) {
    let graphs = board.cards.filter { $0.elementKind == .graph }
    guard !graphs.isEmpty else { return }
    let eqCenter = CGPoint(x: equation.frame.midX, y: equation.frame.midY)
    let target = graphs.min { a, b in
      hypot(a.frame.midX - eqCenter.x, a.frame.midY - eqCenter.y)
        < hypot(b.frame.midX - eqCenter.x, b.frame.midY - eqCenter.y)
    }!
    if board.absorbEquationIntoGraph(equation.id, into: target.id) {
      show(Toast(text: "Plotted on graph".localizedUI, symbol: "chart.xyaxis.line", tint: Theme.Palette.accent))
    } else {
      show(Toast(text: "Couldn't plot that expression".localizedUI, symbol: "exclamationmark.triangle.fill", tint: .orange))
    }
  }

  // MARK: Compile + refine

  /// Collapse the whole board into one ordered, paste-ready draft.
  private func runCompile() {
    guard !isWorking, store.compiledDraft == nil else { return }
    let source = board.joinedPlainText()
    guard !source.trimmed.isEmpty else {
      show(Toast(text: "Add some cards to compile".localizedUI, symbol: "rectangle.dashed", tint: .orange))
      return
    }
    guard let engine = preferredEngine() else {
      show(Toast(text: unavailableEngineMessage(), symbol: "exclamationmark.triangle.fill", tint: .orange))
      return
    }
    isWorking = true
    Task {
      do {
        let result = try await service.compileBoard(source: source, engine: engine)
        store.compiledDraft = result
      } catch {
        show(Toast(text: UserFacingError.message(for: error, while: "Compiling the board".localizedUI), symbol: "exclamationmark.triangle.fill", tint: .orange))
      }
      isWorking = false
    }
  }

  /// Refine the active card's current selection in place.
  private func refineSelection(_ engine: HeadlessEngine, card: CardInteraction) {
    let snapshot = card.selection
    guard !snapshot.isEmpty, !isWorking else { return }
    guard EnginePreferences.isEnabled(engine) else {
      show(Toast(text: "%@ is disabled in Settings".localizedUI(engine.title), symbol: "exclamationmark.triangle.fill", tint: .orange))
      return
    }
    guard engineCapabilities.isAvailable(engine) else {
      show(Toast(text: unavailableEngineMessage(), symbol: "exclamationmark.triangle.fill", tint: .orange))
      return
    }
    let whole = card.controller.plainText
    isWorking = true
    Task {
      do {
        let result = try await service.refineSelection(whole: whole, selection: snapshot.text, engine: engine)
        card.controller.replace(range: snapshot.range, with: result)
        show(Toast(text: "Refined with %@".localizedUI(engine.title), symbol: "checkmark.circle.fill", tint: .green))
      } catch {
        show(Toast(text: UserFacingError.message(for: error, while: "Refining the selected text with %@".localizedUI(engine.title)), symbol: "exclamationmark.triangle.fill", tint: .orange))
      }
      isWorking = false
    }
  }

  /// Escalate one flagged phrase on the active card to the chat agent — the same engine the in-canvas
  /// chat runs on, so the linter's "Refine with …" matches the user's Default Chat Agent pick.
  private func askAgent(about flag: LintFlag, card: CardInteraction) {
    guard !isWorking else { return }
    guard let engine = resolvedChatEngine() else {
      show(Toast(text: unavailableEngineMessage(), symbol: "exclamationmark.triangle.fill", tint: .orange))
      return
    }
    let whole = card.controller.plainText
    isWorking = true
    card.lint.activeFlagID = nil
    Task {
      do {
        let result = try await service.refineSelection(whole: whole, selection: flag.phrase, engine: engine)
        card.controller.applyLintFix(range: flag.range, expecting: flag.phrase, with: result)
        show(Toast(text: "Clarified with %@".localizedUI(engine.title), symbol: "checkmark.circle.fill", tint: .green))
      } catch {
        show(Toast(text: UserFacingError.message(for: error, while: "Clarifying the selected text with %@".localizedUI(engine.title)), symbol: "exclamationmark.triangle.fill", tint: .orange))
      }
      isWorking = false
    }
  }

  private func preferredEngine() -> HeadlessEngine? {
    for engine in HeadlessEngine.allCases {
      if EnginePreferences.isEnabled(engine), engineCapabilities.isAvailable(engine) { return engine }
    }
    return nil
  }

  /// The engine the in-canvas chat — and the linter's "Refine with …" escalation — runs on: the
  /// Default Chat Agent pick when enabled + available, else the first available engine.
  private func resolvedChatEngine() -> HeadlessEngine? {
    EnginePreferences.resolvedEngine(for: .chat, isAvailable: engineCapabilities.isAvailable)
  }

  private func unavailableEngineMessage() -> String {
    let enabled = HeadlessEngine.allCases.filter { EnginePreferences.isEnabled($0) }
    guard !enabled.isEmpty else {
      return "All engines are disabled in Settings > Runtime. Enable one before using this action.".localizedUI
    }
    let reasons = enabled.compactMap { engine -> String? in
      switch engineCapabilities.status(for: engine) {
      case .checking: return "%@ is still being checked".localizedUI(engine.title)
      case let .unavailable(reason): return "%@: %@".localizedUI(engine.title, reason)
      case .available: return nil
      }
    }
    if reasons.isEmpty {
      return "No engine could be selected. Open Settings > Runtime > Recheck.".localizedUI
    }
    return reasons.joined(separator: " · ")
  }

  @discardableResult
  private func copyToClipboard(_ text: String) -> Bool {
    NSPasteboard.general.clearContents()
    return NSPasteboard.general.setString(text, forType: .string)
  }

  private func copySelectedCards() {
    let selected = board.selectedCardsForClipboard()
    guard !selected.isEmpty else { return }
    let data: Data
    do {
      data = try JSONEncoder().encode(selected)
    } catch {
      show(Toast(text: UserFacingError.message(for: error, while: "Encoding the selected cards for copy".localizedUI), symbol: "exclamationmark.triangle.fill", tint: .orange))
      return
    }
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    guard pasteboard.setData(data, forType: cardPasteboardType) else {
      show(Toast(text: "macOS did not accept the selected-card clipboard data. The cards were not copied.".localizedUI, symbol: "exclamationmark.triangle.fill", tint: .orange))
      return
    }
  }

  private func pasteSelectedCards() {
    let pasteboard = NSPasteboard.general
    if let data = pasteboard.data(forType: cardPasteboardType) {
      do {
        let cards = try JSONDecoder().decode([CardState].self, from: data)
        // Paste lands under the pointer (the set's bounding-box center on the cursor, relative
        // layout preserved); the 28pt stagger only remains for pointer-less paste (menu-driven,
        // cursor outside the window) so copies never stack invisibly on their originals.
        if let pointer = pointerViewportLocation(), !cards.isEmpty {
          let target = boardPoint(forViewport: pointer)
          let midX = ((cards.map(\.x).min() ?? 0) + (cards.map { $0.x + $0.w }.max() ?? 0)) / 2
          let midY = ((cards.map(\.y).min() ?? 0) + (cards.map { $0.y + $0.h }.max() ?? 0)) / 2
          board.insertCopies(cards, offset: CGSize(width: target.x - CGFloat(midX),
                                                   height: target.y - CGFloat(midY)))
        } else {
          board.insertCopies(cards)
        }
      } catch {
        show(Toast(text: UserFacingError.message(for: error, while: "Reading selected cards from the clipboard".localizedUI), symbol: "exclamationmark.triangle.fill", tint: .orange))
      }
      return
    }
    if let image = firstImage(from: pasteboard), let filename = image.ingest() {
      board.addImageObject(path: filename, at: boardPoint(forViewport: pointerViewportLocation() ?? viewportCenter))
    }
  }

  /// A region captured via "Snap to board" landed: drop it as an image card at the viewport center,
  /// then read it on-device in two stages so the card paints fast — OCR first (the floor), then an
  /// Apple Intelligence cleanup/classification swaps in when it's ready. Both feed the compiled prompt.
  private func addCapturedImage(path: String) {
    let id = board.addImageObject(path: path, at: boardPoint(forViewport: viewportCenter))
    // Reuse the just-captured pixels; only fall back to decoding the PNG if the hand-off missed.
    let captured = CapturedShotStore.shared.take(path)
    Task {
      let ocr: String
      if let captured {
        ocr = await ImageUnderstanding.recognizeText(in: captured)
      } else if let understanding = await ImageUnderstanding.analyze(imagePath: path) {
        board.setImageUnderstanding(id, understanding)
        show(Toast(text: "Screenshot read - ready for the prompt".localizedUI, symbol: "checkmark.circle.fill", tint: .green))
        return
      } else {
        show(Toast(text: "Added screenshot - no text found".localizedUI, symbol: "photo", tint: .accentColor))
        return
      }

      // Stage 1: show the OCR text immediately so the card is useful within a beat.
      if !ocr.isEmpty {
        board.setImageUnderstanding(id, "[Screenshot]\n\(ocr)")
        show(Toast(text: "Screenshot read - ready for the prompt".localizedUI, symbol: "checkmark.circle.fill", tint: .green))
      } else {
        show(Toast(text: "Added screenshot - no text found".localizedUI, symbol: "photo", tint: .accentColor))
      }

      // Stage 2: upgrade to the cleaned, classified version in the background if the model can.
      if let refined = await ImageUnderstanding.refine(ocr: ocr), !refined.isEmpty {
        board.setImageUnderstanding(id, refined)
      }
    }
  }

  /// An external drag of image files landed on the canvas at `viewportLocation`. Resolve each
  /// provider to a file URL, ingest it OFF the main thread (like AppDelegate.captureToBoard), then
  /// drop the card on the MainActor. The first image lands at the drop point (converted to board
  /// coordinates); subsequent images in a multi-drop stagger so they don't stack invisibly.
  /// `addImageObject` registers its own undo.
  @discardableResult
  private func handleImageFileDrop(_ providers: [NSItemProvider], at viewportLocation: CGPoint) -> Bool {
    // Snapshot the board-space drop point now, on the main thread, before any async hop.
    let dropPoint = boardPoint(forViewport: viewportLocation)

    // SwiftUI's NSItemProvider bridging is unreliable for Finder drags on macOS — providers can
    // arrive with no registered type identifiers at all. The AppKit drag pasteboard always holds
    // the real file URLs during performDrop, so read it directly; the provider dance below is
    // only a fallback for drag sources that don't populate the pasteboard.
    let pasteboardURLs = (NSPasteboard(name: .drag).readObjects(
      forClasses: [NSURL.self],
      options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    if !pasteboardURLs.isEmpty {
      for (index, url) in pasteboardURLs.enumerated() {
        ingestDroppedImage(url, at: Self.staggered(dropPoint, index: index))
      }
      return true
    }

    guard !providers.isEmpty else { return false }
    for (index, provider) in providers.enumerated() {
      let point = Self.staggered(dropPoint, index: index)
      Self.loadFileURL(from: provider) { url in
        guard let url else { return }
        ingestDroppedImage(url, at: point)
      }
    }
    return true
  }

  /// Subsequent images in a multi-drop stagger so they don't stack invisibly.
  private static func staggered(_ point: CGPoint, index: Int) -> CGPoint {
    CGPoint(x: point.x + CGFloat(index) * 24, y: point.y + CGFloat(index) * 24)
  }

  /// Ingest one dropped file OFF the main thread (like AppDelegate.captureToBoard), then add the
  /// card on the MainActor. Non-image files are ignored silently (no error UI) — the filter is the
  /// same NSImage.imageTypes conformance set the paste path uses. `addImageObject` registers undo.
  private func ingestDroppedImage(_ url: URL, at point: CGPoint) {
    guard url.conformsToImageType else {
      NSLog("Composer drop: ignoring non-image file %@", url.path)
      return
    }
    Task.detached(priority: .userInitiated) {
      // Finder URLs may be security-scoped even when we can already read them; start/stop is a
      // harmless no-op when the app isn't sandboxed, and correct if it ever is.
      let scoped = url.startAccessingSecurityScopedResource()
      defer { if scoped { url.stopAccessingSecurityScopedResource() } }
      guard let filename = AssetStore.ingest(fileURL: url) else { return }
      await MainActor.run {
        _ = board.addImageObject(path: filename, at: point)
      }
    }
  }

  /// Resolve a dropped provider to a file URL. `loadObject(ofClass: URL.self)` is unreliable for
  /// Finder drags on macOS (the provider surfaces `public.file-url` as raw data, which that
  /// overload won't decode), so read the raw representation first and fall back through the
  /// shapes it's known to arrive in.
  private static func loadFileURL(from provider: NSItemProvider, completion: @escaping (URL?) -> Void) {
    provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
      if let url = item as? URL { completion(url); return }
      if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) { completion(url); return }
      if let text = item as? String, let url = URL(string: text), url.isFileURL { completion(url); return }
      NSLog("Composer drop: could not resolve a file URL from the dropped item (%@)",
            error?.localizedDescription ?? "no underlying error")
      completion(nil)
    }
  }

  private func dismiss() { NotificationCenter.default.post(name: .composerDismiss, object: nil) }

  private func boardPoint(forViewport point: CGPoint) -> CGPoint {
    CGPoint(x: (point.x - pan.width) / effectiveScale,
            y: (point.y - pan.height) / effectiveScale)
  }

  private enum ImageInput {
    case file(URL)
    case image(NSImage)

    func ingest() -> String? {
      switch self {
      case let .file(url): return AssetStore.ingest(fileURL: url)
      case let .image(image): return AssetStore.ingest(image: image)
      }
    }
  }

  private func firstImage(from pasteboard: NSPasteboard) -> ImageInput? {
    let options: [NSPasteboard.ReadingOptionKey: Any] = [
      .urlReadingFileURLsOnly: true,
      .urlReadingContentsConformToTypes: NSImage.imageTypes,
    ]
    if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL],
       let url = urls.first {
      return .file(url)
    }
    if pasteboard.canReadObject(forClasses: [NSImage.self], options: nil),
       let images = pasteboard.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage],
       let first = images.first {
      return .image(first)
    }
    return nil
  }

  // MARK: Toast

  private func showLatestReportedError() {
    guard let notice = userFacingErrors.takeLatest() else { return }
    show(Toast(text: notice.message, symbol: "exclamationmark.triangle.fill", tint: .orange))
  }

  private func show(_ value: Toast) {
    toast = value
    let id = value.id
    // A concrete diagnostic is often much longer than a success confirmation. Keep it on screen
    // long enough to read rather than hiding the useful part after the old fixed 1.9 seconds.
    let duration = min(8.0, max(1.9, 1.3 + Double(value.text.count) * 0.026))
    Task {
      try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
      if toast?.id == id { toast = nil }
    }
  }
}

@MainActor
private final class ViewportEventThrottle {
  private var pendingScroll: CGSize = .zero
  private var scrollScheduled = false
  private var pendingZoomFactor: CGFloat = 1
  private var latestZoomAnchor: CGPoint = .zero
  private var zoomScheduled = false
  private let interval: TimeInterval = 1.0 / 120.0

  func enqueueScroll(_ delta: CGSize, apply: @escaping (CGSize) -> Void) {
    pendingScroll.width += delta.width
    pendingScroll.height += delta.height
    guard !scrollScheduled else { return }
    scrollScheduled = true
    DispatchQueue.main.asyncAfter(deadline: .now() + interval) { [weak self] in
      guard let self else { return }
      let value = pendingScroll
      pendingScroll = .zero
      scrollScheduled = false
      guard value != .zero else { return }
      apply(value)
    }
  }

  func enqueueZoom(_ factor: CGFloat, anchoredAt point: CGPoint, apply: @escaping (CGFloat, CGPoint) -> Void) {
    pendingZoomFactor *= factor
    latestZoomAnchor = point
    guard !zoomScheduled else { return }
    zoomScheduled = true
    DispatchQueue.main.asyncAfter(deadline: .now() + interval) { [weak self] in
      guard let self else { return }
      let factor = pendingZoomFactor
      let anchor = latestZoomAnchor
      pendingZoomFactor = 1
      zoomScheduled = false
      guard factor != 1 else { return }
      apply(factor, anchor)
    }
  }
}

// MARK: - Native viewport input

/// Shared, view-independent latch for the space-to-pan key. The board's viewport input owns the
/// notification-driven state, but a card's own pointer catcher sits ABOVE the viewport in the card
/// layer, so it must consult the same latch to know when to fall through — otherwise space-pan dies
/// anywhere a card sits. AppKit re-creates neither NSView on a space press, so a plain singleton
/// they both poll (in `hitTest` / `mouseDown`) keeps them in lockstep. The window resets it on
/// losing key so a space held while focus leaves doesn't stick the board in pan mode.
///
/// Not `@MainActor`: it's a single `Bool` mutated and read only on the main thread (from
/// notification handlers and AppKit's `hitTest`/`mouseDown`), and staying nonisolated lets the
/// AppKit NSView overrides poll it without concurrency ceremony.
final class CanvasKeyState: @unchecked Sendable {
  static let shared = CanvasKeyState()
  private init() {}
  var isSpaceDown = false
}

private struct BoardViewportInput: NSViewRepresentable {
  let tool: CanvasTool
  let isSpacePressed: Bool
  let onTap: (CGPoint, EventModifiers) -> Void
  let onDoubleTap: (CGPoint) -> Void
  let onSelectionChanged: (CGRect?) -> Void
  let onSelectionEnded: (CGRect, EventModifiers) -> Void
  let onFreehandChanged: ([CGPoint]?) -> Void
  let onFreehandEnded: ([CGPoint]) -> Void
  let onElementDraftChanged: (CGPoint, CGPoint) -> Void
  let onElementDraftEnded: (CGPoint, CGPoint) -> Void
  let onElementDraftCancelled: () -> Void
  let onPanChanged: (CGSize) -> Void
  let onPanEnded: (CGSize) -> Void
  let onScroll: (CGSize) -> Void
  let onZoom: (CGFloat, CGPoint) -> Void

  func makeNSView(context: Context) -> InputView {
    let view = InputView()
    view.state = state
    return view
  }

  func updateNSView(_ nsView: InputView, context: Context) {
    nsView.state = state
  }

  private var state: InputView.State {
    InputView.State(
      tool: tool,
      isSpacePressed: isSpacePressed,
      onTap: onTap,
      onDoubleTap: onDoubleTap,
      onSelectionChanged: onSelectionChanged,
      onSelectionEnded: onSelectionEnded,
      onFreehandChanged: onFreehandChanged,
      onFreehandEnded: onFreehandEnded,
      onElementDraftChanged: onElementDraftChanged,
      onElementDraftEnded: onElementDraftEnded,
      onElementDraftCancelled: onElementDraftCancelled,
      onPanChanged: onPanChanged,
      onPanEnded: onPanEnded,
      onScroll: onScroll,
      onZoom: onZoom
    )
  }

  final class InputView: NSView {
    struct State {
      var tool: CanvasTool = .select
      var isSpacePressed = false
      var onTap: (CGPoint, EventModifiers) -> Void = { _, _ in }
      var onDoubleTap: (CGPoint) -> Void = { _ in }
      var onSelectionChanged: (CGRect?) -> Void = { _ in }
      var onSelectionEnded: (CGRect, EventModifiers) -> Void = { _, _ in }
      var onFreehandChanged: ([CGPoint]?) -> Void = { _ in }
      var onFreehandEnded: ([CGPoint]) -> Void = { _ in }
      var onElementDraftChanged: (CGPoint, CGPoint) -> Void = { _, _ in }
      var onElementDraftEnded: (CGPoint, CGPoint) -> Void = { _, _ in }
      var onElementDraftCancelled: () -> Void = {}
      var onPanChanged: (CGSize) -> Void = { _ in }
      var onPanEnded: (CGSize) -> Void = { _ in }
      var onScroll: (CGSize) -> Void = { _ in }
      var onZoom: (CGFloat, CGPoint) -> Void = { _, _ in }
    }

    private enum DragMode {
      case maybeTap
      case selecting
      case drawing
      case placing
      case panning
    }

    var state = State() {
      didSet {
        if state.isSpacePressed != oldValue.isSpacePressed || state.tool != oldValue.tool {
          window?.invalidateCursorRects(for: self)
        }
      }
    }
    private var dragStart: CGPoint?
    private var dragModifiers: EventModifiers = []
    /// Refresh the cursor whenever the drag mode changes, so the open-hand grab flips to a closed
    /// grab the moment a space-pan actually starts (and back when it ends).
    private var dragMode: DragMode = .maybeTap {
      didSet { if dragMode != oldValue { window?.invalidateCursorRects(for: self) } }
    }
    private var dragClickCount = 1
    private var lastPan: CGSize = .zero
    private var freehandPoints: [CGPoint] = []
    /// Last raw drag point, kept so a Shift press/release with the mouse still (flagsChanged,
    /// no mouseDragged) can re-emit the draft with the new constraint immediately.
    private var lastDragPoint: CGPoint?
    /// Set when Esc aborted the current placing/freehand drag: further mouse-drags stop emitting a
    /// preview and the pending mouse-up commits nothing. Reset on the next `mouseDown`.
    private var draftCancelled = false
    private var escapeObserver: NSObjectProtocol?

    override init(frame frameRect: NSRect) {
      super.init(frame: frameRect)
      // Esc while drawing abandons the in-flight shape/freehand: drop this drag so the pending
      // mouse-up can't commit it. The canvas clears its preview state on the same notification.
      escapeObserver = NotificationCenter.default.addObserver(
        forName: .composerEscapeBoard, object: nil, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.cancelActiveDraft() }
      }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
      if let escapeObserver { NotificationCenter.default.removeObserver(escapeObserver) }
    }

    /// Abandon a placing/freehand drag in progress (Esc). Leaves the mode intact so the eventual
    /// mouse-up still tears the gesture down cleanly, but flags it so nothing is committed.
    private func cancelActiveDraft() {
      guard dragMode == .placing || dragMode == .drawing else { return }
      draftCancelled = true
      freehandPoints = []
      state.onFreehandChanged(nil)
      state.onElementDraftCancelled()
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    // Cursor feedback for the current mode: a closed grab while actually panning (space + drag), an
    // open grab while space is merely held (pan is armed), and a crosshair for every drawing tool so
    // the canvas reads as "ready to place". Select tool with no space held keeps the arrow.
    override func resetCursorRects() {
      if state.isSpacePressed {
        addCursorRect(bounds, cursor: dragMode == .panning ? .closedHand : .openHand)
      } else if state.tool.elementKind != nil {
        addCursorRect(bounds, cursor: .crosshair)
      }
    }

    override func mouseDown(with event: NSEvent) {
      window?.makeFirstResponder(self)
      let point = convert(event.locationInWindow, from: nil)
      dragStart = point
      dragModifiers = EventModifiers(event.modifierFlags)
      dragClickCount = event.clickCount
      lastPan = .zero
      freehandPoints = []
      draftCancelled = false
      dragMode = state.isSpacePressed ? .panning : .maybeTap
      state.onSelectionChanged(nil)
      state.onFreehandChanged(nil)
      state.onElementDraftCancelled()
    }

    override func mouseDragged(with event: NSEvent) {
      guard let start = dragStart else { return }
      // Esc cancelled this placing/freehand drag — ignore the rest of it until mouse-up.
      if draftCancelled { lastDragPoint = convert(event.locationInWindow, from: nil); return }
      let point = convert(event.locationInWindow, from: nil)
      let delta = CGSize(width: point.x - start.x, height: point.y - start.y)
      let distance = hypot(delta.width, delta.height)

      if dragMode == .maybeTap, distance >= 4 {
        if state.tool == .select {
          dragMode = .selecting
        } else if state.tool == .freehand {
          dragMode = .drawing
          freehandPoints = [start]
          state.onFreehandChanged(freehandPoints)
        } else if state.tool.placesByDragging {
          dragMode = .placing
        } else {
          dragMode = .panning
        }
      }

      switch dragMode {
      case .maybeTap:
        break
      case .selecting:
        state.onSelectionChanged(Self.normalizedRect(from: start, to: point))
      case .drawing:
        if freehandPoints.last.map({ hypot($0.x - point.x, $0.y - point.y) >= 1.5 }) ?? true {
          freehandPoints.append(point)
          state.onFreehandChanged(freehandPoints)
        }
      case .placing:
        state.onElementDraftChanged(start, constrained(point, from: start, flags: event.modifierFlags))
      case .panning:
        lastPan = delta
        state.onPanChanged(delta)
      }
      lastDragPoint = point
    }

    /// Shift squares box-shape drags (|dx| == |dy| == the larger side, keeping direction) and snaps
    /// line/arrow drags to the nearer axis (horizontal if |dx| >= |dy|, else vertical). Freeform for
    /// every other tool. Reads the live modifier flags, so pressing/releasing Shift mid-drag updates
    /// the draft — same mechanism the square constraint uses.
    private func constrained(_ end: CGPoint, from start: CGPoint, flags: NSEvent.ModifierFlags) -> CGPoint {
      guard flags.contains(.shift) else { return end }
      let dx = end.x - start.x, dy = end.y - start.y
      if state.tool.constrainsToSquare {
        let side = max(abs(dx), abs(dy))
        return CGPoint(x: start.x + (dx < 0 ? -side : side), y: start.y + (dy < 0 ? -side : side))
      }
      if state.tool.constrainsToAxis {
        return abs(dx) >= abs(dy) ? CGPoint(x: end.x, y: start.y) : CGPoint(x: start.x, y: end.y)
      }
      return end
    }

    /// Pressing/releasing Shift mid-drag updates the draft immediately, without waiting for the
    /// next mouse movement.
    override func flagsChanged(with event: NSEvent) {
      if dragMode == .placing, let start = dragStart, let current = lastDragPoint {
        state.onElementDraftChanged(start, constrained(current, from: start, flags: event.modifierFlags))
      }
      super.flagsChanged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
      guard let start = dragStart else { return }
      let point = convert(event.locationInWindow, from: nil)
      let delta = CGSize(width: point.x - start.x, height: point.y - start.y)
      let distance = hypot(delta.width, delta.height)

      // Esc already tore down this placing/freehand drag — commit nothing and reset cleanly, so the
      // mouse-up neither drops a shape nor falls through to tap-to-place.
      if draftCancelled {
        resetDragState()
        return
      }

      switch dragMode {
      case .maybeTap:
        if dragClickCount >= 2 { state.onDoubleTap(start) } else { state.onTap(start, dragModifiers) }
      case .selecting:
        if distance < 5 {
          state.onSelectionChanged(nil)
          state.onTap(start, dragModifiers)
        } else {
          state.onSelectionEnded(Self.normalizedRect(from: start, to: point), dragModifiers)
        }
      case .drawing:
        if freehandPoints.last != point { freehandPoints.append(point) }
        state.onFreehandEnded(freehandPoints)
      case .placing:
        if distance < 5 {
          // A bare click (no real drag). `onTap` → `handleTap` decides per tool whether to place:
          // box/text tools place at the click, line/arrow place nothing (no default diagonal arrow).
          state.onElementDraftCancelled()
          state.onTap(start, dragModifiers)
        } else {
          state.onElementDraftEnded(start, constrained(point, from: start, flags: event.modifierFlags))
        }
      case .panning:
        state.onPanEnded(lastPan)
      }

      resetDragState()
    }

    private func resetDragState() {
      dragStart = nil
      dragModifiers = []
      dragMode = .maybeTap
      lastPan = .zero
      freehandPoints = []
      lastDragPoint = nil
      draftCancelled = false
      state.onSelectionChanged(nil)
      state.onFreehandChanged(nil)
    }

    override func scrollWheel(with event: NSEvent) {
      // Panning mid-draw would shift the board out from under a draft whose start point was captured
      // at the old pan, so the committed shape lands away from the preview. Swallow scroll-pan while
      // a shape/freehand drag is live; two-finger pan resumes the moment the draw ends.
      if dragMode == .placing || dragMode == .drawing { return }
      state.onScroll(CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY))
    }

    private static func normalizedRect(from start: CGPoint, to end: CGPoint) -> CGRect {
      CGRect(
        x: min(start.x, end.x),
        y: min(start.y, end.y),
        width: abs(end.x - start.x),
        height: abs(end.y - start.y)
      )
    }
  }
}

// MARK: - External image-file drop

/// Accepts EXTERNAL image-file drags (Finder etc.) onto the canvas, exposing both the hover state
/// (for the drop-target treatment) and the drop location (for board-coordinate placement).
/// SwiftUI's plain `.onDrop(of:isTargeted:)` gives one or the other; a DropDelegate gives both.
private struct ImageFileDropDelegate: DropDelegate {
  @Binding var isTargeted: Bool
  /// Called with the item providers and the drop location in canvas viewport space. Returns
  /// whether the drop was accepted.
  let onDrop: ([NSItemProvider], CGPoint) -> Bool

  func validateDrop(info: DropInfo) -> Bool {
    info.hasItemsConforming(to: [.fileURL])
  }

  func dropEntered(info: DropInfo) {
    withAnimation(.easeOut(duration: 0.15)) { isTargeted = true }
  }

  func dropExited(info: DropInfo) {
    withAnimation(.easeOut(duration: 0.15)) { isTargeted = false }
  }

  func performDrop(info: DropInfo) -> Bool {
    withAnimation(.easeOut(duration: 0.15)) { isTargeted = false }
    return onDrop(info.itemProviders(for: [.fileURL]), info.location)
  }
}

private extension URL {
  /// True when the file's own content type conforms to any image type BonsAI accepts — the same
  /// `NSImage.imageTypes` set the paste path filters on.
  var conformsToImageType: Bool {
    guard let type = (try? resourceValues(forKeys: [.contentTypeKey]))?.contentType else {
      // No resolvable type (e.g. a file that no longer exists): fall back to the extension.
      return NSImage.imageTypes.contains { UTType($0)?.preferredFilenameExtension == pathExtension.lowercased() }
    }
    return NSImage.imageTypes.contains { UTType($0).map { type.conforms(to: $0) } ?? false }
  }
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

// MARK: - Board-wide pinch zoom

/// Reliable pinch-to-zoom for the whole board. A per-view `magnify(with:)` only fires when the
/// gesture lands on that exact view, so pinching over a card, the dock, the toolbar, or an editing
/// text view used to silently do nothing — the "sometimes it works, sometimes it doesn't" feel.
/// A single local event monitor catches every `.magnify` in the panel window regardless of what's
/// under the cursor, so it works everywhere, every time; it stays transparent to clicks and scroll.
private struct PinchZoomCatcher: NSViewRepresentable {
  let onZoom: (CGFloat, CGPoint) -> Void

  func makeNSView(context: Context) -> MonitorView {
    let view = MonitorView()
    view.onZoom = onZoom
    view.install()
    return view
  }
  func updateNSView(_ view: MonitorView, context: Context) { view.onZoom = onZoom }
  static func dismantleNSView(_ view: MonitorView, coordinator: ()) { view.uninstall() }

  final class MonitorView: NSView {
    var onZoom: (CGFloat, CGPoint) -> Void = { _, _ in }
    private var monitor: Any?
    override var isFlipped: Bool { true }
    // Pointer-transparent: clicks/scroll fall through to the board; the monitor still gets magnify.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func install() {
      guard monitor == nil else { return }
      monitor = NSEvent.addLocalMonitorForEvents(matching: .magnify) { [weak self] event in
        guard let self, let window = self.window, event.window === window else { return event }
        self.onZoom(1 + event.magnification, self.convert(event.locationInWindow, from: nil))
        return nil   // handled here — don't let any view double-apply it
      }
    }
    func uninstall() {
      if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
    }
    deinit { uninstall() }
  }
}

// MARK: - Active-card overlays

/// The caret/selection-anchored chrome for whichever card holds focus: the selection action
/// bar, the `@`-mention menu, the connector search panel, and the linter popover. Observes the
/// active card's state objects directly so it re-renders when they change; rebuilt (via `.id`)
/// when the active card changes.
private struct ActiveCardOverlays: View {
  @ObservedObject var card: CardInteraction
  @ObservedObject var mentions: MentionState
  @ObservedObject var appSearch: AppSearchState
  @ObservedObject var lint: LintState
  let size: CGSize
  let isWorking: Bool
  let currentTint: Int?
  /// The engine the linter's "Refine with …" escalation targets (the resolved Chat Agent pick);
  /// `nil` hides the escalate row.
  let askEngine: HeadlessEngine?
  let onRefine: (HeadlessEngine) -> Void
  let onFormat: (MarkdownStyle.Action) -> Void
  let onTint: (Int?) -> Void
  let onApplyFix: (LintFlag, String) -> Void
  let onEscalate: (LintFlag) -> Void

  init(card: CardInteraction, size: CGSize, isWorking: Bool,
       currentTint: Int?,
       onRefine: @escaping (HeadlessEngine) -> Void,
       onFormat: @escaping (MarkdownStyle.Action) -> Void,
       onTint: @escaping (Int?) -> Void,
       onApplyFix: @escaping (LintFlag, String) -> Void,
       askEngine: HeadlessEngine?,
       onEscalate: @escaping (LintFlag) -> Void) {
    self.card = card
    self.mentions = card.mentions
    self.appSearch = card.appSearch
    self.lint = card.lint
    self.size = size
    self.isWorking = isWorking
    self.currentTint = currentTint
    self.askEngine = askEngine
    self.onRefine = onRefine
    self.onFormat = onFormat
    self.onTint = onTint
    self.onApplyFix = onApplyFix
    self.onEscalate = onEscalate
  }

  var body: some View {
    ZStack(alignment: .topLeading) {
      selectionBar
      mentionMenu
      appSearchPanel
      lintPopover
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .animation(Theme.Motion.accessory, value: card.selection)
    .animation(Theme.Motion.accessory, value: mentions.isOpen)
    .animation(Theme.Motion.accessory, value: appSearch.isOpen)
    .animation(Theme.Motion.accessory, value: lint.activeFlagID)
  }

  @ViewBuilder
  private var selectionBar: some View {
    if !card.selection.isEmpty, !mentions.isOpen, !appSearch.isOpen, let rect = card.selection.rectInView {
      SelectionActionBar(isWorking: isWorking, onRefine: onRefine, onFormat: onFormat, currentTint: currentTint, onTint: onTint)
        .fixedSize()
        .position(x: clamp(rect.midX, 120, max(120, size.width - 120)),
                  y: clamp(rect.minY - 22, 30, max(30, size.height - 28)))
        .transition(.opacity)
    }
  }

  @ViewBuilder
  private var mentionMenu: some View {
    if mentions.isOpen, let anchor = mentions.anchorInView {
      let popup = CGSize(width: Theme.Size.menuWidth, height: mentionMenuHeight)
      let origin = popupOrigin(anchor: anchor, popup: popup)
      MentionMenu(mentions: mentions)
        .fixedSize(horizontal: true, vertical: false)
        .frame(width: popup.width)
        .position(x: origin.x + popup.width / 2, y: origin.y + popup.height / 2)
        .transition(.opacity)
    }
  }

  @ViewBuilder
  private var appSearchPanel: some View {
    if appSearch.isOpen, let anchor = appSearch.anchorInView {
      let popup = CGSize(width: 360, height: appSearchPanelHeight)
      let origin = popupOrigin(anchor: anchor, popup: popup)
      AppSearchPanel(state: appSearch)
        .fixedSize(horizontal: true, vertical: false)
        .frame(width: popup.width)
        .position(x: origin.x + popup.width / 2, y: origin.y + popup.height / 2)
        .transition(.opacity)
    }
  }

  @ViewBuilder
  private var lintPopover: some View {
    if card.selection.isEmpty, !mentions.isOpen, !appSearch.isOpen, let flag = lint.activeFlag, let rect = flag.rectInView {
      let popup = CGSize(width: 300, height: lintPopoverHeight(flag))
      let origin = popupOrigin(anchor: CGPoint(x: rect.minX, y: rect.maxY + 1), popup: popup)
      LintPopover(
        flag: flag,
        escalationEngine: askEngine,
        onPick: { onApplyFix(flag, $0) },
        onEscalate: { onEscalate(flag) },
        onHover: { hovering in if hovering { lint.cancelHide?() } else { lint.requestHide?() } }
      )
      .fixedSize(horizontal: true, vertical: false)
      .frame(width: popup.width)
      .position(x: origin.x + popup.width / 2, y: origin.y + popup.height / 2)
      .transition(.opacity)
    }
  }

  // MARK: Geometry

  private var mentionMenuHeight: CGFloat {
    let rows = min(CGFloat(max(mentions.items.count, 1)), Theme.Size.menuMaxVisibleRows)
    return rows * Theme.Size.menuRowHeight + 10 + 26
  }

  private var appSearchPanelHeight: CGFloat {
    let content: CGFloat
    if appSearch.results.isEmpty {
      content = 42
    } else {
      content = min(CGFloat(max(appSearch.results.count, 1)), Theme.Size.menuMaxVisibleRows) * 46 + 10
    }
    return 42 + 1 + content + 26
  }

  private func lintPopoverHeight(_ flag: LintFlag) -> CGFloat {
    // The escalate row is hidden when no engine is available; each shown block adds its own hairline.
    let hasButton = askEngine != nil
    let suggestions = CGFloat(flag.suggestions.count) * 42
    let button: CGFloat = hasButton ? 42 : 0
    let dividers = (flag.suggestions.isEmpty ? 0.0 : 1.0) + (hasButton ? 1.0 : 0.0)
    return min(260, 62 + suggestions + button + dividers)
  }

  private func popupOrigin(anchor: CGPoint, popup: CGSize) -> CGPoint {
    let margin: CGFloat = 8
    let below = anchor.y + 6
    let above = anchor.y - popup.height - 8
    let hasRoomBelow = below + popup.height <= size.height - margin
    let hasMoreRoomAbove = anchor.y > size.height - anchor.y
    let preferredY = (!hasRoomBelow && hasMoreRoomAbove) ? above : below
    return CGPoint(
      x: clamp(anchor.x, margin, max(margin, size.width - popup.width - margin)),
      y: clamp(preferredY, margin, max(margin, size.height - popup.height - margin)))
  }

  private func clamp(_ value: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
    Swift.min(Swift.max(value, lower), upper)
  }
}

/// The board's card layer, pulled out of the canvas body and made `Equatable` so SwiftUI re-renders
/// the cards only when something that actually affects how they draw changes — never for a transient
/// gesture (draw / freehand / selection rect / live pan), which all mutate canvas `@State` that this
/// layer doesn't depend on. The comparison covers exactly that state: the visible cards themselves,
/// the selection/editing/primary ids, the zoom, the select-tool gate, and the shell-failure marks.
///
/// `board` and `onEscape` are excluded from `==` on purpose — the board is one stable instance and
/// the closure is stable, so comparing them would be meaningless. `definedVariableNames` is also left
/// out deliberately: it's an O(n) string rebuild to read and only changes when card text is committed
/// (which already changes `cards`), so including it would cost per frame for no behavior gain.
///
/// Each `BoardCardView` still observes its own `CardInteraction`, so editing/typing a card re-renders
/// just that card even while this whole layer is skipped — the same way the capture overlay stays
/// immediate.
struct BoardCardLayer: View, Equatable {
  let cards: [CardState]
  let board: BoardViewModel
  let selectedCardIDs: Set<UUID>
  let editingCardID: UUID?
  let primarySelectedCardID: UUID?
  let scale: CGFloat
  let selectable: Bool
  let failedShellCommands: Set<String>
  /// The graph card a parseable equation is currently dragged over (its accent drop-ring). Included
  /// in `==` so the ring appears/clears mid-drag even though nothing in `cards` changes.
  let equationDropTargetID: UUID?

  static func == (lhs: BoardCardLayer, rhs: BoardCardLayer) -> Bool {
    lhs.cards == rhs.cards &&
      lhs.selectedCardIDs == rhs.selectedCardIDs &&
      lhs.editingCardID == rhs.editingCardID &&
      lhs.primarySelectedCardID == rhs.primarySelectedCardID &&
      lhs.scale == rhs.scale &&
      lhs.selectable == rhs.selectable &&
      lhs.failedShellCommands == rhs.failedShellCommands &&
      lhs.equationDropTargetID == rhs.equationDropTargetID
  }

  var body: some View {
    ZStack(alignment: .topLeading) {
      ForEach(cards) { card in
        BoardCardView(
          card: card,
          interaction: board.interaction(for: card.id),
          isSelected: selectedCardIDs.contains(card.id),
          isEditing: editingCardID == card.id,
          scale: scale,
          board: board,
          selectable: selectable
        )
        .zIndex(Double(card.z) + (primarySelectedCardID == card.id ? 10_000 : 0))
      }
    }
  }
}

/// Start/end of an in-progress drag that draws a shape or line (viewport coordinates).
private struct DragSegment: Equatable {
  var start: CGPoint
  var end: CGPoint
}

/// The board card is derived from its own AppKit window's current viewport. The auxiliary dock is
/// deliberately absent here: it is a sibling window managed by `PanelController`.
/// One row of the hover board picker: click to switch; hover reveals rename (pencil) and delete
/// (trash) icons. Rename is inline; delete arms on first click (red) and fires on the second.
private struct BoardPickerRow: View {
  let title: String
  let isCurrent: Bool
  let onPick: () -> Void
  let onRename: (String) -> Void
  var onDelete: (() -> Void)?
  /// True while this row is renaming or confirming a delete — pins the panel open.
  var onManaging: (Bool) -> Void

  @State private var hovering = false
  @State private var isRenaming = false
  @State private var confirmingDelete = false
  @State private var draftName = ""
  @FocusState private var nameFocused: Bool

  var body: some View {
    Group {
      if isRenaming { renameRow } else { pickRow }
    }
    .onHover { over in
      hovering = over
      if over { Haptics.hover() }
      if !over { setConfirmingDelete(false) }
    }
    .animation(.easeOut(duration: 0.1), value: hovering)
  }

  private var pickRow: some View {
    Button(action: onPick) {
      HStack(spacing: 8) {
        Circle()
          .fill(isCurrent ? Theme.Palette.accent : Color.clear)
          .frame(width: 5, height: 5)
        Text(title)
          .font(WindowChrome.labelFont)
          .foregroundStyle(Theme.Palette.body)
          .lineLimit(1)
        Spacer(minLength: 10)
        if hovering {
          rowIcon("pencil", help: "Rename board".localizedUI, tint: nil) { beginRename() }
          if let onDelete {
            rowIcon("trash", help: confirmingDelete ? "Click again to permanently delete".localizedUI : "Delete board".localizedUI,
                    tint: confirmingDelete ? .red : nil) {
              if confirmingDelete { onDelete() } else { setConfirmingDelete(true) }
            }
          }
        }
      }
      .padding(.horizontal, WindowChrome.labelPadH)
      .frame(height: 30)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  private var renameRow: some View {
    HStack(spacing: 8) {
      Circle()
        .fill(isCurrent ? Theme.Palette.accent : Color.clear)
        .frame(width: 5, height: 5)
      TextField("Board name".localizedUI, text: $draftName)
        .textFieldStyle(.plain)
        .font(WindowChrome.labelFont)
        .foregroundStyle(Theme.Palette.body)
        .focused($nameFocused)
        .onSubmit(commitRename)
        .onExitCommand(perform: cancelRename)
    }
    .padding(.horizontal, WindowChrome.labelPadH)
    .frame(height: 30)
    .background(
      RoundedRectangle(cornerRadius: 7, style: .continuous)
        .fill(Theme.Palette.rowFill)
    )
    // Defer a runloop tick: focusing straight from onAppear can miss while the panel animates in.
    .onAppear { DispatchQueue.main.async { nameFocused = true } }
    // Clicking away (focus leaves the field) commits, so the rename isn't lost.
    .onChange(of: nameFocused) { _, focused in if !focused { commitRename() } }
  }

  private func rowIcon(_ symbol: String, help: String, tint: Color?, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: 10.5, weight: .semibold))
        .foregroundStyle(tint ?? Theme.Palette.title)
        .frame(width: 20, height: 20)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(help)
  }

  private func beginRename() {
    draftName = title
    setConfirmingDelete(false)
    isRenaming = true
    onManaging(true)
  }

  private func commitRename() {
    guard isRenaming else { return }   // guard so the focus-loss path doesn't re-fire after a cancel
    isRenaming = false
    onManaging(false)
    onRename(draftName)
  }

  private func cancelRename() {
    isRenaming = false
    onManaging(false)
  }

  private func setConfirmingDelete(_ value: Bool) {
    guard confirmingDelete != value else { return }
    confirmingDelete = value
    onManaging(value)
  }
}

/// One row of the hover export menu: a short centered format name ("PNG"). The menu is
/// width-locked to the "Export" rest label, so rows carry the format name only — the verbose
/// action lives in `help`, and hover feedback is the trackpad tick. Structured so more formats
/// slot in as sibling rows. When `enabled` is false (empty board) the row dims and is inert.
private struct ExportMenuRow: View {
  let label: String
  let help: String
  var enabled: Bool = true
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Text(label)
        .font(WindowChrome.labelFont)
        .lineLimit(1)
        .foregroundStyle(enabled ? Theme.Palette.body : Theme.Palette.chromeGlyphDim)
        .frame(maxWidth: .infinity)
        .frame(height: 30)   // matches BoardPickerRow, not controlHeight — menu rows are denser
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(!enabled)
    .onHover { if $0, enabled { Haptics.hover() } }
    .help(help)
  }
}

/// Live rubber-band preview shown while dragging out a shape/line with a placement tool.
private struct ElementDraftPreview: View {
  let kind: CanvasElementKind
  let start: CGPoint
  let end: CGPoint

  var body: some View {
    let r = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                   width: abs(end.x - start.x), height: abs(end.y - start.y))
    path(in: r).stroke(
      Theme.Palette.accent.opacity(0.9),
      style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round, dash: dash))
  }

  private var dash: [CGFloat] { (kind == .line || kind == .arrow) ? [] : [6, 4] }

  private func path(in r: CGRect) -> Path {
    switch kind {
    case .line, .arrow:
      return Path { p in
        p.move(to: start)
        p.addLine(to: end)
        // Draw the same arrowhead the committed arrow uses (`LineShape`: head 15, splay ±0.82π), so
        // the preview reads exactly as the final arrow instead of a bare segment.
        if kind == .arrow {
          let angle = atan2(end.y - start.y, end.x - start.x)
          let head: CGFloat = 15
          for side in [CGFloat.pi * 0.82, -CGFloat.pi * 0.82] {
            p.move(to: end)
            p.addLine(to: CGPoint(x: end.x + cos(angle + side) * head, y: end.y + sin(angle + side) * head))
          }
        }
      }
    case .equation, .graph:
      // Neither drag-places (equations click-to-place; graphs come from converting a line/arrow),
      // so this preview is only ever hit for exhaustiveness — a plain rounded box if it ever renders.
      return Path(roundedRect: r, cornerRadius: 6)
    case .ellipse:
      return Path(ellipseIn: r)
    case .diamond:
      return Path { p in
        p.move(to: CGPoint(x: r.midX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.midY))
        p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.midY))
        p.closeSubpath()
      }
    default:
      return Path(roundedRect: r, cornerRadius: 6)
    }
  }
}

private struct Toast: Identifiable, Equatable {
  let id = UUID()
  let text: String
  let symbol: String
  let tint: Color
}
