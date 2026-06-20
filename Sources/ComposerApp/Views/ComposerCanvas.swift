import AppKit
import SwiftUI
import SwiftData

/// The entire app surface: a pan/zoom board of text cards on a chromeless glass card, with a
/// top tool toolbar and a left action rail floating in the gutters. Per-card editor chrome
/// (mentions, connector search, the semantic linter) is routed to the active card; board-level
/// actions (Compile, Copy) span every card.
struct ComposerCanvas: View {
  @StateObject private var store = DumpStore.shared
  @StateObject private var board = BoardViewModel()
  @ObservedObject private var engineCapabilities = EngineCapabilityStore.shared
  @ObservedObject private var workspaceLayout = WorkspaceLayout.shared

  @State private var tool: CanvasTool = .select
  @State private var isWorking = false
  @State private var toast: Toast?
  @State private var lastViewportSize: CGSize = .zero
  @State private var selectionRect: CGRect?
  @State private var freehandDraft: [CGPoint]?
  @State private var elementDraft: DragSegment?
  @State private var isSpacePressed = false
  @State private var viewportThrottle = ViewportEventThrottle()
  /// Held as plain @State (not @StateObject) so the agent's streaming updates stay scoped to its
  /// own auxiliary panel rather than re-rendering the canvas.
  @State private var agent = CanvasAgent()
  @State private var showAgent = false
  /// Mirrors the agent's grounding folder so the toolbar reflects it reactively.
  @AppStorage("agent.groundingDirectory") private var groundingPath = ""

  // Board transform. Pointer locations are normalized back into board space so selection,
  // placement, and dragging keep working at every zoom level.
  @State private var scale: CGFloat = 1
  @State private var pan: CGSize = .zero
  @State private var panLive: CGSize = .zero

  private let service = HeadlessPromptService()
  private let cardPasteboardType = NSPasteboard.PasteboardType("dev.jow.Composer.cards")

  private var effectiveScale: CGFloat { scale }

  var body: some View {
    GeometryReader { proxy in canvasRoot(proxy: proxy) }
    .ignoresSafeArea()
    .animation(Theme.Motion.accessory, value: isWorking)
    .animation(Theme.Motion.accessory, value: store.isHistoryOpen)
    .animation(Theme.Motion.accessory, value: store.compiledDraft)
    .onChange(of: isWorking) { _, working in
      NotificationCenter.default.post(name: .composerBusyChanged, object: nil, userInfo: ["busy": working])
    }
  }

  @ViewBuilder
  private func canvasRoot(proxy: GeometryProxy) -> some View {
    let layout = CanvasSurfaceLayout(windowSize: proxy.size)
    let inner = layout.cardSize
    let toolbarCenterX = workspaceLayout.toolbarCenterX > 0
      ? workspaceLayout.toolbarCenterX
      : proxy.size.width / 2
    ZStack(alignment: .topLeading) {
      ZStack(alignment: .topLeading) {
        ComposerPanelBackground()
        boardContent(viewportSize: inner)
        compiledOverlay
        toastView
      }
      .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
      .frame(width: layout.cardSize.width, height: layout.cardSize.height, alignment: .topLeading)
      .offset(x: layout.cardOrigin.x, y: layout.cardOrigin.y)

      // Active-card overlays resolve through screen → window space, so they live in
      // full-window coordinates and keep working while the board itself is transformed.
      if let editing = board.editingInteraction {
        ActiveCardOverlays(
          card: editing,
          size: proxy.size,
          isWorking: isWorking,
          onRefine: { refineSelection($0, card: editing) },
          onCopy: { copyBoard() },
          onApplyFix: { editing.controller.applyLintFix(range: $0.range, expecting: $0.phrase, with: $1) },
          onAskClaude: { askClaude(about: $0, card: editing) }
        )
        .id(editing.id)
      }

      // Rails float in the gutters; the history list opens over the card.
      historyListOverlay(in: proxy.size)
      sidebar(in: proxy.size)
      toolbar(
        fit: inner,
        windowSize: proxy.size,
        cardSize: layout.cardSize,
        workspaceCenterX: toolbarCenterX
      )
      commandBridge
    }
    .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
    .onAppear { lastViewportSize = inner; enterEditingForEntry(); CanvasBridge.shared.register(board) }
    .onChange(of: inner) { _, value in lastViewportSize = value }
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
      .onReceive(NotificationCenter.default.publisher(for: .composerCopy)) { _ in copyBoard() }
      .onReceive(NotificationCenter.default.publisher(for: .composerCompileBoard)) { _ in runCompile() }
      .onReceive(NotificationCenter.default.publisher(for: .composerShowSettings)) { _ in openSettings() }
      .onReceive(NotificationCenter.default.publisher(for: .composerPrevDump)) { _ in handlePrevDump() }
      .onReceive(NotificationCenter.default.publisher(for: .composerNextDump)) { _ in handleNextDump() }
      .onReceive(NotificationCenter.default.publisher(for: .composerNewDump)) { _ in handleNewDump() }
      .onReceive(NotificationCenter.default.publisher(for: .composerDockDismissed)) { note in
        guard let rawKind = note.userInfo?["kind"] as? String,
              let kind = ComposerDockKind(rawValue: rawKind) else { return }
        switch kind {
        case .agent: showAgent = false
        case .settings: store.isSettingsOpen = false
        }
      }
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
  }

  /// The agent and Settings share the single auxiliary-panel slot.
  private func toggleAgent() {
    if showAgent {
      showAgent = false
      NotificationCenter.default.post(name: .composerDismissDock, object: nil)
    } else {
      showAgent = true
      store.isSettingsOpen = false
      NotificationCenter.default.post(
        name: .composerPresentDock,
        object: agent,
        userInfo: ["kind": ComposerDockKind.agent.rawValue]
      )
    }
  }

  private func selectTool(index: Int) {
    let order: [CanvasTool] = [.select, .text, .rectangle, .ellipse, .diamond, .line, .arrow, .freehand]
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
        onSelectionChanged: { selectionRect = $0 },
        onSelectionEnded: selectCards(inViewportRect:modifiers:),
        onFreehandChanged: { freehandDraft = $0 },
        onFreehandEnded: commitFreehandDraft,
        onElementDraftChanged: { start, current in elementDraft = DragSegment(start: start, end: current) },
        onElementDraftEnded: commitElementDraft,
        onElementDraftCancelled: { elementDraft = nil },
        onPanChanged: { panLive = $0 },
        onPanEnded: { delta in
          pan.width += delta.width
          pan.height += delta.height
          panLive = .zero
        },
        onScroll: handleScroll,
        onZoom: handleZoom
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)

      // Transformed cards. Off-screen cards are culled before SwiftUI builds their views.
      ZStack(alignment: .topLeading) {
        ForEach(visibleCards(in: viewportSize)) { card in
          BoardCardView(
            card: card,
            interaction: board.interaction(for: card.id),
            isSelected: board.selectedCardIDs.contains(card.id),
            isEditing: board.editingCardID == card.id,
            scale: effectiveScale,
            board: board,
            onEscape: { dismiss() }
          )
          .zIndex(Double(card.z) + (board.primarySelectedCardID == card.id ? 10_000 : 0))
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .scaleEffect(effectiveScale, anchor: .topLeading)
      .offset(x: pan.width + panLive.width, y: pan.height + panLive.height)

      selectionRectView
      freehandDraftView
      elementDraftView

      // Board-wide pinch-to-zoom, so it works no matter what's under the cursor (card, dock,
      // toolbar, editing text view). Transparent to clicks; only listens for magnify.
      PinchZoomCatcher(onZoom: handleZoom)
        .allowsHitTesting(false)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  @ViewBuilder
  private var elementDraftView: some View {
    if let draft = elementDraft, let kind = tool.elementKind {
      ElementDraftPreview(kind: kind, start: draft.start, end: draft.end)
        .allowsHitTesting(false)
    }
  }

  @ViewBuilder
  private var selectionRectView: some View {
    if let rect = selectionRect, rect.width > 1, rect.height > 1 {
      RoundedRectangle(cornerRadius: 2, style: .continuous)
        .fill(Color.accentColor.opacity(0.10))
        .overlay(RoundedRectangle(cornerRadius: 2, style: .continuous)
          .strokeBorder(Color.accentColor.opacity(0.72), lineWidth: 1))
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
      .stroke(Color.white.opacity(0.82), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
      .shadow(color: .black.opacity(0.22), radius: 5, y: 2)
      .allowsHitTesting(false)
    }
  }

  /// A tap on empty board: place a card (Text tool) or clear selection (Select tool).
  private func handleTap(at point: CGPoint, modifiers: EventModifiers) {
    if tool == .select {
      if !modifiers.contains(.shift), !modifiers.contains(.command) { board.deselectAll() }
      return
    }

    guard let kind = tool.elementKind else { return }
    let boardPoint = CGPoint(x: (point.x - pan.width) / effectiveScale,
                             y: (point.y - pan.height) / effectiveScale)
    let id = board.addElement(kind, at: boardPoint)
    tool = .select
    if kind == .text {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
        board.interaction(for: id).controller.focus()
      }
    }
  }

  /// Double-clicking empty canvas drops a text element there and starts editing — the default
  /// "just start writing" gesture, regardless of the active tool.
  private func handleDoubleTap(at point: CGPoint) {
    let id = board.addCard(at: boardPoint(forViewport: point))
    tool = .select
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { board.interaction(for: id).controller.focus() }
  }

  /// Commit a shape/line drawn by dragging from `start` to `end` (viewport space → board space).
  private func commitElementDraft(_ start: CGPoint, _ end: CGPoint) {
    defer { elementDraft = nil }
    guard let kind = tool.elementKind else { return }
    if board.addDrawnElement(kind, from: boardPoint(forViewport: start), to: boardPoint(forViewport: end)) != nil {
      tool = .select
    }
  }

  private func commitFreehandDraft(_ viewportPoints: [CGPoint]) {
    defer { freehandDraft = nil }
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
    if board.addFreehandStroke(frame: frame, points: normalized) != nil {
      tool = .select
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

  // MARK: Rails + overlays

  private func sidebar(in windowSize: CGSize) -> some View {
    Sidebar(
      store: store,
      onNew: { newBoard() },
      onHistory: {
        store.isHistoryOpen.toggle()
        if store.isHistoryOpen { closeAuxiliaryPanel() }
      },
      onSettings: { openSettings() }
    )
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    .padding(.leading, Theme.Size.railInset(in: windowSize.width))
  }

  private func toolbar(
    fit innerSize: CGSize,
    windowSize: CGSize,
    cardSize: CGSize,
    workspaceCenterX: CGFloat
  ) -> some View {
    CanvasToolbar(
      tool: $tool,
      zoomPercent: Int((effectiveScale * 100).rounded()),
      groundedFolder: groundingPath.isEmpty ? nil : URL(fileURLWithPath: groundingPath).lastPathComponent,
      onFolder: { agent.chooseDirectory() },
      agentOpen: showAgent,
      onAgent: { toggleAgent() },
      onTidy: { tidyBoard(in: innerSize) },
      onZoomOut: { zoom(0.8, anchoredAt: zoomAnchor) },
      onZoomIn: { zoom(1.25, anchoredAt: zoomAnchor) },
      onZoomReset: { withAnimation(Theme.Motion.accessory) { scale = 1 } },
      onFit: { withAnimation(Theme.Motion.accessory) { fitBoard(in: innerSize) } }
    )
    // The board's host window narrows for Agent/Settings, but the toolbar belongs to the complete
    // composed workspace. `workspaceCenterX` is supplied by the AppKit controller in board-window
    // coordinates, so the controls remain centered across both panels.
    .frame(width: cardSize.width, alignment: .top)
    .frame(maxHeight: .infinity, alignment: .top)
    .offset(x: workspaceCenterX - cardSize.width / 2)
    .padding(.top, Theme.Size.toolbarInset(in: windowSize.height))
  }

  @ViewBuilder
  private func historyListOverlay(in size: CGSize) -> some View {
    if store.isHistoryOpen {
      ZStack {
        Color.clear.contentShape(Rectangle()).onTapGesture { store.isHistoryOpen = false }
        HistoryList(
          store: store,
          onPick: { pickBoard($0) },
          onDelete: { deleteBoard($0) },
          onNew: { newBoard() }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(.leading, Theme.Size.railGutter(in: size.width) + size.width * 0.004)
      }
      .transition(.opacity)
    }
  }

  @ViewBuilder
  private var compiledOverlay: some View {
    if let draft = store.compiledDraft {
      CompiledDraftOverlay(
        text: draft,
        onCopy: { copyToClipboard(draft); show(Toast(text: "Copied compiled draft", symbol: "doc.on.doc.fill", tint: .accentColor)) },
        onClose: { store.compiledDraft = nil }
      )
      .transition(.opacity)
    }
  }

  @ViewBuilder
  private var toastView: some View {
    if let toast {
      VStack {
        Spacer()
        HStack(spacing: 8) {
          Image(systemName: toast.symbol).foregroundStyle(toast.tint)
          Text(toast.text).font(Theme.Typography.actionLabel).foregroundStyle(Theme.Palette.body)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .floatingGlass(Capsule(style: .continuous))
        .padding(.bottom, 30)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .transition(.move(edge: .bottom).combined(with: .opacity))
      .allowsHitTesting(false)
    }
  }

  // MARK: Zoom helpers

  private func clampZoom(_ value: CGFloat) -> CGFloat { min(max(value, 0.35), 1) }

  private var viewportCenter: CGPoint {
    CGPoint(x: lastViewportSize.width / 2, y: lastViewportSize.height / 2)
  }

  /// Toolbar/keyboard zoom targets the current selection's center so the board doesn't lurch
  /// back to center on every zoom; falls back to the viewport center with nothing selected.
  private var zoomAnchor: CGPoint {
    let selected = board.cards.filter { board.selectedCardIDs.contains($0.id) }
    guard !selected.isEmpty else { return viewportCenter }
    let midX = ((selected.map(\.x).min() ?? 0) + (selected.map { $0.x + $0.w }.max() ?? 0)) / 2
    let midY = ((selected.map(\.y).min() ?? 0) + (selected.map { $0.y + $0.h }.max() ?? 0)) / 2
    return CGPoint(x: CGFloat(midX) * effectiveScale + pan.width,
                   y: CGFloat(midY) * effectiveScale + pan.height)
  }

  private func zoom(_ factor: CGFloat, anchoredAt point: CGPoint) {
    let oldScale = max(scale, 0.01)
    let nextScale = clampZoom(oldScale * factor)
    guard nextScale != scale else { return }
    dismissEditorOverlays()
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
    viewportThrottle.enqueueScroll(delta) { applied in
      dismissEditorOverlays()
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

  /// Auto-arrange the whole board into a clean layered layout, then frame the result.
  private func tidyBoard(in size: CGSize) {
    board.deselectAll()
    board.relayout()
    withAnimation(Theme.Motion.accessory) { fitBoard(in: size) }
  }

  private func resetView() { scale = 1; pan = .zero }

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
    if board.editingInteraction != nil { return }
    if tool != .select {
      tool = .select
    } else if !board.selectedCardIDs.isEmpty {
      board.deselectAll()
    } else {
      dismiss()
    }
  }
  private func handleUndoBoard() { if canEditBoard { board.undo() } }
  private func handleRedoBoard() { if canEditBoard { board.redo() } }
  private func handleGroupSelection() { if canEditBoard { board.groupSelection() } }
  private func handleUngroupSelection() { if canEditBoard { board.ungroupSelection() } }
  private func handleLockSelection() { if canEditBoard { board.lockSelection(true) } }
  private func handleUnlockSelection() { if canEditBoard { board.lockSelection(false) } }

  private func handleSpaceKey(_ notification: Notification) {
    isSpacePressed = (notification.userInfo?["down"] as? Bool) ?? false
  }

  private func gotoOlder() { board.flushSave(); store.goOlder(); board.loadFromStore(); resetView() }
  private func gotoNewer() { board.flushSave(); store.goNewer(); board.loadFromStore(); resetView() }
  private func newBoard() { board.flushSave(); store.newDump(); board.loadFromStore(); resetView(); focusFirstCard() }
  private func pickBoard(_ id: PersistentIdentifier) { board.flushSave(); store.select(id); board.loadFromStore(); resetView() }
  private func deleteBoard(_ id: PersistentIdentifier) { board.flushSave(); store.delete(id); board.loadFromStore(); resetView() }

  private func focusFirstCard() {
    guard let id = board.cards.first?.id else { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { board.interaction(for: id).controller.focus() }
  }

  /// On panel open: enter editing on the active (or first) card so the caret is ready to type.
  /// Never steals focus mid-edit or while an overlay/settings is up.
  private func enterEditingForEntry() {
    guard board.editingInteraction == nil, !store.isSettingsOpen, store.compiledDraft == nil,
          !store.isHistoryOpen else { return }
    let id = board.primarySelectedCardID ?? board.cards.first?.id
    guard let id, board.cards.first(where: { $0.id == id })?.elementKind == .text else { return }
    board.beginEditing(id)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { board.interaction(for: id).controller.focus() }
  }

  /// A pan or zoom would strand caret-anchored overlays at a stale point, so close them.
  private func dismissEditorOverlays() {
    guard let editing = board.editingInteraction else { return }
    if editing.mentions.isOpen { editing.mentions.isOpen = false; editing.mentions.items = [] }
    if editing.appSearch.isOpen { editing.appSearch.isOpen = false }
    if editing.lint.activeFlagID != nil { editing.lint.activeFlagID = nil }
  }

  private func openSettings() {
    store.isHistoryOpen = false
    store.compiledDraft = nil
    showAgent = false
    store.isSettingsOpen = true
    NotificationCenter.default.post(
      name: .composerPresentDock,
      object: nil,
      userInfo: ["kind": ComposerDockKind.settings.rawValue]
    )
  }

  private func closeAuxiliaryPanel() {
    guard showAgent || store.isSettingsOpen else { return }
    showAgent = false
    store.isSettingsOpen = false
    NotificationCenter.default.post(name: .composerDismissDock, object: nil)
  }

  // MARK: Compile + copy + refine

  /// Collapse the whole board into one ordered, paste-ready draft.
  private func runCompile() {
    guard !isWorking, store.compiledDraft == nil else { return }
    let source = board.joinedPlainText()
    guard !source.trimmed.isEmpty else {
      show(Toast(text: "Add some cards to compile", symbol: "rectangle.dashed", tint: .orange))
      return
    }
    guard let engine = preferredEngine() else {
      show(Toast(text: "No engines enabled in Settings", symbol: "exclamationmark.triangle.fill", tint: .orange))
      return
    }
    isWorking = true
    Task {
      do {
        let result = try await service.compileBoard(source: source, engine: engine)
        store.compiledDraft = result
      } catch {
        show(Toast(text: error.localizedDescription, symbol: "exclamationmark.triangle.fill", tint: .orange))
      }
      isWorking = false
    }
  }

  /// Copy the whole board as one self-contained block (connectors expanded).
  private func copyBoard() {
    let plain = board.joinedPlainText()
    guard !plain.trimmed.isEmpty else {
      show(Toast(text: "Nothing to copy yet", symbol: "doc.on.doc", tint: .orange))
      return
    }
    let connectors = AppToken.scan(plain).filter { $0.selection != nil }.count
    if connectors > 0 { show(Toast(text: "Resolving connectors\u{2026}", symbol: "arrow.triangle.2.circlepath", tint: .accentColor)) }
    Task {
      let rendered = await SelfContainedRenderer.render(plain)
      guard !rendered.trimmed.isEmpty else {
        show(Toast(text: "Couldn\u{2019}t resolve connectors", symbol: "exclamationmark.triangle.fill", tint: .orange))
        return
      }
      copyToClipboard(rendered)
      let message = connectors > 0 ? "Copied \u{00b7} \(connectors) connector\(connectors == 1 ? "" : "s") resolved" : "Copied self-contained text"
      show(Toast(text: message, symbol: "doc.on.doc.fill", tint: .accentColor))
    }
  }

  /// Refine the active card's current selection in place.
  private func refineSelection(_ engine: HeadlessEngine, card: CardInteraction) {
    let snapshot = card.selection
    guard !snapshot.isEmpty, !isWorking else { return }
    guard EnginePreferences.isEnabled(engine) else {
      show(Toast(text: "\(engine.title) is disabled in Settings", symbol: "exclamationmark.triangle.fill", tint: .orange))
      return
    }
    let whole = card.controller.plainText
    isWorking = true
    Task {
      do {
        let result = try await service.refineSelection(whole: whole, selection: snapshot.text, engine: engine)
        card.controller.replace(range: snapshot.range, with: result)
        show(Toast(text: "Refined with \(engine.title)", symbol: "checkmark.circle.fill", tint: .green))
      } catch {
        show(Toast(text: error.localizedDescription, symbol: "exclamationmark.triangle.fill", tint: .orange))
      }
      isWorking = false
    }
  }

  /// Escalate one flagged phrase on the active card to Claude.
  private func askClaude(about flag: LintFlag, card: CardInteraction) {
    guard !isWorking else { return }
    guard EnginePreferences.isEnabled(.claude) else {
      show(Toast(text: "Claude is disabled in Settings", symbol: "exclamationmark.triangle.fill", tint: .orange))
      return
    }
    let whole = card.controller.plainText
    isWorking = true
    card.lint.activeFlagID = nil
    Task {
      do {
        let result = try await service.refineSelection(whole: whole, selection: flag.phrase, engine: .claude)
        card.controller.applyLintFix(range: flag.range, expecting: flag.phrase, with: result)
        show(Toast(text: "Clarified with Claude", symbol: "checkmark.circle.fill", tint: .green))
      } catch {
        show(Toast(text: error.localizedDescription, symbol: "exclamationmark.triangle.fill", tint: .orange))
      }
      isWorking = false
    }
  }

  private func preferredEngine() -> HeadlessEngine? {
    if EnginePreferences.isEnabled(.claude), engineCapabilities.isAvailable(.claude) { return .claude }
    if EnginePreferences.isEnabled(.codex), engineCapabilities.isAvailable(.codex) { return .codex }
    return nil
  }

  private func copyToClipboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }

  private func copySelectedCards() {
    let selected = board.selectedCardsForClipboard()
    guard !selected.isEmpty, let data = try? JSONEncoder().encode(selected) else { return }
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setData(data, forType: cardPasteboardType)
  }

  private func pasteSelectedCards() {
    let pasteboard = NSPasteboard.general
    if let data = pasteboard.data(forType: cardPasteboardType),
       let cards = try? JSONDecoder().decode([CardState].self, from: data) {
      board.insertCopies(cards)
      return
    }
    if let image = firstImage(from: pasteboard), let url = ComposerTextView.savePNG(image) {
      board.addImageObject(path: url.path, at: boardPoint(forViewport: viewportCenter))
    }
  }

  private func dismiss() { NotificationCenter.default.post(name: .composerDismiss, object: nil) }

  private func boardPoint(forViewport point: CGPoint) -> CGPoint {
    CGPoint(x: (point.x - pan.width) / effectiveScale,
            y: (point.y - pan.height) / effectiveScale)
  }

  private func firstImage(from pasteboard: NSPasteboard) -> NSImage? {
    if pasteboard.canReadObject(forClasses: [NSImage.self], options: nil),
       let images = pasteboard.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage],
       let first = images.first {
      return first
    }
    let options: [NSPasteboard.ReadingOptionKey: Any] = [
      .urlReadingFileURLsOnly: true,
      .urlReadingContentsConformToTypes: NSImage.imageTypes,
    ]
    if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL],
       let url = urls.first {
      return NSImage(contentsOf: url)
    }
    return nil
  }

  // MARK: Toast

  private func show(_ value: Toast) {
    toast = value
    let id = value.id
    Task {
      try? await Task.sleep(nanoseconds: 1_900_000_000)
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
        if state.isSpacePressed != oldValue.isSpacePressed { window?.invalidateCursorRects(for: self) }
      }
    }
    private var dragStart: CGPoint?
    private var dragModifiers: EventModifiers = []
    private var dragMode: DragMode = .maybeTap
    private var dragClickCount = 1
    private var lastPan: CGSize = .zero
    private var freehandPoints: [CGPoint] = []

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    // Make space-to-pan discoverable: a grab cursor while space is held.
    override func resetCursorRects() {
      if state.isSpacePressed { addCursorRect(bounds, cursor: .openHand) }
    }

    override func mouseDown(with event: NSEvent) {
      window?.makeFirstResponder(self)
      let point = convert(event.locationInWindow, from: nil)
      dragStart = point
      dragModifiers = EventModifiers(event.modifierFlags)
      dragClickCount = event.clickCount
      lastPan = .zero
      freehandPoints = []
      dragMode = state.isSpacePressed ? .panning : .maybeTap
      state.onSelectionChanged(nil)
      state.onFreehandChanged(nil)
      state.onElementDraftCancelled()
    }

    override func mouseDragged(with event: NSEvent) {
      guard let start = dragStart else { return }
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
        state.onElementDraftChanged(start, point)
      case .panning:
        lastPan = delta
        state.onPanChanged(delta)
      }
    }

    override func mouseUp(with event: NSEvent) {
      guard let start = dragStart else { return }
      let point = convert(event.locationInWindow, from: nil)
      let delta = CGSize(width: point.x - start.x, height: point.y - start.y)
      let distance = hypot(delta.width, delta.height)

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
          state.onElementDraftCancelled()
          state.onTap(start, dragModifiers)   // a click (no real drag) still drops a default size
        } else {
          state.onElementDraftEnded(start, point)
        }
      case .panning:
        state.onPanEnded(lastPan)
      }

      dragStart = nil
      dragModifiers = []
      dragMode = .maybeTap
      lastPan = .zero
      freehandPoints = []
      state.onSelectionChanged(nil)
      state.onFreehandChanged(nil)
    }

    override func scrollWheel(with event: NSEvent) {
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
  let onRefine: (HeadlessEngine) -> Void
  let onCopy: () -> Void
  let onApplyFix: (LintFlag, String) -> Void
  let onAskClaude: (LintFlag) -> Void

  init(card: CardInteraction, size: CGSize, isWorking: Bool,
       onRefine: @escaping (HeadlessEngine) -> Void,
       onCopy: @escaping () -> Void,
       onApplyFix: @escaping (LintFlag, String) -> Void,
       onAskClaude: @escaping (LintFlag) -> Void) {
    self.card = card
    self.mentions = card.mentions
    self.appSearch = card.appSearch
    self.lint = card.lint
    self.size = size
    self.isWorking = isWorking
    self.onRefine = onRefine
    self.onCopy = onCopy
    self.onApplyFix = onApplyFix
    self.onAskClaude = onAskClaude
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
      SelectionActionBar(isWorking: isWorking, onRefine: onRefine, onCopy: onCopy)
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
        onPick: { onApplyFix(flag, $0) },
        onAskClaude: { onAskClaude(flag) },
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
    let suggestions = CGFloat(flag.suggestions.count) * 42
    let dividers = flag.suggestions.isEmpty ? 1.0 : 2.0
    return min(260, 62 + suggestions + 42 + dividers)
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

/// Start/end of an in-progress drag that draws a shape or line (viewport coordinates).
private struct DragSegment: Equatable {
  var start: CGPoint
  var end: CGPoint
}

/// The board card is derived from its own AppKit window's current viewport. The auxiliary dock is
/// deliberately absent here: it is a sibling window managed by `PanelController`.
private struct CanvasSurfaceLayout {
  let cardSize: CGSize
  let cardOrigin: CGPoint

  init(windowSize: CGSize) {
    let windowWidth = max(windowSize.width, 0)
    let windowHeight = max(windowSize.height, 0)
    let rail = Theme.Size.railGutter(in: windowWidth)
    let toolbar = Theme.Size.toolbarGutter(in: windowHeight)
    let cardWidth = max(windowWidth - rail, 1)
    let cardHeight = max(windowHeight - toolbar, 1)

    cardSize = CGSize(width: cardWidth, height: cardHeight)
    cardOrigin = CGPoint(x: rail, y: toolbar)
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
      Color.accentColor.opacity(0.9),
      style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round, dash: dash))
  }

  private var dash: [CGFloat] { (kind == .line || kind == .arrow) ? [] : [6, 4] }

  private func path(in r: CGRect) -> Path {
    switch kind {
    case .line, .arrow:
      return Path { p in p.move(to: start); p.addLine(to: end) }
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
