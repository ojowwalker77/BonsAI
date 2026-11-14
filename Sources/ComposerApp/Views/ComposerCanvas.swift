import AppKit
import SwiftUI
import SwiftData
import UniformTypeIdentifiers

private struct PendingBoardDeletion: Identifiable {
  let boardID: PersistentIdentifier
  let title: String

  var id: String { String(describing: boardID) }
}

/// The entire app surface: a pan/zoom board of cards filling the window, with floating glass
/// chrome — the board picker top-left, export top-right, and one bottom command bar. Per-card
/// editor chrome (the selection bar) is routed to the active card.
struct ComposerCanvas: View {
  @ObservedObject private var workspace: CanvasWorkspaceSession
  @ObservedObject private var store: DumpStore
  @ObservedObject private var board: BoardViewModel
  @ObservedObject private var userFacingErrors = UserFacingErrorStore.shared
  @AppStorage(ComposerPreferences.helperLinesEnabledKey) private var helperLinesEnabled = false
  @AppStorage(ComposerPreferences.continuousDrawingEnabledKey) private var continuousDrawingEnabled
    = ComposerPreferences.defaultContinuousDrawingEnabled
  @AppStorage(ComposerPreferences.dotGridEnabledKey) private var dotGridEnabled = false

  @State private var tool: CanvasTool = .select
  @State private var toast: Toast?
  @State private var lastViewportSize: CGSize = .zero
  /// Bumped on text-size/font-family changes: `.id()` on the board subtree remounts it (fonts and
  /// measurement caches re-resolve) WITHOUT tearing down the whole canvas the way a theme rebuild
  /// does — the Settings overlay (where these controls live) keeps its identity and scroll.
  @State private var typographyRevision = 0
  @State private var selectionRect: CGRect?
  /// True while an EXTERNAL image drag (Finder etc.) is hovering the canvas — drives the
  /// drop-target treatment. In-canvas card drags never set this (onDrop's isTargeted only
  /// fires for external content).
  @State private var isImageDropTargeted = false
  @State private var drawingDraftState = CanvasDrawingDraftState()
  /// While drawing a line/arrow, the card its live end will bind to on release — highlighted so the
  /// bind is visible before commit. Shares `board.bindCandidate` with the commit path, so the
  /// preview and the actual binding can never disagree.
  @State private var isSpacePressed = false
  @State private var viewportThrottle = ViewportEventThrottle()
  @ObservedObject private var updater = UpdaterController.shared
  /// A board delete is only executed by the destructive action in this confirmation surface.
  @State private var pendingBoardDeletion: PendingBoardDeletion?
  /// AppKit may deliver Escape through both keyDown and cancelOperation for one physical press.
  /// Resetting on the next run-loop turn keeps the command one-shot without swallowing the next key.
  @State private var escapeHandledThisTurn = false
  /// The ⌘K command palette (board switcher + buried board-level actions) is showing.
  @State private var showPalette = false
  /// The tint swatch row in the bottom bar is expanded.
  @State private var tintPickerOpen = false
  /// The single board picker expands downward on hover. A grace timer prevents flicker while the
  /// pointer crosses into its rows; rename and delete-confirmation state pin it open.
  @State private var boardPickerOpen = false
  @State private var boardPickerHovering = false
  @State private var boardPickerCloseWork: DispatchWorkItem?
  /// The export pill grows on hover into a list of export formats (same mechanic as the board
  /// picker). Open immediate, close deferred so the glyph→row gap doesn't flicker.
  @State private var exportMenuOpen = false
  @State private var exportMenuCloseWork: DispatchWorkItem?
  /// Measured rest-label width of the Export pill; its expanded list pins to this so hovering
  /// only grows the surface downward, never sideways.
  @State private var exportRestWidth: CGFloat = 0
  /// Board rename stays owned by the canvas so persistence failures keep the attempted name visible
  /// and Escape participates in the workspace's single dismissal coordinator.
  @State private var renamingBoardID: PersistentIdentifier?
  @State private var boardNameDraft = ""
  @FocusState private var boardNameFocused: Bool
  /// The card that held the caret when the palette was summoned, captured before the palette's
  /// search field steals first responder — so a cancel can hand editing back to it.
  @State private var paletteReturnCardID: UUID?

  // Board transform. Committed scale/pan live in the retained workspace so changing the theme or
  // language does not teleport the user back to the origin. The in-flight gesture remains local.
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

  private let cardPasteboardType = NSPasteboard.PasteboardType("dev.jow.Composer.cards")

  init(workspace: CanvasWorkspaceSession) {
    self.workspace = workspace
    store = workspace.store
    board = workspace.board
  }

  private var scale: CGFloat {
    get { workspace.scale }
    nonmutating set { workspace.scale = newValue }
  }

  private var pan: CGSize {
    get { workspace.pan }
    nonmutating set { workspace.pan = newValue }
  }

  private var freehandDraft: [CGPoint]? {
    get { drawingDraftState.freehand }
    nonmutating set {
      var state = drawingDraftState
      state.freehand = newValue
      drawingDraftState = state
    }
  }

  private var vectorDraft: VectorPathDraft? {
    get { drawingDraftState.vector }
    nonmutating set {
      var state = drawingDraftState
      state.vector = newValue
      drawingDraftState = state
    }
  }

  private var elementDraft: DragSegment? {
    get { drawingDraftState.element }
    nonmutating set {
      var state = drawingDraftState
      state.element = newValue
      drawingDraftState = state
    }
  }

  private var bindTargetID: UUID? {
    get { drawingDraftState.bindTargetID }
    nonmutating set {
      var state = drawingDraftState
      state.bindTargetID = newValue
      drawingDraftState = state
    }
  }

  private var effectiveScale: CGFloat { scale }

  var body: some View {
    GeometryReader { proxy in canvasRoot(proxy: proxy) }
    .ignoresSafeArea()
    .animation(Theme.Motion.accessory, value: showPalette)
    .onChange(of: userFacingErrors.latest) { _, notice in
      if notice != nil { showLatestReportedError() }
    }
    .onReceive(NotificationCenter.default.publisher(for: .composerFontSizeChanged)) { _ in
      typographyRevision += 1
    }
    .onReceive(NotificationCenter.default.publisher(for: .composerFontFamilyChanged)) { _ in
      typographyRevision += 1
    }
    .confirmationDialog(
      "Delete board".localizedUI,
      isPresented: Binding(
        get: { pendingBoardDeletion != nil },
        set: {
          if !$0 {
            pendingBoardDeletion = nil
            scheduleBoardPickerCloseIfNeeded()
          }
        }
      ),
      titleVisibility: .visible,
      presenting: pendingBoardDeletion
    ) { pending in
      Button("Delete Board".localizedUI, role: .destructive) {
        confirmBoardDeletion(pending)
      }
      Button("Cancel".localizedUI, role: .cancel) {}
    } message: { pending in
      Text("Delete \"%@\" permanently? This cannot be undone.".localizedUI(pending.title))
    }
  }

  @ViewBuilder
  private func canvasRoot(proxy: GeometryProxy) -> some View {
    let inner = proxy.size
    ZStack(alignment: .topLeading) {
      ZStack(alignment: .topLeading) {
        ComposerPanelBackground()
        boardContent(viewportSize: inner)
        // Wash only board content. Drafts, toasts, and active-card overlays stay above the fade so
        // their own surfaces keep their intended contrast.
        CanvasTopFade()
        toastView
      }
      .frame(width: inner.width, height: inner.height, alignment: .topLeading)
      .id(typographyRevision)

      // Active-card overlays resolve through screen → window space, so they live in
      // full-window coordinates and keep working while the board itself is transformed.
      if let editing = board.editingInteraction {
        ActiveCardOverlays(
          card: editing,
          size: proxy.size,
          currentTint: board.cards.first(where: { $0.id == editing.id })?.tint,
          onFormat: { editing.controller.applyMarkdown($0) },
          onTint: { slot in
            // A live text selection inks just that range; a bare caret falls back to whole-card tint.
            if editing.controller.applyInk(slot) {
              board.noteInkChanged(cardID: editing.id)
            } else {
              board.setTint(slot, for: editing.id)
            }
          }
        )
        .id(editing.id)
      }

      // Floating chrome: board identity top-left (the pill IS the board manager), export top-right,
      // everything hands-on (tools, zoom, settings) in one bottom command bar.
      // The promotion chip floats above the cards but below the command bar/pills and Settings
      // — it's a whisper over the canvas, not chrome that competes with the tools.
      promotionOverlay(in: inner)
      if !showPalette {
        boardSwitcherPill(in: proxy.size)
          .transition(.opacity)
      }
      boardActionsPill(in: proxy.size)
      protectedBoardBanner(in: proxy.size)
      bottomCommandBar(fit: inner)
      dockOverlay(in: proxy.size)
      editingStageOverlay(in: proxy.size)
      commandPaletteOverlay(in: proxy.size)
      commandBridge
    }
    .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
    .onAppear {
      lastViewportSize = inner
      CanvasBridge.shared.register(board)
      showLatestReportedError()
    }
    .onChange(of: inner) { _, value in lastViewportSize = value }
    // Promotion lifecycle: a tool change starts a fresh intent, so any live chip is stale.
    .onChange(of: tool) { _, selectedTool in
      dismissPromotion()
      if selectedTool != .vectorPen { vectorDraft = nil }
    }
    // Editing a card owns the screen; while a stage is open the chip must not hover behind it. When
    // a text card's edit session ENDS (editingCardID → nil), evaluate it for a text promotion.
    .onChange(of: board.editingCardID) { previous, current in
      if current != nil { dismissPromotion() }
      else if let previous { evaluateTextPromotion(previous) }
    }
    // Selection change away from the offer's card retracts it; a single text selection can arm one.
    .onChange(of: board.selectedCardIDs) { _, _ in
      promotionSelectionChanged()
    }
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
      .onReceive(NotificationCenter.default.publisher(for: .composerZoomOut)) { _ in zoom(0.8, anchoredAt: viewportCenter) }
      .onReceive(NotificationCenter.default.publisher(for: .composerZoomIn)) { _ in zoom(1.25, anchoredAt: viewportCenter) }
      .onReceive(NotificationCenter.default.publisher(for: .composerZoomReset)) { _ in resetZoom() }
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
      // Scroll forwarded from a card under the cursor — keep the board panning & zooming.
      .onReceive(NotificationCenter.default.publisher(for: .composerCanvasScroll)) { note in
        if let factor = note.userInfo?["zoom"] as? CGFloat {
          handleZoom(factor, anchoredAt: pointerViewportLocation() ?? viewportCenter)
          return
        }
        let dx = (note.userInfo?["dx"] as? CGFloat) ?? 0
        let dy = (note.userInfo?["dy"] as? CGFloat) ?? 0
        handleScroll(CGSize(width: dx, height: dy))
      }
      .onReceive(NotificationCenter.default.publisher(for: .composerSelectTool)) { note in
        if let selectedTool = note.userInfo?["tool"] as? CanvasTool {
          tool = selectedTool
        }
      }
      .onReceive(NotificationCenter.default.publisher(for: .composerToggleToolLock)) { _ in
        continuousDrawingEnabled.toggle()
        Haptics.level()
      }
      .onReceive(NotificationCenter.default.publisher(for: .composerTogglePalette)) { _ in
        togglePalette()
      }
      .onReceive(NotificationCenter.default.publisher(for: .composerToggleFocus)) { _ in
        toggleFocus()
      }
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
        onVectorNodeChanged: updateVectorNode,
        onVectorNodeEnded: finishVectorNode,
        onVectorHoverChanged: updateVectorHover,
        onVectorCommitOpen: commitOpenVectorDraft,
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

      if dotGridEnabled {
        CanvasDotGrid(
          scale: effectiveScale,
          translation: CGSize(
            width: pan.width + panLive.width,
            height: pan.height + panLive.height))
      }

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
      vectorDraftView
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
    if helperLinesEnabled, !board.snapGuides.isEmpty {
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

  @ViewBuilder
  private var vectorDraftView: some View {
    if let draft = vectorDraft {
      let transform = CGAffineTransform(
        a: effectiveScale,
        b: 0,
        c: 0,
        d: effectiveScale,
        tx: pan.width + panLive.width,
        ty: pan.height + panLive.height)
      Path(draft.previewPath)
        .applying(transform)
        .stroke(
          currentTintColor ?? Theme.Palette.inkStroke,
          style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
        .shadow(color: .black.opacity(0.22), radius: 5, y: 2)
        .allowsHitTesting(false)

      ForEach(Array(draft.anchorPoints.enumerated()), id: \.offset) { index, point in
        Circle()
          .fill(index == 0 ? Theme.Palette.accent : Theme.Palette.labelChipFill)
          .overlay(Circle().strokeBorder(Theme.Palette.accent, lineWidth: 1.5))
          .frame(width: index == 0 && draft.nodeCount >= 3 ? 10 : 8,
                 height: index == 0 && draft.nodeCount >= 3 ? 10 : 8)
          .position(
            x: point.x * effectiveScale + pan.width + panLive.width,
            y: point.y * effectiveScale + pan.height + panLive.height)
          .allowsHitTesting(false)
      }
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
    if kind == .line || kind == .arrow || kind == .freehand || kind == .vectorPath { return }
    let boardPoint = CGPoint(x: (point.x - pan.width) / effectiveScale,
                             y: (point.y - pan.height) / effectiveScale)
    let id = board.addElement(kind, at: boardPoint)
    tool = tool.afterSuccessfulPlacement(continuousDrawing: continuousDrawingEnabled)
    // Editing state is established synchronously so navigation cannot race the stage's own focus
    // delay and persist an abandoned structured card before its editor mounts.
    if kind == .text || kind == .equation || kind == .sticky || kind == .checklist || kind == .table {
      board.beginEditing(id)
    }
  }

  /// Double-clicking empty canvas (a click sequence begun with Select) drops a text element there
  /// and starts editing — the "just start writing" gesture. The inline editor takes the caret
  /// itself when it mounts (`ComposerTextView.focusesWhenAttached`).
  private func handleDoubleTap(at point: CGPoint) {
    let id = board.addCard(at: boardPoint(forViewport: point))
    tool = .select
    board.beginEditing(id)
  }

  /// The draft segment changed (viewport space). Store it, and for a line/arrow resolve the card its
  /// live end would bind to — under the CURRENT drag endpoint, converted to board space — so the
  /// highlight tracks the cursor and matches exactly what connector finalization does on commit.
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
      tool = tool.afterSuccessfulPlacement(continuousDrawing: continuousDrawingEnabled)
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
      tool = tool.afterSuccessfulPlacement(continuousDrawing: continuousDrawingEnabled)
      // Auto-snap (Settings ▸ Drawing): a confident read converts on pen-up, no chip — the rough
      // stroke stays its own undo step, so ⌘Z restores the original ink like OneNote. Arrows are
      // EXCLUDED from auto conversion: too many ordinary strokes read as arrow-with-a-hook and
      // kept snapping under the pen (1.4.5 feedback) — an arrow read falls back to the chip, so
      // it's one click when it's actually wanted.
      if ComposerPreferences.autoSnapFreehand,
         let recognition = ShapeRecognizer.recognize(boardPoints),
         !recognition.kind.isArrow {
        board.convertFreehand(id, to: recognition.kind)
      } else {
        // The flagship promotion: a confidently recognized stroke offers to become that clean shape.
        offerFreehandPromotion(id, boardPoints: boardPoints)
      }
    }
  }

  private func updateVectorNode(_ viewportAnchor: CGPoint, _ viewportDrag: CGPoint) {
    if promotion != nil { dismissPromotion() }
    var draft = vectorDraft ?? VectorPathDraft()
    draft.update(
      anchor: boardPoint(forViewport: viewportAnchor),
      drag: boardPoint(forViewport: viewportDrag))
    vectorDraft = draft
  }

  private func finishVectorNode(_ viewportAnchor: CGPoint, _ viewportDrag: CGPoint) {
    guard var draft = vectorDraft else { return }
    let placement = draft.finish(
      anchor: boardPoint(forViewport: viewportAnchor),
      drag: boardPoint(forViewport: viewportDrag),
      closeTolerance: 10 / max(effectiveScale, 0.01))
    if let placement {
      commitVectorPlacement(placement)
    } else {
      vectorDraft = draft
    }
  }

  private func updateVectorHover(_ viewportPoint: CGPoint?) {
    guard var draft = vectorDraft else { return }
    draft.hover(at: viewportPoint.map(boardPoint(forViewport:)))
    vectorDraft = draft
  }

  private func commitOpenVectorDraft() {
    guard let placement = vectorDraft?.commitOpen() else { return }
    commitVectorPlacement(placement)
  }

  private func commitVectorPlacement(_ placement: VectorPathPlacement) {
    vectorDraft = nil
    guard board.addVectorPath(placement) != nil else { return }
    tool = tool.afterSuccessfulPlacement(continuousDrawing: continuousDrawingEnabled)
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

  @ViewBuilder
  private func protectedBoardBanner(in size: CGSize) -> some View {
    if let protection = store.currentBoardProtection {
      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 8) {
          Image(systemName: "lock.trianglebadge.exclamationmark")
            .font(WindowChrome.iconFont)
            .foregroundStyle(.orange)
          Text("This board's original data is protected. Changes on this fallback are not saved.".localizedUI)
            .font(WindowChrome.labelFont)
            .foregroundStyle(Theme.Palette.body)
            .lineLimit(2)
          Spacer(minLength: 8)
          if let recoveryURL = protection.recoveryURL {
            Button("Show Recovery".localizedUI) {
              NSWorkspace.shared.activateFileViewerSelecting([recoveryURL])
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.Palette.chromeText)
          }
          Button("Duplicate to Edit".localizedUI) {
            if board.duplicateProtectedBoardForEditing() {
              resetView()
              show(Toast(
                text: "Created an editable copy; the original board remains unchanged.".localizedUI,
                symbol: "doc.on.doc.fill",
                tint: .accentColor
              ))
            }
          }
          .buttonStyle(.plain)
          .foregroundStyle(Theme.Palette.accent)
        }
        if let recoveryURL = protection.recoveryURL {
          Text("Recovery copy: %@".localizedUI(recoveryURL.path))
            .font(Theme.Typography.count)
            .foregroundStyle(Theme.Palette.title)
            .lineLimit(1)
            .truncationMode(.middle)
        }
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 10)
      .frame(maxWidth: min(720, max(280, size.width - WindowChrome.edgeInset * 2)))
      .composerPopupSurface()
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
      .padding(.top, WindowChrome.edgeInset + WindowChrome.controlHeight + WindowChrome.padV * 2 + 10)
      .zIndex(70)
    }
  }

  /// The current board's name rests in one top-left pill. Hovering the same surface expands it
  /// downward into board management; it never becomes a tab row or changes workspace geometry.
  private func boardSwitcherPill(in size: CGSize) -> some View {
    boardPickerMenu(viewportWidth: size.width)
      // Constrain pointer ownership while this view still has the popup's intrinsic bounds. The
      // following alignment frame intentionally fills the window for positioning only; giving it
      // the interaction shape would let transparent canvas space win hit testing over the board.
      .contentShape(
        .interaction,
        RoundedRectangle(cornerRadius: WindowChrome.radius, style: .continuous))
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .padding(.top, WindowChrome.edgeInset)
      .padding(.leading, WindowChrome.trafficLightInset)
      // The protected-board banner sits at 70 below this rest row. An expanded picker must remain
      // visually and interactively above it, especially at the 640pt window minimum.
      .zIndex(boardPickerOpen ? 80 : 60)
  }

  private var currentBoardName: String {
    let name = store.current?.title.trimmed ?? ""
    guard !name.isEmpty else { return "Untitled".localizedUI }
    return name
  }

  /// Fixed-width rest label: the expanded list grows only downward, never sideways.
  private var boardPickerTitle: String {
    let name = currentBoardName
    return name.count > 13 ? String(name.prefix(13)) + "…" : name
  }

  @ViewBuilder
  private func currentBoardTitleRow(canDelete: Bool, contentWidth: CGFloat) -> some View {
    if renamingBoardID == store.currentID {
      TextField("Board name".localizedUI, text: $boardNameDraft)
        .textFieldStyle(.plain)
        .font(WindowChrome.labelFont)
        .foregroundStyle(Theme.Palette.body)
        .multilineTextAlignment(.center)
        .focused($boardNameFocused)
        .onSubmit { _ = commitBoardRename() }
        .onExitCommand(perform: handleEscapeBoard)
        .frame(width: contentWidth, height: WindowChrome.controlHeight)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.Palette.rowFill))
        .onAppear { DispatchQueue.main.async { boardNameFocused = true } }
        .onChange(of: boardNameFocused) { _, focused in
          if !focused { _ = commitBoardRename() }
        }
    } else {
      Button(action: toggleBoardPicker) {
        Text(boardPickerOpen ? currentBoardName : boardPickerTitle)
          .font(WindowChrome.labelFont)
          .foregroundStyle(Theme.Palette.body)
          .lineLimit(1)
          .frame(width: contentWidth, height: WindowChrome.controlHeight)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help(currentBoardName)
      .accessibilityLabel(Text(currentBoardName))
      .accessibilityValue(Text((boardPickerOpen ? "Expanded" : "Collapsed").localizedUI))
      .accessibilityHint(Text("Switch board".localizedUI))
      .accessibilityActions {
        Button("Rename board".localizedUI) {
          guard let id = store.currentID, commitBoardRename() else { return }
          beginBoardRename(id, title: store.current?.title ?? "")
        }
        if canDelete, let id = store.currentID {
          Button("Delete board".localizedUI) {
            requestBoardDeletion(id, title: store.current?.title ?? "")
          }
        }
      }
      .contextMenu {
        Button("Rename Board".localizedUI) {
          guard let id = store.currentID, commitBoardRename() else { return }
          beginBoardRename(id, title: store.current?.title ?? "")
        }
        if canDelete, let id = store.currentID {
          Button("Delete Board".localizedUI, role: .destructive) {
            requestBoardDeletion(id, title: store.current?.title ?? "")
          }
        }
      }
    }
  }

  /// One glass surface: current board at rest; other boards and New Board below on hover.
  private func boardPickerMenu(viewportWidth: CGFloat) -> some View {
    let others = store.dumps.filter { $0.persistentModelID != store.currentID }
    let expandedContentWidth = BoardPickerLayoutPolicy.expandedContentWidth(
      viewportWidth: viewportWidth)
    let contentWidth = boardPickerOpen ? expandedContentWidth : WindowChrome.boardPillWidth
    return VStack(alignment: .leading, spacing: WindowChrome.itemSpacing) {
      currentBoardTitleRow(canDelete: !others.isEmpty, contentWidth: contentWidth)

      if boardPickerOpen {
        VStack(alignment: .leading, spacing: WindowChrome.itemSpacing) {
          Divider().overlay(Theme.Palette.separator).padding(.horizontal, 2)

          if !others.isEmpty {
            ScrollView {
              LazyVStack(alignment: .leading, spacing: WindowChrome.itemSpacing) {
                ForEach(others, id: \.persistentModelID) { dump in
                  let id = dump.persistentModelID
                  BoardPickerRow(
                    title: dump.title.isEmpty ? "Untitled".localizedUI : dump.title,
                    isRenaming: renamingBoardID == id,
                    draftName: $boardNameDraft,
                    nameFocused: $boardNameFocused,
                    onPick: {
                      guard commitBoardRename() else { return }
                      pickBoard(id)
                      if store.currentID == id { boardPickerOpen = false }
                    },
                    onBeginRename: {
                      guard commitBoardRename() else { return }
                      beginBoardRename(id, title: dump.title)
                    },
                    onCommitRename: { _ = commitBoardRename() },
                    onCancelRename: handleEscapeBoard,
                    onDelete: { requestBoardDeletion(id, title: dump.title) }
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
        .frame(width: expandedContentWidth)
      }
    }
    .frame(width: contentWidth, alignment: .leading)
    .padding(.horizontal, WindowChrome.padH)
    .padding(.vertical, WindowChrome.padV)
    .composerPopupSurface()
    .onHover { setBoardPickerHover($0) }
    .animation(.easeOut(duration: 0.16), value: boardPickerOpen)
    .help(boardPickerOpen ? "" : "Switch board".localizedUI)
  }

  private var newBoardRow: some View {
    Button {
      let previousID = store.currentID
      newBoard()
      if store.currentID != previousID { boardPickerOpen = false }
    } label: {
      HStack(spacing: 6) {
        Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
        Text("New board".localizedUI).font(WindowChrome.labelFont)
        Spacer(minLength: 0)
      }
      .foregroundStyle(Theme.Palette.body)
      .padding(.horizontal, WindowChrome.labelPadH)
      .frame(maxWidth: .infinity)
      .frame(height: WindowChrome.boardPickerRowHeight)
      .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.Palette.rowFill))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help("New board  ⌘N".localizedUI)
  }

  private func beginBoardRename(_ id: PersistentIdentifier, title: String) {
    boardNameDraft = title.isEmpty ? "Untitled".localizedUI : title
    renamingBoardID = id
    boardPickerCloseWork?.cancel()
    boardPickerCloseWork = nil
    boardPickerOpen = true
  }

  @discardableResult
  private func commitBoardRename() -> Bool {
    guard let id = renamingBoardID else { return true }
    let name = boardNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else {
      renamingBoardID = nil
      scheduleBoardPickerCloseIfNeeded()
      return true
    }
    if renameBoard(id, to: name) {
      renamingBoardID = nil
      scheduleBoardPickerCloseIfNeeded()
      return true
    } else {
      // Keep the editor and the attempted value visible so the user can retry after fixing storage.
      DispatchQueue.main.async { boardNameFocused = true }
      return false
    }
  }

  private func cancelBoardRename() {
    renamingBoardID = nil
    scheduleBoardPickerCloseIfNeeded()
  }

  private func setBoardPickerHover(_ hovering: Bool) {
    boardPickerHovering = hovering
    boardPickerCloseWork?.cancel()
    boardPickerCloseWork = nil
    if hovering {
      if !boardPickerOpen { Haptics.hover() }
      boardPickerOpen = true
    } else {
      scheduleBoardPickerCloseIfNeeded()
    }
  }

  private func toggleBoardPicker() {
    boardPickerCloseWork?.cancel()
    boardPickerCloseWork = nil
    if boardPickerOpen,
       BoardPickerPresentationPolicy.canClose(
         isHovering: false,
         hasActiveRename: renamingBoardID != nil,
         hasDeleteConfirmation: pendingBoardDeletion != nil
       ) {
      boardPickerOpen = false
    } else {
      boardPickerOpen = true
    }
  }

  private func closeBoardPicker() {
    boardPickerCloseWork?.cancel()
    boardPickerCloseWork = nil
    withAnimation(.easeOut(duration: 0.16)) { boardPickerOpen = false }
  }

  private func scheduleBoardPickerCloseIfNeeded() {
    boardPickerCloseWork?.cancel()
    boardPickerCloseWork = nil
    guard !boardPickerHovering else { return }
    let work = DispatchWorkItem {
      guard BoardPickerPresentationPolicy.canClose(
        isHovering: boardPickerHovering,
        hasActiveRename: renamingBoardID != nil,
        hasDeleteConfirmation: pendingBoardDeletion != nil
      ) else { return }
      boardPickerOpen = false
    }
    boardPickerCloseWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
  }

  /// The top-right chrome: an Export pill that hover-expands downward (`.top` alignment keeps its
  /// rest label anchored while it grows).
  /// When a scheduled check finds a new release, an Update pill appears at the far left — the one
  /// accent-tinted control in the chrome, so it reads as the single signal, not decoration.
  private func boardActionsPill(in size: CGSize) -> some View {
    HStack(alignment: .top, spacing: WindowChrome.itemSpacing) {
      if let version = updater.availableUpdateVersion {
        updatePill(version: version)
      }
      exportMenu
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

  /// Opening is immediate; closing waits a beat so crossing the glyph→row gap doesn't flicker.
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
  /// zoom · tools · tint · settings — tldraw-style, so the top stays calm (identity left,
  /// export right) and the bottom is a single strong grouping instead of scattered pills.
  private func bottomCommandBar(fit innerSize: CGSize) -> some View {
    return HStack(spacing: WindowChrome.itemSpacing) {
      SidebarButton(symbol: "minus.magnifyingglass", help: "Zoom out".localizedUI) { zoom(0.8, anchoredAt: viewportCenter) }
      Button(action: resetZoom) {
        Text("\(Int((effectiveScale * 100).rounded()))%")
          .font(WindowChrome.labelFont.monospacedDigit())
          .foregroundStyle(Theme.Palette.chromeText)
          .frame(width: 44, height: WindowChrome.controlHeight)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help("Reset to 100%".localizedUI)
      SidebarButton(symbol: "plus.magnifyingglass", help: "Zoom in".localizedUI) { zoom(1.25, anchoredAt: viewportCenter) }
      SidebarButton(symbol: "arrow.up.left.and.down.right.magnifyingglass", help: "Fit board".localizedUI) {
        withAnimation(Theme.Motion.accessory) { fitBoard(in: innerSize) }
      }

      barDivider

      CanvasToolbar(tool: $tool, continuousDrawingEnabled: $continuousDrawingEnabled)

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
  /// opens a stage from `editingCardID`; vector paths edit their nodes inline, and freehand/image
  /// never open an editor at all.
  @ViewBuilder
  private func editingStageOverlay(in size: CGSize) -> some View {
    if let id = focusedCardID,
       let card = board.cards.first(where: { $0.id == id }), card.elementKind == .text {
      EditingStage(
        board: board,
        card: card,
        interaction: board.interaction(for: id),
        size: size,
        onClose: { closeFocus() }
      )
      .id(id)
    } else if let id = board.editingCardID,
       let card = board.cards.first(where: { $0.id == id }),
       EditingStagePresentationPolicy.presentsStage(for: card.elementKind) {
      EditingStage(
        board: board,
        card: card,
        interaction: board.interaction(for: id),
        size: size,
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

  /// Settings presents as a centered glass sheet over a click-away scrim.
  @ViewBuilder
  private func dockOverlay(in size: CGSize) -> some View {
    if store.isSettingsOpen {
      SettingsOverlay(
        canvasSize: size,
        onClose: { toggleSettings() },
        onEscape: { handleEscapeBoard() }
      )
        .transition(.opacity)
        .zIndex(40)
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

  /// Board zoom is clamped to 10%–400% (Fit applies its own ≤100% cap so it never enlarges). The
  /// low end lets Fit frame a large board; the dot grid thins itself to stay inside its budget.
  private func clampZoom(_ value: CGFloat) -> CGFloat { min(max(value, 0.1), 4) }

  private var viewportCenter: CGPoint {
    CGPoint(x: lastViewportSize.width / 2, y: lastViewportSize.height / 2)
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
  /// TEXT editing lives ON the board, so pan/zoom stays live there.
  private func allowPanZoom() -> Bool {
    guard let id = board.editingCardID,
          let kind = board.cards.first(where: { $0.id == id })?.elementKind else { return true }
    return kind == .text
  }

  /// Toolbar and keyboard zoom anchor at the viewport centre (the pointer is on the command bar
  /// or nowhere useful); wheel and pinch pass the pointer instead.
  private func zoom(_ factor: CGFloat, anchoredAt point: CGPoint) {
    setScale(max(scale, 0.01) * factor, anchoredAt: point)
  }

  /// Change the zoom while keeping the board point under `point` fixed on screen.
  private func setScale(_ target: CGFloat, anchoredAt point: CGPoint) {
    guard allowViewportTransform() else { return }
    let oldScale = max(scale, 0.01)
    let nextScale = clampZoom(target)
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
    guard allowViewportTransform() else { return }
    viewportThrottle.enqueueScroll(delta, canApply: allowViewportTransform) { applied in
      pan.width += applied.width
      pan.height += applied.height
    }
  }

  private func handleZoom(_ factor: CGFloat, anchoredAt point: CGPoint) {
    guard allowViewportTransform() else { return }
    viewportThrottle.enqueueZoom(
      factor, anchoredAt: point, canApply: allowViewportTransform
    ) { appliedFactor, anchor in
      zoom(appliedFactor, anchoredAt: anchor)
    }
  }

  /// Checks both modal editing and pointer ownership. The throttle calls this again immediately
  /// before applying deferred work: an event accepted just before a drawing press must not move the
  /// captured viewport transform after that press begins.
  private func allowViewportTransform() -> Bool {
    guard CanvasViewportTransformPolicy.allowsPanOrZoom(
      during: CanvasKeyState.shared.viewportDragMode) else { return false }
    return allowPanZoom()
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
    guard allowViewportTransform() else { return }
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

  /// Keyboard and menu reset commands obey the same pointer-ownership gate as wheel/pinch input.
  /// Otherwise a Pen press could capture one transform for its preview and commit under another.
  /// 100%, anchored at the viewport centre so the content under it stays put instead of jumping.
  private func resetZoom() {
    withAnimation(Theme.Motion.accessory) { setScale(1, anchoredAt: viewportCenter) }
  }


  /// Reset everything tied to the outgoing board. Drawing drafts are view-local rather than part
  /// of `BoardViewModel`, so every path that replaces its cards must explicitly discard them here;
  /// otherwise a pen path begun on one board could finish onto the next board.
  private func resetView() {
    scale = 1
    pan = .zero
    panLive = .zero
    var drafts = drawingDraftState
    drafts.cancelForBoardReplacement()
    drawingDraftState = drafts
    dismissPromotion()
  }

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

  private var canEditBoard: Bool {
    guard !store.isSettingsOpen else { return false }
    return board.editingInteraction == nil
  }

  private func handlePrevDump() { gotoOlder() }
  private func handleNextDump() { gotoNewer() }
  private func handleNewDump() { newBoard() }

  private func handleDeleteSelection() { if canEditBoard { board.deleteSelection() } }
  private func handleDuplicateSelection() { if canEditBoard { board.duplicateSelection() } }
  private func handleCopySelection() { if canEditBoard { copySelectedCards() } }
  private func handlePasteSelection() { if canEditBoard { pasteSelectedCards() } }
  private func handleSelectAllCards() { if canEditBoard { board.selectAll() } }
  private func handleEscapeBoard() {
    guard !escapeHandledThisTurn else { return }
    escapeHandledThisTurn = true
    DispatchQueue.main.async { escapeHandledThisTurn = false }

    let activeEditorKind = board.editingCardID.flatMap { id in
      board.cards.first(where: { $0.id == id })?.elementKind
    }
    let target = ComposerEscapeCoordinator.target(for: ComposerEscapeState(
      hasBoardDeletionConfirmation: pendingBoardDeletion != nil,
      hasBoardRename: renamingBoardID != nil,
      hasBoardPicker: boardPickerOpen,
      hasCommandPalette: showPalette,
      hasFocusedEditor: focusedCardID != nil,
      hasPromotion: promotion != nil,
      hasSettings: store.isSettingsOpen,
      hasActiveEditor: board.editingInteraction != nil,
      hasActiveVectorEditor: activeEditorKind == .vectorPath,
      hasDrawingDraft: elementDraft != nil || freehandDraft != nil || vectorDraft != nil,
      hasTintPicker: tintPickerOpen,
      hasActiveTool: tool != .select,
      hasSelection: !board.selectedCardIDs.isEmpty
    ))

    switch target {
    case .boardDeletionConfirmation:
      pendingBoardDeletion = nil
      scheduleBoardPickerCloseIfNeeded()
    case .boardRename:
      cancelBoardRename()
    case .boardPicker:
      closeBoardPicker()
    case .commandPalette:
      dismissPalette()
    case .focusedEditor:
      closeFocus()
    case .promotion:
      dismissPromotion()
    case .auxiliaryPanel:
      closeAuxiliaryPanel()
    case .activeEditor:
      // Inline text and structured stages own their draft cancellation. The window-level command
      // must stop here rather than dismissing the workspace behind an active editor. Vector nodes
      // are the one inline non-text editor, so Escape explicitly ends that session here.
      if let id = board.editingCardID,
         board.cards.first(where: { $0.id == id })?.elementKind == .vectorPath {
        board.endEditing(id)
      }
      return
    case .drawingDraft:
      // The InputView listens for the same escape and drops its drag, so a pending mouse-up cannot
      // commit after this preview state is cleared.
      elementDraft = nil
      freehandDraft = nil
      vectorDraft = nil
      bindTargetID = nil
      tool = .select
    case .tintPicker:
      withAnimation(.easeOut(duration: 0.14)) { tintPickerOpen = false }
    case .activeTool:
      tool = .select
    case .selection:
      board.deselectAll()
    case .none:
      return
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

  private func gotoOlder() {
    guard store.canGoOlder else { return }
    guard commitBoardRename() else { return }
    guard checkpointBeforeLeavingCurrentBoard() else { return }
    store.goOlder(); board.loadFromStore(); resetView()
  }
  private func gotoNewer() {
    guard store.canGoNewer else { return }
    guard commitBoardRename() else { return }
    guard checkpointBeforeLeavingCurrentBoard() else { return }
    store.goNewer(); board.loadFromStore(); resetView()
  }
  private func newBoard() {
    // DumpStore intentionally refuses to stack blank boards. Match that no-op before ending the
    // active edit, including live text that has not reached the persisted dump yet.
    guard board.hasMeaningfulContent || store.current?.isBlank == false else { return }
    guard commitBoardRename() else { return }
    guard checkpointBeforeLeavingCurrentBoard() else { return }
    store.newDump(); board.loadFromStore(); resetView(); focusFirstCard()
  }
  private func pickBoard(_ id: PersistentIdentifier) {
    guard id != store.currentID,
          store.dumps.contains(where: { $0.persistentModelID == id }) else { return }
    guard commitBoardRename() else { return }
    guard checkpointBeforeLeavingCurrentBoard() else { return }
    store.select(id); board.loadFromStore(); resetView()
  }

  /// Protected recovery boards are deliberately read-only: their fallback edits are never saved,
  /// but that must not trap the user on the board. Editable boards still require a successful
  /// checkpoint before any action that replaces the working card array.
  private func checkpointBeforeLeavingCurrentBoard() -> Bool {
    store.currentBoardProtection != nil || board.flushSave(abandoningActiveEdit: true)
  }
  private func requestBoardDeletion(_ id: PersistentIdentifier, title: String) {
    guard store.dumps.count > 1,
          store.dumps.contains(where: { $0.persistentModelID == id }) else { return }
    boardPickerCloseWork?.cancel()
    boardPickerCloseWork = nil
    boardPickerOpen = true
    pendingBoardDeletion = PendingBoardDeletion(
      boardID: id,
      title: title.isEmpty ? "Untitled".localizedUI : title
    )
  }

  private func confirmBoardDeletion(_ pending: PendingBoardDeletion) {
    pendingBoardDeletion = nil
    scheduleBoardPickerCloseIfNeeded()
    guard commitBoardRename() else { return }
    let deletingCurrent = pending.boardID == store.currentID
    if deletingCurrent {
      // Deleting the open board swaps the canvas onto the next one, so checkpoint first: if
      // storage is failing, abort rather than tear down a board whose edits can't be saved.
      // Deletion is destructive, so unlike navigation it never bypasses protected recovery data.
      guard board.flushSave() else {
        show(Toast(
          text: "The board was not deleted because its latest changes could not be saved.".localizedUI,
          symbol: "exclamationmark.triangle.fill",
          tint: Theme.Palette.warning
        ))
        return
      }
    }
    guard store.delete(pending.boardID) else {
      show(Toast(
        text: "The board was not deleted. Your saved board is still available.".localizedUI,
        symbol: "exclamationmark.triangle.fill",
        tint: Theme.Palette.warning
      ))
      return
    }
    // Only a current-board delete moves the canvas to another board. Deleting a background board
    // must leave the working set alone — reloading here would clobber in-flight debounced edits
    // (loadFromStore replaces `cards` with the last persisted payload) and reset the viewport.
    if deletingCurrent {
      board.loadFromStore()
      resetView()
    }
  }
  // Rename only touches the board's name, never its cards — no flush/reload needed.
  private func renameBoard(_ id: PersistentIdentifier, to name: String) -> Bool {
    store.rename(id, to: name)
  }

  /// A fresh board's first card opens into its editing stage so the caret is ready. Only a text card
  /// has a caret-first stage; a non-text first card is left selected.
  private func focusFirstCard() {
    guard let id = board.cards.first?.id,
          board.cards.first(where: { $0.id == id })?.elementKind == .text else { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { board.beginEditing(id) }
  }

  /// The command-bar gear toggles Settings: a second click while Settings is up closes it again.
  /// (⌘, always opens.)
  private func toggleSettings() {
    if store.isSettingsOpen {
      withAnimation(Theme.Motion.accessory) { store.isSettingsOpen = false }
    } else {
      openSettings()
    }
  }

  private func openSettings() {
    withAnimation(Theme.Motion.accessory) { store.isSettingsOpen = true }
  }

  private func closeAuxiliaryPanel() {
    guard store.isSettingsOpen else { return }
    withAnimation(Theme.Motion.accessory) { store.isSettingsOpen = false }
  }

  // MARK: Command palette (⌘K)

  /// A spotlight over the board: a faint scrim catches a click-away dismiss; the palette itself
  /// floats near the top-center, like Spotlight. Lives only in the board window's SwiftUI tree, so
  /// it never disturbs the window geometry.
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
          onDismiss: { handleEscapeBoard() }
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
    // The picker temporarily sits above the protected-board banner. Collapse it before the palette
    // claims modal ownership at zIndex 50; a failed rename keeps both its editor and attempted value
    // visible instead of opening the palette behind it.
    guard commitBoardRename() else { return }
    closeBoardPicker()
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
  /// Apple Intelligence cleanup/classification swaps in when it's ready. Agents read either over the
  /// canvas API.
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
        show(Toast(text: "Screenshot read - agents can see its text".localizedUI, symbol: "checkmark.circle.fill", tint: .green))
        return
      } else {
        show(Toast(text: "Added screenshot - no text found".localizedUI, symbol: "photo", tint: .accentColor))
        return
      }

      // Stage 1: show the OCR text immediately so the card is useful within a beat.
      if !ocr.isEmpty {
        board.setImageUnderstanding(id, "[Screenshot]\n\(ocr)")
        show(Toast(text: "Screenshot read - agents can see its text".localizedUI, symbol: "checkmark.circle.fill", tint: .green))
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

/// A quiet board-space dot field rendered as one vector path. It sits above the pointer-input view
/// but below cards and live drawing previews, and never participates in hit testing or export.
private struct CanvasDotGrid: View {
  let scale: CGFloat
  let translation: CGSize

  var body: some View {
    Canvas { context, size in
      let layout = CanvasDotGridLayout.layout(
        scale: scale, translation: translation, viewportSize: size)
      let radius = min(max(scale, 0.7), 1.35)
      var dots = Path()

      for x in stride(from: layout.xAxis.first, through: size.width, by: layout.xAxis.spacing) {
        for y in stride(from: layout.yAxis.first, through: size.height, by: layout.yAxis.spacing) {
          dots.addEllipse(in: CGRect(x: x - radius, y: y - radius,
                                     width: radius * 2, height: radius * 2))
        }
      }
      context.fill(dots, with: .color(Theme.Palette.menuDesc.opacity(Theme.flavor.isDark ? 0.34 : 0.26)))
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}

@MainActor
final class ViewportEventThrottle {
  private var pendingScroll: CGSize = .zero
  private var scrollScheduled = false
  private var pendingZoomFactor: CGFloat = 1
  private var latestZoomAnchor: CGPoint = .zero
  private var zoomScheduled = false
  private let interval: TimeInterval = 1.0 / 120.0

  func enqueueScroll(
    _ delta: CGSize,
    canApply: @escaping () -> Bool = { true },
    apply: @escaping (CGSize) -> Void
  ) {
    pendingScroll.width += delta.width
    pendingScroll.height += delta.height
    guard !scrollScheduled else { return }
    scrollScheduled = true
    DispatchQueue.main.asyncAfter(deadline: .now() + interval) { [weak self] in
      guard let self else { return }
      let value = pendingScroll
      pendingScroll = .zero
      scrollScheduled = false
      guard value != .zero, canApply() else { return }
      apply(value)
    }
  }

  func enqueueZoom(
    _ factor: CGFloat,
    anchoredAt point: CGPoint,
    canApply: @escaping () -> Bool = { true },
    apply: @escaping (CGFloat, CGPoint) -> Void
  ) {
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
      guard factor != 1, canApply() else { return }
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
enum CanvasViewportDragMode: Equatable {
  case maybeTap
  case selecting
  case drawing
  case vectorPress
  case vectorDrawing
  case placing
  case panning
}

/// A draft's viewport-to-board conversion is captured when its press begins. Pan or zoom during
/// these modes would change that transform before commit and separate result from preview.
/// What one scroll event does to the board. Trackpads pan by their precise pixel deltas; a mouse
/// wheel reports whole lines, which are scaled to a useful distance (raw, one notch panned ~1pt);
/// and ⌘ or ⌃ + scroll zooms around the pointer, as in Excalidraw and every browser canvas.
enum CanvasScrollInput: Equatable {
  case pan(CGSize)
  case zoom(CGFloat)

  /// Board points one mouse-wheel line pans.
  static let wheelLinePoints: CGFloat = 32
  /// Zoom sensitivity per scrolled point (scroll toward the user zooms in).
  static let zoomPerPoint: CGFloat = 0.003

  init(deltaX: CGFloat, deltaY: CGFloat, hasPreciseDeltas: Bool, zoomModifier: Bool) {
    let scale = hasPreciseDeltas ? 1 : Self.wheelLinePoints
    let dx = deltaX * scale
    let dy = deltaY * scale
    if zoomModifier {
      // A single event never more than halves or doubles the zoom, however hard the flick.
      self = .zoom(min(max(exp(dy * Self.zoomPerPoint), 0.5), 2))
    } else {
      self = .pan(CGSize(width: dx, height: dy))
    }
  }

  init(_ event: NSEvent) {
    self.init(
      deltaX: event.scrollingDeltaX,
      deltaY: event.scrollingDeltaY,
      hasPreciseDeltas: event.hasPreciseScrollingDeltas,
      zoomModifier: !event.modifierFlags.intersection([.command, .control]).isEmpty)
  }
}

enum CanvasViewportTransformPolicy {
  static func allowsPanOrZoom(during mode: CanvasViewportDragMode) -> Bool {
    switch mode {
    case .drawing, .vectorPress, .vectorDrawing, .placing: false
    case .maybeTap, .selecting, .panning: true
    }
  }
}

/// Resolves pointer ownership synchronously at mouse-down, before any preview callback fires.
/// Pen clicks are real vector drafts even when they never cross AppKit's drag threshold, so they
/// freeze the viewport for the entire press rather than briefly masquerading as a generic tap.
enum CanvasPointerPressMode {
  static func resolve(tool: CanvasTool, isSpacePressed: Bool) -> CanvasViewportDragMode {
    if isSpacePressed { return .panning }
    if tool == .vectorPen { return .vectorPress }
    return .maybeTap
  }
}

final class CanvasKeyState: @unchecked Sendable {
  static let shared = CanvasKeyState()
  private init() {}
  var isSpaceDown = false
  var viewportDragMode: CanvasViewportDragMode = .maybeTap
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
  let onVectorNodeChanged: (CGPoint, CGPoint) -> Void
  let onVectorNodeEnded: (CGPoint, CGPoint) -> Void
  let onVectorHoverChanged: (CGPoint?) -> Void
  let onVectorCommitOpen: () -> Void
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
      onVectorNodeChanged: onVectorNodeChanged,
      onVectorNodeEnded: onVectorNodeEnded,
      onVectorHoverChanged: onVectorHoverChanged,
      onVectorCommitOpen: onVectorCommitOpen,
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
      var onVectorNodeChanged: (CGPoint, CGPoint) -> Void = { _, _ in }
      var onVectorNodeEnded: (CGPoint, CGPoint) -> Void = { _, _ in }
      var onVectorHoverChanged: (CGPoint?) -> Void = { _ in }
      var onVectorCommitOpen: () -> Void = {}
      var onElementDraftChanged: (CGPoint, CGPoint) -> Void = { _, _ in }
      var onElementDraftEnded: (CGPoint, CGPoint) -> Void = { _, _ in }
      var onElementDraftCancelled: () -> Void = {}
      var onPanChanged: (CGSize) -> Void = { _ in }
      var onPanEnded: (CGSize) -> Void = { _ in }
      var onScroll: (CGSize) -> Void = { _ in }
      var onZoom: (CGFloat, CGPoint) -> Void = { _, _ in }
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
    private var dragMode: CanvasViewportDragMode = .maybeTap {
      didSet {
        CanvasKeyState.shared.viewportDragMode = dragMode
        if dragMode != oldValue { window?.invalidateCursorRects(for: self) }
      }
    }
    private var dragClickCount = 1
    /// The tool active on the FIRST click of a click sequence. A double-click only means "type here"
    /// when that click was a Select click; with a placement tool the first click already placed.
    private var firstClickTool: CanvasTool = .select
    private var lastPan: CGSize = .zero
    private var freehandPoints: [CGPoint] = []
    /// Last raw drag point, kept so a Shift press/release with the mouse still (flagsChanged,
    /// no mouseDragged) can re-emit the draft with the new constraint immediately.
    private var lastDragPoint: CGPoint?
    /// Set when Esc aborted the current placing/freehand drag: further mouse-drags stop emitting a
    /// preview and the pending mouse-up commits nothing. Reset on the next `mouseDown`.
    private var draftCancelled = false
    private var escapeObserver: NSObjectProtocol?
    private var pointerTrackingArea: NSTrackingArea?

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
      CanvasKeyState.shared.viewportDragMode = .maybeTap
    }

    override func updateTrackingAreas() {
      super.updateTrackingAreas()
      if let pointerTrackingArea { removeTrackingArea(pointerTrackingArea) }
      let area = NSTrackingArea(
        rect: .zero,
        options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
        owner: self,
        userInfo: nil)
      addTrackingArea(area)
      pointerTrackingArea = area
    }

    /// Abandon a placing/freehand drag in progress (Esc). Leaves the mode intact so the eventual
    /// mouse-up still tears the gesture down cleanly, but flags it so nothing is committed.
    private func cancelActiveDraft() {
      guard dragMode == .placing || dragMode == .drawing || dragMode == .vectorPress
              || dragMode == .vectorDrawing else { return }
      draftCancelled = true
      freehandPoints = []
      state.onFreehandChanged(nil)
      state.onElementDraftCancelled()
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func mouseMoved(with event: NSEvent) {
      guard state.tool == .vectorPen, !state.isSpacePressed else { return }
      state.onVectorHoverChanged(convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
      if state.tool == .vectorPen { state.onVectorHoverChanged(nil) }
    }

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
      if event.clickCount <= 1 { firstClickTool = state.tool }
      lastPan = .zero
      freehandPoints = []
      draftCancelled = false
      dragMode = CanvasPointerPressMode.resolve(
        tool: state.tool, isSpacePressed: state.isSpacePressed)
      state.onSelectionChanged(nil)
      state.onFreehandChanged(nil)
      state.onElementDraftCancelled()
      if state.tool == .vectorPen, !state.isSpacePressed {
        state.onVectorNodeChanged(point, point)
      }
    }

    override func mouseDragged(with event: NSEvent) {
      guard let start = dragStart else { return }
      // Esc cancelled this placing/freehand drag — ignore the rest of it until mouse-up.
      if draftCancelled { lastDragPoint = convert(event.locationInWindow, from: nil); return }
      let point = convert(event.locationInWindow, from: nil)
      let delta = CGSize(width: point.x - start.x, height: point.y - start.y)
      let distance = hypot(delta.width, delta.height)

      if (dragMode == .maybeTap || dragMode == .vectorPress), distance >= 4 {
        if state.tool == .select {
          dragMode = .selecting
        } else if state.tool == .freehand {
          dragMode = .drawing
          freehandPoints = [start]
          state.onFreehandChanged(freehandPoints)
        } else if state.tool == .vectorPen {
          dragMode = .vectorDrawing
        } else if state.tool.placesByDragging {
          dragMode = .placing
        }
        // Click-to-place tools (text, equation, sticky, checklist, table) stay a tap however far
        // the press wanders and place at the press point on mouse-up — a slightly moved click used
        // to pan the board instead. Panning is Space-drag or scroll.
      }

      switch dragMode {
      case .maybeTap, .vectorPress:
        break
      case .selecting:
        state.onSelectionChanged(Self.normalizedRect(from: start, to: point))
      case .drawing:
        if freehandPoints.last.map({ hypot($0.x - point.x, $0.y - point.y) >= 1.5 }) ?? true {
          freehandPoints.append(point)
          state.onFreehandChanged(freehandPoints)
        }
      case .vectorDrawing:
        state.onVectorNodeChanged(start, point)
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
      case .maybeTap, .vectorPress:
        if state.tool == .vectorPen {
          state.onVectorNodeEnded(start, start)
        } else if dragClickCount >= 2 {
          if firstClickTool == .select { state.onDoubleTap(start) }
        } else {
          state.onTap(start, dragModifiers)
        }
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
      case .vectorDrawing:
        state.onVectorNodeEnded(start, point)
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
      guard CanvasViewportTransformPolicy.allowsPanOrZoom(during: dragMode) else { return }
      switch CanvasScrollInput(event) {
      case .pan(let delta): state.onScroll(delta)
      case .zoom(let factor): state.onZoom(factor, convert(event.locationInWindow, from: nil))
      }
    }

    override func keyDown(with event: NSEvent) {
      if state.tool == .vectorPen, event.keyCode == 36 {
        state.onVectorCommitOpen()
        return
      }
      super.keyDown(with: event)
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
        // Swallow pinch just like InputView swallows scroll-pan while drawing. The shared drag mode
        // is updated synchronously by the AppKit input view, so this global monitor cannot zoom the
        // board out from beneath an in-progress shape, freehand stroke, or vector handle pull.
        guard CanvasViewportTransformPolicy.allowsPanOrZoom(
          during: CanvasKeyState.shared.viewportDragMode) else { return nil }
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

/// The selection-anchored chrome for whichever card holds focus: the selection action bar.
/// Observes the active card's interaction directly so it re-renders when the selection changes;
/// rebuilt (via `.id`) when the active card changes.
private struct ActiveCardOverlays: View {
  @ObservedObject var card: CardInteraction
  let size: CGSize
  let currentTint: Int?
  let onFormat: (MarkdownStyle.Action) -> Void
  let onTint: (Int?) -> Void

  var body: some View {
    ZStack(alignment: .topLeading) {
      selectionBar
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .animation(Theme.Motion.accessory, value: card.selection)
  }

  @ViewBuilder
  private var selectionBar: some View {
    if !card.selection.isEmpty, let rect = card.selection.rectInView {
      SelectionActionBar(onFormat: onFormat, currentTint: currentTint, onTint: onTint)
        .fixedSize()
        .position(x: clamp(rect.midX, 120, max(120, size.width - 120)),
                  y: clamp(rect.minY - 22, 30, max(30, size.height - 28)))
        .transition(.opacity)
    }
  }

  private func clamp(_ value: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
    Swift.min(Swift.max(value, lower), upper)
  }
}

/// The board's card layer, pulled out of the canvas body and made `Equatable` so SwiftUI re-renders
/// the cards only when something that actually affects how they draw changes — never for a transient
/// gesture (draw / freehand / selection rect / live pan), which all mutate canvas `@State` that this
/// layer doesn't depend on. The comparison covers exactly that state: the visible cards themselves,
/// the selection/editing/primary ids, the zoom, the select-tool gate, and the equation drop target.
///
/// `board` is excluded from `==` on purpose — it is one stable instance, so comparing it would be
/// meaningless.
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
struct DragSegment: Equatable {
  var start: CGPoint
  var end: CGPoint
}

/// Transient drawing state belongs to exactly one loaded board. Board replacement resets this
/// value atomically, which also makes that lifecycle rule testable without mounting SwiftUI.
struct CanvasDrawingDraftState: Equatable {
  var freehand: [CGPoint]? = nil
  var vector: VectorPathDraft? = nil
  var element: DragSegment? = nil
  var bindTargetID: UUID? = nil

  var hasDraft: Bool {
    freehand != nil || vector != nil || element != nil || bindTargetID != nil
  }

  mutating func cancelForBoardReplacement() {
    freehand = nil
    vector = nil
    element = nil
    bindTargetID = nil
  }
}

/// A hover exit may close the picker only after every management surface has released it.
enum BoardPickerPresentationPolicy {
  static func canClose(
    isHovering: Bool,
    hasActiveRename: Bool,
    hasDeleteConfirmation: Bool
  ) -> Bool {
    !isHovering && !hasActiveRename && !hasDeleteConfirmation
  }
}

/// The wrapper that positions the picker fills the window, but its interactive region is only the
/// visible popup at these chrome insets. Kept as geometry-only policy so that contract can be
/// regression-tested independently of SwiftUI's modifier tree.
enum BoardPickerHitTestingPolicy {
  static func interactiveSurfaceRect(surfaceSize: CGSize) -> CGRect {
    CGRect(
      x: WindowChrome.trafficLightInset,
      y: WindowChrome.edgeInset,
      width: surfaceSize.width,
      height: surfaceSize.height)
  }
}

/// The compact identity pill keeps its established footprint; only the open manager grows. Values
/// name the actual popup surface width (including chrome padding) and the resulting row text budget
/// so future action affordances cannot silently squeeze board titles back to an ellipsis.
enum BoardPickerLayoutPolicy {
  static var collapsedSurfaceWidth: CGFloat {
    WindowChrome.boardPillWidth + WindowChrome.padH * 2
  }

  static func expandedSurfaceWidth(viewportWidth: CGFloat) -> CGFloat {
    min(
      WindowChrome.boardPickerExpandedWidth,
      max(
        collapsedSurfaceWidth,
        viewportWidth - WindowChrome.trafficLightInset - WindowChrome.topRightReservedWidth
      )
    )
  }

  static func expandedContentWidth(viewportWidth: CGFloat) -> CGFloat {
    expandedSurfaceWidth(viewportWidth: viewportWidth) - WindowChrome.padH * 2
  }

  static func expandedTextBudget(viewportWidth: CGFloat) -> CGFloat {
    expandedContentWidth(viewportWidth: viewportWidth)
      - WindowChrome.labelPadH * 2
      - WindowChrome.boardPickerActionSlotWidth
      - WindowChrome.itemSpacing
      - WindowChrome.boardPickerIndicatorWidth
      - WindowChrome.boardPickerIndicatorSpacing
      - WindowChrome.itemSpacing
  }
}

/// Visibility and activation move together for the hover-only row actions. The view keeps one
/// stable whole-row hover region, including the reserved action slot, and feeds that region here.
struct BoardPickerRowInteractionState: Equatable {
  private(set) var isHovered = false

  var showsActions: Bool { isHovered }
  var enablesActions: Bool { isHovered }

  /// Returns true only on entry so callers can emit one hover tick, not one per state refresh.
  mutating func setHovered(_ hovered: Bool) -> Bool {
    let entered = hovered && !isHovered
    isHovered = hovered
    return entered
  }
}

/// One non-current board in the hover picker. Management state stays in `ComposerCanvas`, so a
/// failed persistence attempt can keep this exact editor visible and Escape follows the global
/// coordinator instead of being swallowed by row-local state.
private struct BoardPickerRow: View {
  let title: String
  let isRenaming: Bool
  @Binding var draftName: String
  var nameFocused: FocusState<Bool>.Binding
  let onPick: () -> Void
  let onBeginRename: () -> Void
  let onCommitRename: () -> Void
  let onCancelRename: () -> Void
  let onDelete: () -> Void

  @State private var interaction = BoardPickerRowInteractionState()

  var body: some View {
    Group {
      if isRenaming { renameRow } else { pickRow }
    }
    .animation(.easeOut(duration: 0.1), value: interaction.showsActions)
  }

  private var pickRow: some View {
    HStack(spacing: WindowChrome.itemSpacing) {
      Button(action: onPick) {
        HStack(spacing: WindowChrome.boardPickerIndicatorSpacing) {
          Circle().fill(Color.clear)
            .frame(width: WindowChrome.boardPickerIndicatorWidth,
                   height: WindowChrome.boardPickerIndicatorWidth)
          Text(title)
            .font(WindowChrome.labelFont)
            .foregroundStyle(Theme.Palette.body)
            .lineLimit(1)
          Spacer(minLength: WindowChrome.itemSpacing)
        }
        .frame(maxWidth: .infinity)
        .frame(height: WindowChrome.boardPickerRowHeight)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help("Open %@".localizedUI(title))
      .accessibilityLabel(Text(title))
      .accessibilityAction(named: Text("Rename board".localizedUI), onBeginRename)
      .accessibilityAction(named: Text("Delete board".localizedUI), onDelete)

      HStack(spacing: WindowChrome.itemSpacing) {
        rowIcon("pencil", help: "Rename board".localizedUI, action: onBeginRename)
        rowIcon("trash", help: "Delete board".localizedUI, tint: .red, action: onDelete)
      }
      .frame(
        width: WindowChrome.boardPickerActionSlotWidth,
        height: WindowChrome.rowIconSide)
      .opacity(interaction.showsActions ? 1 : 0)
      // Keep the reserved slot in the row's hover region even while its controls are invisible.
      // Disabling prevents invisible activation without making the pointer fall through and fire a
      // hover exit just as it crosses from the title into Edit/Delete.
      .disabled(!interaction.enablesActions)
      .accessibilityHidden(!interaction.showsActions)
    }
    .padding(.horizontal, WindowChrome.labelPadH)
    .frame(height: WindowChrome.boardPickerRowHeight)
    .contentShape(.interaction, Rectangle())
    .onHover { over in
      if interaction.setHovered(over) { Haptics.hover() }
    }
  }

  private var renameRow: some View {
    HStack(spacing: WindowChrome.boardPickerIndicatorSpacing) {
      Circle().fill(Color.clear)
        .frame(
          width: WindowChrome.boardPickerIndicatorWidth,
          height: WindowChrome.boardPickerIndicatorWidth)
      TextField("Board name".localizedUI, text: $draftName)
        .textFieldStyle(.plain)
        .font(WindowChrome.labelFont)
        .foregroundStyle(Theme.Palette.body)
        .focused(nameFocused)
        .onSubmit(onCommitRename)
        .onExitCommand(perform: onCancelRename)
    }
    .padding(.horizontal, WindowChrome.labelPadH)
    .frame(height: WindowChrome.boardPickerRowHeight)
    .background(
      RoundedRectangle(cornerRadius: 7, style: .continuous)
        .fill(Theme.Palette.rowFill)
    )
    .onAppear { DispatchQueue.main.async { nameFocused.wrappedValue = true } }
    .onChange(of: nameFocused.wrappedValue) { _, focused in
      if !focused { onCommitRename() }
    }
  }

  private func rowIcon(
    _ symbol: String,
    help: String,
    tint: Color? = nil,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(WindowChrome.rowIconFont)
        .foregroundStyle(tint ?? Theme.Palette.title)
        .frame(width: WindowChrome.rowIconSide, height: WindowChrome.rowIconSide)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(help)
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
        .frame(height: 30)   // denser than the standard chrome control height
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
    case .equation, .graph, .sticky, .checklist, .table:
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
