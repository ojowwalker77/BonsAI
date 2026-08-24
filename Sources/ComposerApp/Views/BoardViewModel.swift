import SwiftUI
import SwiftData
import AppKit
import ImageIO

// MARK: - Per-card runtime state

/// One card's editor-runtime state — the per-editor objects that were singletons in the
/// note era, now one bundle per card. Geometry lives in `CardState` (the board model);
/// this holds the live editing surface. Stable identity: created once per card id and
/// cached in `BoardViewModel`, never rebuilt inside a `ForEach`.
@MainActor
final class CardInteraction: ObservableObject, Identifiable {
  let id: UUID
  // A visible non-editing card only needs its serialized text and drag preview. Keep the
  // AppKit/editor support graph lazy so panning across a large board does not allocate an
  // NSTextView controller, linter, popover state, and connector search state for every card.
  lazy var mentions = MentionState()
  lazy var appSearch = AppSearchState()
  lazy var controller = EditorController()
  lazy var lint = LintState()
  lazy var refine = RefineState()
  private var plainTextCache: String
  private var inkCache: [InkRun] = []
  private var attributedCache: NSAttributedString?

  /// The visible string (`tv.string`) — drives count/placeholder/change-detection. NOT the
  /// persisted form; persistence and compile use `controller.plainText` (tokens preserved).
  @Published var text: String
  @Published var count: Int
  @Published var selection = EditorSelection()
  @Published var dragDelta: CGSize = .zero

  init(_ card: CardState) {
    self.id = card.id
    self.text = card.text
    self.count = card.text.count
    self.plainTextCache = card.text
    self.inkCache = card.ink ?? []
  }

  /// Self-contained plain text (mention tokens serialized back to `@name`). Falls back to
  /// the last captured editor value while the heavy AppKit editor is unmounted. `text` is kept
  /// in serialized form while editing, and `captureEditorState()` refreshes this cache before an
  /// editor leaves the view tree, so reading a static card never needs to instantiate its editor.
  var plainText: String {
    plainTextCache
  }

  var attributedSnapshot: NSAttributedString? { attributedCache }

  /// Per-range text ink for the current serialized text — always extracted alongside the
  /// plain-text cache from the same attributed string, so offsets agree even mid-edit.
  var ink: [InkRun] { inkCache }

  func captureEditorState() {
    if let snapshot = controller.attributedSnapshot {
      attributedCache = snapshot
      let (plain, runs) = snapshot.composerPlainTextAndInk
      plainTextCache = plain
      inkCache = runs
      count = snapshot.string.count
    } else if let (plain, runs) = controller.plainTextAndInkIfLoaded {
      plainTextCache = plain
      inkCache = runs
    }
  }

  func cachePlainText(_ value: String) {
    plainTextCache = value
    // Ink offsets are over the serialized text — re-extract from the live editor (loaded while
    // editing) so a run and its offsets always match this exact serialization.
    if let (_, runs) = controller.plainTextAndInkIfLoaded { inkCache = runs }
  }

  /// The ink runs currently in the live editor (peeked, not cached) — nil coalesces to the cache
  /// when the editor is unmounted. Lets the board diff a fresh inking against the committed cache.
  var editorInk: [InkRun] {
    controller.plainTextAndInkIfLoaded?.ink ?? inkCache
  }

  /// Refresh the ink cache from the live editor after an inking action that leaves the
  /// serialized text unchanged (so `cachePlainText` didn't fire).
  func refreshInkFromEditor() {
    if let (_, runs) = controller.plainTextAndInkIfLoaded { inkCache = runs }
  }
}

// MARK: - Board view-model

/// Immutable board-wide text state shared by every card renderer for one text revision.
///
/// Rendering consumes ONLY `definedVariableNames` — chips style the card's literal source text and
/// use the set purely for membership (is `$name` a defined reference?) via
/// `ShellTemplate.expressions(in:definedNames:)`. Definition VALUES are never rendered; they are
/// expanded exclusively at copy time (`ShellTemplate.expand`). That's why `BoardCardLayer.==`
/// compares only the name set: `revision` bumps on nearly every mutation, and including it would
/// rebuild every card per keystroke — the exact cost this type exists to avoid. `revision` stays
/// here as the derivation counter proving the context is rebuilt once per text change.
struct BoardTextContext: Equatable {
  let revision: UInt64
  let definedVariableNames: Set<String>
}

/// Owns the working board: the cards' geometry (`cards`) and their runtime bundles
/// (`interactions`), plus which card is active. The single `@StateObject` the canvas holds;
/// the only writer to the store for the current board.
@MainActor
final class BoardViewModel: ObservableObject {
  private let store: DumpStore
  private struct HistorySnapshot {
    var cards: [CardState]
    var selectedCardIDs: Set<UUID>
    var primarySelectedCardID: UUID?
    var editingCardID: UUID?
    var nextZ: Int
  }

  /// Geometry + last-saved text + z-order, newest-placed last. Live text lives in the
  /// matching `CardInteraction`; `text` here is only the seed/persisted snapshot.
  @Published private(set) var cards: [CardState] = []
  /// Selected cards — show selection rings and receive group operations.
  @Published private(set) var selectedCardIDs: Set<UUID> = []
  /// The lead selection. This is the card that gets destructive/action chrome when several
  /// cards are selected.
  @Published private(set) var primarySelectedCardID: UUID?
  /// The card in text-edit mode (its editor holds first responder). Anchored overlays
  /// (mentions, connector search, linter, selection bar) route here.
  @Published var editingCardID: UUID?

  /// `$(…)` commands that failed on the last Copy Board, so their tokens render amber. Set by the
  /// copy; cleared on the next copy and whenever the board text changes.
  @Published var failedShellCommands: Set<String> = []

  /// The graph card a single, parseable equation is currently being dragged over — set while a lone
  /// equation's live center lands inside a graph frame (and its LaTeX parses), cleared when the drag
  /// leaves or ends. Graph cards read it to draw the accent drop-target ring.
  @Published private(set) var equationDropTargetID: UUID?

  /// Alignment guide lines to draw while a card MOVE drag is snapping (board space). Set from the
  /// live preview via `snappedDelta(for:proposed:)`, and ALWAYS cleared on commit/cancel/clear so
  /// the hairlines never outlive the gesture.
  @Published private(set) var snapGuides: [SnapEngine.Guide] = []

  private var interactions: [UUID: CardInteraction] = [:]
  private var movePreviewIDs: Set<UUID> = []
  private var movePreviewDelta: CGSize = .zero
  /// Set by `beginDragDuplicate` so the drag's finishMovePreview joins the duplicate's undo
  /// checkpoint instead of opening a second one — the whole ⌥-drag gesture is one intention.
  private var foldNextMoveUndo = false
  private var nextZ = 1
  private var undoStack: [HistorySnapshot] = []
  private var redoStack: [HistorySnapshot] = []
  private var textEditBaselines: [UUID: String] = [:]
  /// During an active edit, `setText` publishes through `CardInteraction`, so the card view observes
  /// the same value after the mutation already registered undo. Remember that exact value until
  /// `noteEdited` consumes it; comparing against `CardState.text` is unsafe because live inline
  /// edits intentionally leave the serialized card snapshot stale until persistence.
  private var committedTextNotifications: [UUID: String] = [:]
  /// Cards with a live `BoardCardView`. Programmatic text updates only need a notification marker
  /// when a mounted view can observe `CardInteraction.text`; keeping this explicit prevents both a
  /// duplicate undo checkpoint for visible cards and stale markers for culled/off-screen cards.
  private var mountedCardIDs: Set<UUID> = []
  private var isRestoringHistory = false
  /// Set while a compound mutation (e.g. building a whole diagram) runs, so the inner
  /// `insertText`/`connectCards` calls don't each push their own undo step — the batch registers
  /// exactly one at the top.
  private var suppressUndo = false
  /// Compound operations can touch many text-bearing cards. Delay the expensive board-wide
  /// definition scan until the outermost operation finishes while keeping independent mutations
  /// immediately observable.
  private var boardTextContextBatchDepth = 0
  private var boardTextContextInvalidationPending = false
  /// Who authored the next mutation: `Author.human` by default; the canvas bridge flips it to
  /// `Author.agent` while applying an agent's edits, so every card records who last wrote it.
  var nextAuthor = Author.human

  enum Author { static let human = 1; static let agent = 2 }
  private let maxHistoryDepth = 80
  /// Undo/redo kept per board, so flipping to another board and back doesn't lose your history.
  /// Inactive boards are evicted by least-recent use and by the total number of cards retained in
  /// their snapshots. The active board always remains in `undoStack`/`redoStack`, never this cache.
  static let maxCachedHistoryBoards = 8
  static let maxCachedHistorySnapshotCards = 8_000
  private struct HistoryCacheEntry {
    var undo: [HistorySnapshot]
    var redo: [HistorySnapshot]
    var lastAccess: UInt64

    var snapshotCardCount: Int {
      undo.reduce(0) { $0 + $1.cards.count } + redo.reduce(0) { $0 + $1.cards.count }
    }
  }
  private var undoCache: [PersistentIdentifier: HistoryCacheEntry] = [:]
  private var historyCacheClock: UInt64 = 0
  private var currentBoardID: PersistentIdentifier?
  /// A live editor frame is local rendering state until the edit boundary. Keeping it out of
  /// `cards` prevents every editor layout callback from publishing the whole board layer.
  private var liveTextFrames: [UUID: CGRect] = [:]

  private(set) var boardTextContextDerivationCount = 0
  @Published private(set) var boardTextContext = BoardTextContext(revision: 0, definedVariableNames: [])
  private var boardTextRevision: UInt64 = 0

  /// Test/diagnostic seam for proving the bounded history policy without exposing the cache itself.
  var cachedHistoryBoardCount: Int { undoCache.count }
  var cachedHistorySnapshotCardCount: Int {
    undoCache.values.reduce(0) { $0 + $1.snapshotCardCount }
  }
  var cachedHistoryBoardIDs: Set<PersistentIdentifier> { Set(undoCache.keys) }
  var hasMeaningfulContent: Bool {
    cards.contains { card in
      card.elementKind != .text ||
        !plainText(for: card).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
  }

  /// The injectable store exists for tests (an in-memory `DumpStore`); the app always uses shared.
  /// (`nil` default rather than `= .shared`: a default-argument expression is nonisolated, so it
  /// can't touch the main-actor singleton.)
  init(store: DumpStore? = nil) {
    self.store = store ?? DumpStore.shared
    loadFromStore()
  }

  // MARK: Access

  /// The cached runtime bundle for a card (created on demand, identity-stable).
  func interaction(for id: UUID) -> CardInteraction {
    if let existing = interactions[id] { return existing }
    let seed = cards.first { $0.id == id } ?? CardState.firstCard()
    let made = CardInteraction(seed)
    interactions[id] = made
    return made
  }

  /// Reads the most recent text without creating a runtime/editor bundle for an off-screen card.
  func plainText(for card: CardState) -> String {
    // An image card contributes its file path so Copy, Compile, and Describe emit a concrete
    // reference the reader (or a coding agent) can open. An image with no path yet contributes nothing.
    if card.elementKind == .image { return card.resolvedImageURL?.path ?? card.imagePath ?? "" }
    if card.elementKind == .equation {
      let latex = (card.latex ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      return latex.isEmpty ? "" : "$$\(latex)$$"
    }
    if card.elementKind == .sticky {
      return [card.stickyTitle?.trimmed ?? "", card.text.trimmed]
        .filter { !$0.isEmpty }
        .joined(separator: "\n\n")
    }
    if card.elementKind == .checklist {
      return (card.checklist ?? []).map { "\($0.isChecked ? "[x]" : "[ ]") \($0.text)" }.joined(separator: "\n")
    }
    if card.elementKind == .table {
      let spec = card.table ?? CardState.TableSpec()
      let header = "| " + spec.columns.joined(separator: " | ") + " |"
      let rule = "| " + spec.columns.map { _ in "---" }.joined(separator: " | ") + " |"
      return ([header, rule] + spec.rows.map { "| " + $0.joined(separator: " | ") + " |" }).joined(separator: "\n")
    }
    return interactions[card.id]?.plainText ?? card.text
  }

  /// The card's per-range ink, read from the live runtime bundle when present (so an unsaved
  /// inking is captured) and falling back to the persisted runs. Offsets always match
  /// `plainText(for:)` — both come from the same cache refresh.
  func ink(for card: CardState) -> [InkRun] {
    interactions[card.id]?.ink ?? card.ink ?? []
  }

  var selectedInteraction: CardInteraction? { selectedCardID.flatMap { interactions[$0] } }
  var editingInteraction: CardInteraction? { editingCardID.flatMap { interactions[$0] } }
  var selectedCardID: UUID? { primarySelectedCardID }

  /// The card geometry currently painted on the canvas. Text editing keeps its live hug outside
  /// `cards` to avoid publishing the whole board on every layout callback, so viewport consumers
  /// must use this accessor rather than reading the persisted frame directly.
  func renderingFrame(for id: UUID) -> CGRect? {
    liveTextFrames[id] ?? cards.first(where: { $0.id == id })?.frame
  }

  private func index(for id: UUID) -> Int? {
    cards.firstIndex { $0.id == id }
  }

  private func selectionSet(for id: UUID) -> Set<UUID> {
    guard let i = index(for: id), let groupID = cards[i].groupID else { return [id] }
    return Set(cards.filter { $0.groupID == groupID }.map(\.id))
  }

  private func expandedGroups(_ ids: Set<UUID>) -> Set<UUID> {
    ids.reduce(into: Set<UUID>()) { result, id in
      result.formUnion(selectionSet(for: id))
    }
  }

  private func unlockedIDs(in ids: Set<UUID>) -> Set<UUID> {
    Set(cards.filter { ids.contains($0.id) && !$0.locked }.map(\.id))
  }

  /// Single-click: select without entering text edit (Excalidraw — drag then moves it).
  func select(_ id: UUID, extending: Bool = false, toggling: Bool = false) {
    if let editing = editingCardID, editing != id { stopEditing() }
    let target = selectionSet(for: id)
    if toggling {
      if target.isSubset(of: selectedCardIDs) {
        selectedCardIDs.subtract(target)
        if let primarySelectedCardID, target.contains(primarySelectedCardID) {
          self.primarySelectedCardID = selectedCardIDs.first
        }
      } else {
        selectedCardIDs.formUnion(target)
        primarySelectedCardID = id
      }
    } else if extending {
      selectedCardIDs.formUnion(target)
      primarySelectedCardID = id
    } else {
      selectedCardIDs = target
      primarySelectedCardID = id
    }
  }

  /// Double-click / freshly placed card / click into the editor: enter text edit.
  func beginEditing(_ id: UUID) {
    // Placement focus is delayed until the editor mounts. The card may have been abandoned during
    // that delay, so never resurrect selection/editing state for an ID that no longer exists.
    guard let card = cards.first(where: { $0.id == id }),
          !card.locked,
          card.elementKind.supportsEditing else { return }
    selectedCardIDs = [id]
    primarySelectedCardID = id
    editingCardID = id
  }

  /// The editor lost first responder (a click-away). This is the user-driven end of an edit, so an
  /// empty text card typed into nothing is abandoned — delete it (undoably, through the shared
  /// delete path so bound arrows refresh) instead of leaving a stray writing spot on the board.
  func endEditing(_ id: UUID) {
    interactions[id]?.captureEditorState()
    if !commitLiveTextFrame(id) {
      fitTextSize(id)   // final hug on the settled text (the cache was just refreshed)
    }
    textEditBaselines[id] = nil
    if editingCardID == id { editingCardID = nil }
    discardIfAbandoned(id)
  }

  /// A text card whose edit ends with no meaningful text was abandoned — delete it (undoably,
  /// through the shared delete path so bound arrows refresh) instead of leaving a ghost writing
  /// spot on the board. `captureEditorState()` runs before every call, so this reads what the
  /// user actually left in the editor — not the stale seed snapshot in `cards[i].text`.
  /// Non-text elements are kept: an empty shape or sticky is an intentional placement.
  private func discardIfAbandoned(_ id: UUID) {
    guard let i = index(for: id), cards[i].elementKind == .text,
          plainText(for: cards[i]).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return }
    delete(id, createStarterIfEmpty: false)
  }

  /// Click on empty board: drop selection and leave text edit (resigning the editor).
  func deselectAll() {
    stopEditing()
    selectedCardIDs = []
    primarySelectedCardID = nil
    cancelMovePreview()
  }

  private func stopEditing() {
    guard let id = editingCardID else { return }
    interactions[id]?.captureEditorState()
    if !commitLiveTextFrame(id) {
      fitTextSize(id)   // final hug on the settled text (the cache was just refreshed)
    }
    textEditBaselines[id] = nil
    interactions[id]?.controller.resignFocus()
    editingCardID = nil
    // `resignFocus()` is a no-op when the editor never actually took first responder (a click-away
    // during the mount/focus delay of a freshly placed card), so the editor's own focus-loss
    // callback never fires `endEditing` — the abandoned-card discard must also happen here.
    discardIfAbandoned(id)
    // Structured stages keep equation input as a local draft. If navigation/teardown retires the
    // session before that draft ever commits, remove the invisible blank equation as well.
    pruneBlankEquation(id)
  }

  // MARK: Load / save

  /// Pull the current board's cards into the working set, rebuilding bundles.
  func loadFromStore() {
    // Move the outgoing board to the bounded inactive cache before restoring the incoming board.
    // Set the active id first so eviction can never mistake the board being loaded for an inactive
    // entry when a large history cache is trimmed.
    let nextBoardID = store.currentID
    let isReloadingSameBoard = currentBoardID == nextBoardID
    if let previous = currentBoardID, previous != nextBoardID {
      currentBoardID = nextBoardID
      cacheHistory(for: previous, undo: undoStack, redo: redoStack)
    } else {
      currentBoardID = nextBoardID
    }
    let loaded = store.currentCards
    cards = loaded
    // Fit every text card's HEIGHT to its content at its stored width and font scale — no live
    // editor is mounted to report heights yet. Width is left as saved (a scaled card persists its
    // hugged width), so this never reflows the board's horizontal layout on load.
    for i in cards.indices where cards[i].elementKind == .text {
      cards[i].h = Double(Self.fittedTextHeight(cards[i].text, width: cards[i].w, fontScale: cards[i].textScale))
    }
    // Runtime bundles are created lazily as cards become visible or enter edit mode. A board can
    // contain hundreds of cards, but only a small cullable subset should carry editor state.
    interactions = [:]
    liveTextFrames = [:]
    nextZ = (cards.map(\.z).max() ?? 0) + 1
    let restored = currentBoardID.flatMap { undoCache.removeValue(forKey: $0) }
    undoStack = restored?.undo ?? (isReloadingSameBoard ? undoStack : [])
    redoStack = restored?.redo ?? (isReloadingSameBoard ? redoStack : [])
    textEditBaselines = [:]
    committedTextNotifications = [:]
    if let first = loaded.first?.id {
      selectedCardIDs = [first]
      primarySelectedCardID = first
    } else {
      selectedCardIDs = []
      primarySelectedCardID = nil
    }
    editingCardID = nil
    invalidateBoardTextContext()
  }

  private func cacheHistory(for boardID: PersistentIdentifier,
                            undo: [HistorySnapshot],
                            redo: [HistorySnapshot]) {
    guard boardID != currentBoardID else { return }
    historyCacheClock &+= 1
    undoCache[boardID] = HistoryCacheEntry(undo: undo, redo: redo, lastAccess: historyCacheClock)
    trimHistoryCache()
  }

  private func trimHistoryCache() {
    while undoCache.count > Self.maxCachedHistoryBoards ||
            cachedHistorySnapshotCardCount > Self.maxCachedHistorySnapshotCards {
      guard let oldestID = undoCache
        .filter({ $0.key != currentBoardID })
        .min(by: { $0.value.lastAccess < $1.value.lastAccess })?.key else { return }
      undoCache.removeValue(forKey: oldestID)
    }
  }

  private func invalidateBoardTextContext() {
    if boardTextContextBatchDepth > 0 {
      boardTextContextInvalidationPending = true
      return
    }
    boardTextRevision &+= 1
    boardTextContextDerivationCount += 1
    boardTextContext = BoardTextContext(
      revision: boardTextRevision,
      definedVariableNames: ShellTemplate.definedNames(in: joinedPlainText()))
  }

  private func beginBoardTextContextBatch() {
    boardTextContextBatchDepth += 1
  }

  private func endBoardTextContextBatch() {
    precondition(boardTextContextBatchDepth > 0)
    boardTextContextBatchDepth -= 1
    guard boardTextContextBatchDepth == 0, boardTextContextInvalidationPending else { return }
    boardTextContextInvalidationPending = false
    invalidateBoardTextContext()
  }

  /// Geometry + live plain text, ready to persist.
  func renderingSnapshot(for source: [CardState]) -> [CardState] {
    var appliedLiveFrame = false
    var snapshot = source.map { card -> CardState in
      var copy = card
      if let liveFrame = liveTextFrames[card.id] {
        copy.frame = CGRect(origin: copy.frame.origin, size: liveFrame.size)
        appliedLiveFrame = true
      }
      return copy
    }
    // The live hug resized a card committed connector geometry was anchored against, so re-derive
    // bound connectors ON THE COPY — a mid-edit save/export must not persist the new frame with them
    // still aimed at the old one. Done on the snapshot (never the published `cards`) because this
    // runs from the save debounce and the exporter, which must stay side-effect-free.
    if appliedLiveFrame { snapshot = ConnectorGeometry.refreshing(in: snapshot) }
    return snapshot
  }

  private func snapshot() -> [CardState] {
    renderingSnapshot(for: cards).map { card in
      var copy = card
      copy.text = persistedText(for: card)
      if card.elementKind == .text {
        let runs = ink(for: card)
        copy.ink = runs.isEmpty ? nil : runs
      }
      return copy
    }
  }

  private func persistedText(for card: CardState) -> String {
    switch card.elementKind {
    case .image, .sticky, .checklist, .table:
      // Structured elements expose a composed Markdown/plain-text representation to Compile and
      // agents, but their persisted `text` field must remain only their own body/label payload.
      return card.text
    default:
      return plainText(for: card)
    }
  }

  /// Build the persistence snapshot only when the debounce actually fires. This avoids cloning
  /// the entire board on every keystroke and keeps cancelled saves from retaining stale snapshots.
  func scheduleSave() { store.scheduleUpdate { [weak self] in self?.snapshot() } }
  /// Force the current snapshot to storage. Remount-only flushes keep the active edit alive; real
  /// navigation/teardown callers opt into ending it so an abandoned blank is discarded.
  @discardableResult
  func flushSave(abandoningActiveEdit: Bool = false) -> Bool {
    if abandoningActiveEdit { stopEditing() }
    return store.flush(cards: snapshot())
  }

  @discardableResult
  func duplicateProtectedBoardForEditing() -> Bool {
    guard store.duplicateProtectedCurrentBoard(cards: snapshot()) else { return false }
    loadFromStore()
    return true
  }

  private func historySnapshot(cards overrideCards: [CardState]? = nil) -> HistorySnapshot {
    HistorySnapshot(
      cards: overrideCards ?? snapshot(),
      selectedCardIDs: selectedCardIDs,
      primarySelectedCardID: primarySelectedCardID,
      editingCardID: editingCardID,
      nextZ: nextZ
    )
  }

  private func registerUndo(_ snapshot: HistorySnapshot? = nil) {
    guard !isRestoringHistory, !suppressUndo else { return }
    undoStack.append(snapshot ?? historySnapshot())
    if undoStack.count > maxHistoryDepth { undoStack.removeFirst(undoStack.count - maxHistoryDepth) }
    redoStack.removeAll()
  }

  func registerUndoCheckpoint() {
    registerUndo()
  }

  private func restore(_ value: HistorySnapshot) {
    isRestoringHistory = true
    cards = value.cards
    interactions = [:]
    liveTextFrames = [:]
    selectedCardIDs = value.selectedCardIDs.intersection(Set(value.cards.map(\.id)))
    primarySelectedCardID = selectedCardIDs.contains(value.primarySelectedCardID ?? UUID())
      ? value.primarySelectedCardID
      : selectedCardIDs.first
    editingCardID = nil
    nextZ = max(value.nextZ, (value.cards.map(\.z).max() ?? 0) + 1)
    clearMovePreview()
    textEditBaselines = [:]
    committedTextNotifications = [:]
    scheduleSave()
    isRestoringHistory = false
    invalidateBoardTextContext()
  }

  func undo() {
    guard let previous = undoStack.popLast() else { return }
    redoStack.append(historySnapshot())
    restore(previous)
  }

  func redo() {
    guard let next = redoStack.popLast() else { return }
    undoStack.append(historySnapshot())
    restore(next)
  }

  // MARK: Mutations

  /// Place a new text element where you clicked — the click is the start of its first line
  /// (Excalidraw point text), not the center of a box. Returns its id so the canvas can focus it.
  @discardableResult
  func addCard(at point: CGPoint) -> UUID {
    registerUndo()
    let size = CardState.textDefaultSize
    let card = CardState(
      text: "",
      x: Double(point.x),
      y: Double(point.y - size.height / 2),
      w: Double(size.width),
      h: Double(size.height),
      z: nextZ,
      whoWrote: nextAuthor)
    nextZ += 1
    cards.append(card)
    interactions[card.id] = CardInteraction(card)
    selectedCardIDs = [card.id]
    primarySelectedCardID = card.id
    editingCardID = card.id
    invalidateBoardTextContext()
    scheduleSave()
    return card.id
  }

  @discardableResult
  func addElement(_ kind: CanvasElementKind, at center: CGPoint) -> UUID {
    if kind == .text { return addCard(at: center) }
    registerUndo()
    let size: CGSize = {
      switch kind {
      case .line, .arrow, .freehand, .vectorPath: CardState.lineSize
      case .equation: CardState.equationSize
      case .graph: CardState.graphSize
      case .sticky: CardState.stickySize
      case .checklist: CardState.checklistSize
      case .table: CardState.tableSize
      case .image: CardState.shapeSize
      case .rectangle, .ellipse, .diamond: CardState.shapeSize
      case .text: CardState.defaultSize
      }
    }()
    let initialPoints: [CanvasPoint]? = {
      switch kind {
      case .line, .arrow:
        return CardState.defaultLinePoints()
      case .freehand:
        return CardState.defaultFreehandPoints()
      case .text, .rectangle, .ellipse, .diamond, .vectorPath, .image, .equation, .graph, .sticky, .checklist, .table:
        return nil
      }
    }()
    var card = CardState(
      kind: kind,
      text: "",
      x: Double(center.x - size.width / 2),
      y: Double(center.y - size.height / 2),
      w: Double(size.width),
      h: Double(size.height),
      z: nextZ,
      points: initialPoints,
      whoWrote: nextAuthor,
      tint: kind == .image ? nil : currentTint
    )
    if kind == .checklist {
      card.checklist = [CardState.ChecklistItem(text: "New task")]
    } else if kind == .table {
      card.table = CardState.TableSpec()
    }
    nextZ += 1
    cards.append(card)
    if ConnectorGeometry.isConnector(card) { bindConnectorIfPossible(card.id) }
    interactions[card.id] = CardInteraction(card)
    selectedCardIDs = [card.id]
    primarySelectedCardID = card.id
    editingCardID = nil
    invalidateBoardTextContext()
    scheduleSave()
    return card.id
  }

  /// Create a shape or line sized by a drag from `start` to `end` (board space). Lines/arrows
  /// keep the two points as their endpoints; boxes use the bounding frame. Clamped to a minimum.
  @discardableResult
  func addDrawnElement(_ kind: CanvasElementKind, from start: CGPoint, to end: CGPoint) -> UUID? {
    guard kind != .text, kind != .freehand, kind != .vectorPath, kind != .image,
          kind != .equation, kind != .graph else { return nil }
    registerUndo()
    let isLine = (kind == .line || kind == .arrow)
    let minSize = isLine ? CardState.lineMinSize : CardState.shapeMinSize
    var minX = min(start.x, end.x), minY = min(start.y, end.y)
    var maxX = max(start.x, end.x), maxY = max(start.y, end.y)
    if maxX - minX < minSize.width { let pad = (minSize.width - (maxX - minX)) / 2; minX -= pad; maxX += pad }
    if maxY - minY < minSize.height { let pad = (minSize.height - (maxY - minY)) / 2; minY -= pad; maxY += pad }
    let frame = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    let points: [CanvasPoint]? = isLine ? [
      CanvasPoint(x: Double((start.x - frame.minX) / frame.width), y: Double((start.y - frame.minY) / frame.height)),
      CanvasPoint(x: Double((end.x - frame.minX) / frame.width), y: Double((end.y - frame.minY) / frame.height)),
    ] : nil
    let card = CardState(
      kind: kind, text: "",
      x: Double(frame.minX), y: Double(frame.minY), w: Double(frame.width), h: Double(frame.height),
      z: nextZ, points: points, whoWrote: nextAuthor, tint: currentTint)
    nextZ += 1
    cards.append(card)
    if ConnectorGeometry.isConnector(card) { bindConnectorIfPossible(card.id) }
    interactions[card.id] = CardInteraction(card)
    selectedCardIDs = [card.id]
    primarySelectedCardID = card.id
    editingCardID = nil
    invalidateBoardTextContext()
    scheduleSave()
    return card.id
  }

  @discardableResult
  func addFreehandStroke(frame: CGRect, points: [CanvasPoint]) -> UUID? {
    guard points.count > 1 else { return nil }
    registerUndo()
    let size = CardState.lineMinSize
    let normalized = CGRect(
      x: frame.minX,
      y: frame.minY,
      width: max(frame.width, size.width),
      height: max(frame.height, size.height)
    )
    let card = CardState(
      kind: .freehand,
      text: "",
      x: Double(normalized.minX),
      y: Double(normalized.minY),
      w: Double(normalized.width),
      h: Double(normalized.height),
      z: nextZ,
      points: points,
      whoWrote: nextAuthor,
      tint: currentTint
    )
    nextZ += 1
    cards.append(card)
    interactions[card.id] = CardInteraction(card)
    selectedCardIDs = [card.id]
    primarySelectedCardID = card.id
    editingCardID = nil
    invalidateBoardTextContext()
    scheduleSave()
    return card.id
  }

  @discardableResult
  func addVectorPath(_ placement: VectorPathPlacement) -> UUID? {
    let minimumNodes = placement.spec.isClosed ? 3 : 2
    guard placement.spec.nodes.count >= minimumNodes,
          placement.frame.width.isFinite,
          placement.frame.height.isFinite,
          placement.frame.width > 0,
          placement.frame.height > 0 else { return nil }
    registerUndo()
    let card = CardState(
      kind: .vectorPath,
      x: placement.frame.minX,
      y: placement.frame.minY,
      w: placement.frame.width,
      h: placement.frame.height,
      z: nextZ,
      vectorPath: placement.spec,
      whoWrote: nextAuthor,
      tint: currentTint)
    nextZ += 1
    cards.append(card)
    interactions[card.id] = CardInteraction(card)
    selectedCardIDs = [card.id]
    primarySelectedCardID = card.id
    editingCardID = nil
    invalidateBoardTextContext()
    scheduleSave()
    return card.id
  }

  @discardableResult
  func addImageObject(path: String, at center: CGPoint) -> UUID {
    registerUndo()
    let storedPath = Self.storedImagePath(for: path)
    let size = Self.imageCardSize(forPath: storedPath)
    let card = CardState(
      kind: .image,
      text: "",
      x: Double(center.x - size.width / 2),
      y: Double(center.y - size.height / 2),
      w: Double(size.width),
      h: Double(size.height),
      z: nextZ,
      imagePath: storedPath,
      whoWrote: nextAuthor
    )
    nextZ += 1
    cards.append(card)
    interactions[card.id] = CardInteraction(card)
    selectedCardIDs = [card.id]
    primarySelectedCardID = card.id
    editingCardID = nil
    invalidateBoardTextContext()
    scheduleSave()
    return card.id
  }

  /// A dropped image keeps its own aspect ratio: size the card to the image so its rounded border and
  /// the selection ring coincide instead of the image overflowing (or letterboxing) a fixed landscape
  /// default. Reads just the pixel dimensions — no full decode — and fits them into an on-board
  /// footprint; falls back to the shape default if the file can't be read.
  private static func imageCardSize(forPath path: String) -> CGSize {
    guard
      let url = AssetStore.resolve(path),
      let source = CGImageSourceCreateWithURL(url as CFURL, nil),
      let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let pixelWidth = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
      let pixelHeight = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
      pixelWidth > 0, pixelHeight > 0
    else { return CardState.shapeSize }

    let maxSide: CGFloat = 260
    let aspect = CGFloat(pixelWidth / pixelHeight)
    let size = aspect >= 1
      ? CGSize(width: maxSide, height: maxSide / aspect)
      : CGSize(width: maxSide * aspect, height: maxSide)
    return CGSize(width: size.width.rounded(), height: size.height.rounded())
  }

  private static func storedImagePath(for path: String) -> String {
    if let url = AssetStore.resolve(path) {
      return AssetStore.ingest(fileURL: url) ?? url.lastPathComponent
    }
    if path.hasPrefix("/") {
      let url = URL(fileURLWithPath: path)
      return AssetStore.ingest(fileURL: url) ?? url.lastPathComponent
    }
    return path
  }

  // MARK: Programmatic mutations (canvas API / external agents)

  /// Insert a text card carrying `text` at a board point, without entering edit mode — used by
  /// the canvas API so an agent can drop content without stealing the caret.
  @discardableResult
  func insertText(_ text: String, at point: CGPoint) -> UUID {
    registerUndo()
    let width = CardState.textDefaultSize.width
    let card = CardState(text: text, x: Double(point.x), y: Double(point.y),
                         w: Double(width), h: Double(Self.fittedTextHeight(text, width: width)), z: nextZ,
                         whoWrote: nextAuthor)
    nextZ += 1
    cards.append(card)
    interactions[card.id] = CardInteraction(card)
    selectedCardIDs = [card.id]
    primarySelectedCardID = card.id
    invalidateBoardTextContext()
    scheduleSave()
    return card.id
  }

  /// Insert an equation card carrying raw LaTeX math-mode source at a board point, without entering
  /// edit mode — used by the canvas API so an agent can drop math without stealing the caret.
  @discardableResult
  func insertEquation(_ latex: String, at point: CGPoint) -> UUID {
    registerUndo()
    let size = CardState.equationSize
    let card = CardState(kind: .equation, text: "", x: Double(point.x), y: Double(point.y),
                         w: Double(size.width), h: Double(size.height), z: nextZ,
                         latex: latex, whoWrote: nextAuthor)
    nextZ += 1
    cards.append(card)
    interactions[card.id] = CardInteraction(card)
    selectedCardIDs = [card.id]
    primarySelectedCardID = card.id
    editingCardID = nil
    invalidateBoardTextContext()
    scheduleSave()
    return card.id
  }

  @discardableResult
  func insertStructured(_ kind: CanvasElementKind, title: String? = nil, text: String = "", checklist: [CardState.ChecklistItem]? = nil,
                        table: CardState.TableSpec? = nil, at point: CGPoint) -> UUID {
    registerUndo()
    let size = kind == .sticky ? CardState.stickySize : (kind == .checklist ? CardState.checklistSize : CardState.tableSize)
    let card = CardState(kind: kind, text: text, x: Double(point.x), y: Double(point.y),
                         w: Double(size.width), h: Double(size.height), z: nextZ,
                         stickyTitle: title, checklist: checklist, table: table,
                         whoWrote: nextAuthor, tint: currentTint)
    nextZ += 1
    cards.append(card)
    selectedCardIDs = [card.id]
    primarySelectedCardID = card.id
    invalidateBoardTextContext()
    scheduleSave()
    return card.id
  }

  @discardableResult
  func setSticky(_ id: UUID, title: String, body: String) -> Bool {
    guard let i = index(for: id), cards[i].elementKind == .sticky else { return false }
    registerUndo()
    cards[i].stickyTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
    cards[i].text = body
    cards[i].whoWrote = nextAuthor
    let bundle = interaction(for: id)
    bundle.text = body
    bundle.cachePlainText(body)
    invalidateBoardTextContext()
    scheduleSave()
    return true
  }

  @discardableResult
  func toggleChecklistItem(_ id: UUID, index itemIndex: Int) -> Bool {
    guard let i = index(for: id), cards[i].elementKind == .checklist,
          !cards[i].locked,
          cards[i].checklist?.indices.contains(itemIndex) == true else { return false }
    registerUndo()
    cards[i].checklist![itemIndex].isChecked.toggle()
    cards[i].whoWrote = nextAuthor
    invalidateBoardTextContext()
    scheduleSave()
    return true
  }

  /// Apple Notes-style checklist syntax remains ordinary text, so an existing note can opt into
  /// tappable todos without converting to a different element or losing mentions/markdown.
  func toggleTextChecklistLine(_ id: UUID, lineIndex: Int) {
    guard let i = index(for: id), cards[i].elementKind == .text, !cards[i].locked else { return }
    var lines = plainText(for: cards[i]).components(separatedBy: "\n")
    guard lines.indices.contains(lineIndex) else { return }
    if lines[lineIndex].hasPrefix("- [ ] ") {
      lines[lineIndex].replaceSubrange(lines[lineIndex].startIndex..<lines[lineIndex].index(lines[lineIndex].startIndex, offsetBy: 6), with: "- [x] ")
    } else if lines[lineIndex].lowercased().hasPrefix("- [x] ") {
      lines[lineIndex].replaceSubrange(lines[lineIndex].startIndex..<lines[lineIndex].index(lines[lineIndex].startIndex, offsetBy: 6), with: "- [ ] ")
    } else { return }
    setText(id, lines.joined(separator: "\n"))
  }

  @discardableResult
  func setChecklist(_ id: UUID, _ items: [CardState.ChecklistItem]) -> Bool {
    guard let i = index(for: id), cards[i].elementKind == .checklist, !cards[i].locked else { return false }
    registerUndo(); cards[i].checklist = items; cards[i].whoWrote = nextAuthor
    invalidateBoardTextContext(); scheduleSave()
    return true
  }

  @discardableResult
  func setTable(_ id: UUID, _ spec: CardState.TableSpec) -> Bool {
    guard let i = index(for: id), cards[i].elementKind == .table else { return false }
    registerUndo(); cards[i].table = spec; cards[i].whoWrote = nextAuthor
    invalidateBoardTextContext(); scheduleSave()
    return true
  }

  /// Drop a blank graph card centered on `point` (board space), carrying a default spec so it
  /// renders empty axes immediately. Mirrors `insertEquation`'s placement path. Selects it.
  @discardableResult
  func addGraph(at point: CGPoint) -> UUID {
    registerUndo()
    let size = CardState.graphSize
    let card = CardState(kind: .graph, text: "",
                         x: Double(point.x - size.width / 2), y: Double(point.y - size.height / 2),
                         w: Double(size.width), h: Double(size.height), z: nextZ,
                         graph: CardState.GraphSpec(), whoWrote: nextAuthor)
    nextZ += 1
    cards.append(card)
    interactions[card.id] = CardInteraction(card)
    selectedCardIDs = [card.id]
    primarySelectedCardID = card.id
    editingCardID = nil
    invalidateBoardTextContext()
    scheduleSave()
    return card.id
  }

  /// Replace a card's text (serialized form). The live editor re-chipifies it if mounted.
  /// Fill in an image card's on-device understanding once the OCR/classification pass finishes.
  /// Not an undoable user edit — it's the async completion of a capture, so it skips undo and just
  /// persists. Safe to call after the card was deleted (it no-ops).
  func setImageUnderstanding(_ id: UUID, _ understanding: String) {
    guard let i = cards.firstIndex(where: { $0.id == id }) else { return }
    cards[i].imageUnderstanding = understanding
    scheduleSave()
  }

  func setText(_ id: UUID, _ text: String) {
    guard let i = cards.firstIndex(where: { $0.id == id }) else { return }
    registerUndo()
    if cards[i].elementKind == .equation {
      cards[i].latex = text
      cards[i].whoWrote = nextAuthor
      invalidateBoardTextContext()
      scheduleSave()
      return
    }
    cards[i].text = text
    cards[i].whoWrote = nextAuthor
    let bundle = interaction(for: id)
    if mountedCardIDs.contains(id) || editingCardID == id {
      committedTextNotifications[id] = text
    }
    bundle.text = text
    bundle.cachePlainText(text)
    if cards[i].elementKind == .text { cards[i].h = Double(Self.fittedTextHeight(text, width: cards[i].w, fontScale: cards[i].textScale)) }
    fitShapeSize(id)
    invalidateBoardTextContext()
    scheduleSave()
  }

  /// Update a graph card's spec in place (axis labels, units, ranges, grid). Mirrors `setText`'s
  /// mutation pattern — one undo step, then persist. No-ops on a non-graph card.
  func setGraphSpec(_ id: UUID, _ spec: CardState.GraphSpec) {
    guard let i = cards.firstIndex(where: { $0.id == id }), cards[i].elementKind == .graph else { return }
    registerUndo()
    cards[i].graph = spec
    cards[i].whoWrote = nextAuthor
    scheduleSave()
  }

  @discardableResult
  func absorbEquationIntoGraph(_ equationID: UUID, into graphID: UUID) -> Bool {
    guard equationID != graphID,
          let equationIndex = index(for: equationID),
          let graphIndex = index(for: graphID),
          cards[equationIndex].elementKind == .equation,
          cards[graphIndex].elementKind == .graph else { return false }
    let equation = cards[equationIndex]
    let latex = (equation.latex ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !latex.isEmpty, GraphExpression(latex: latex) != nil else { return false }

    registerUndo()
    var spec = cards[graphIndex].graph ?? CardState.GraphSpec()
    spec.series.append(CardState.GraphSeries(expression: latex, label: latex, tint: equation.tint))
    cards[graphIndex].graph = spec
    cards[graphIndex].whoWrote = nextAuthor

    let previousSuppressUndo = suppressUndo
    suppressUndo = true
    delete(equationID)
    suppressUndo = previousSuppressUndo
    scheduleSave()
    return true
  }

  func addGraphPoint(_ graphID: UUID, at point: CardState.GraphPoint) {
    guard let graphIndex = index(for: graphID), cards[graphIndex].elementKind == .graph else { return }
    registerUndo()
    var spec = cards[graphIndex].graph ?? CardState.GraphSpec()
    if let seriesIndex = spec.series.firstIndex(where: { $0.points != nil }) {
      spec.series[seriesIndex].points?.append(point)
    } else {
      spec.series.append(CardState.GraphSeries(points: [point]))
    }
    cards[graphIndex].graph = spec
    cards[graphIndex].whoWrote = nextAuthor
    scheduleSave()
  }

  func setGraphPoint(_ graphID: UUID,
                     seriesID: UUID,
                     index pointIndex: Int,
                     to point: CardState.GraphPoint,
                     undoable: Bool = true) {
    guard let graphIndex = index(for: graphID),
          cards[graphIndex].elementKind == .graph,
          var spec = cards[graphIndex].graph,
          let seriesIndex = spec.series.firstIndex(where: { $0.id == seriesID }),
          var points = spec.series[seriesIndex].points,
          points.indices.contains(pointIndex) else { return }
    if undoable { registerUndo() }
    points[pointIndex] = point
    spec.series[seriesIndex].points = points
    cards[graphIndex].graph = spec
    cards[graphIndex].whoWrote = nextAuthor
    scheduleSave()
  }

  func removeGraphPoint(_ graphID: UUID, seriesID: UUID, index pointIndex: Int) {
    guard let graphIndex = index(for: graphID),
          cards[graphIndex].elementKind == .graph,
          var spec = cards[graphIndex].graph,
          let seriesIndex = spec.series.firstIndex(where: { $0.id == seriesID }),
          var points = spec.series[seriesIndex].points,
          points.indices.contains(pointIndex) else { return }
    registerUndo()
    points.remove(at: pointIndex)
    spec.series[seriesIndex].points = points
    cards[graphIndex].graph = spec
    cards[graphIndex].whoWrote = nextAuthor
    scheduleSave()
  }

  func removeGraphSeries(_ graphID: UUID, seriesID: UUID) {
    guard let graphIndex = index(for: graphID),
          cards[graphIndex].elementKind == .graph,
          var spec = cards[graphIndex].graph,
          let seriesIndex = spec.series.firstIndex(where: { $0.id == seriesID }) else { return }
    registerUndo()
    spec.series.remove(at: seriesIndex)
    cards[graphIndex].graph = spec
    cards[graphIndex].whoWrote = nextAuthor
    scheduleSave()
  }

  /// Live drop-target update for a lone equation drag: `movedID` is the equation being dragged and
  /// `center` its current board-space center. Highlights the topmost graph whose frame contains the
  /// center when the equation's LaTeX parses; clears otherwise. Cheap — bails immediately unless the
  /// dragged card is a single equation with parseable math.
  func updateEquationDropTarget(movedID: UUID, center: CGPoint) {
    guard let moved = card(id: movedID), moved.elementKind == .equation,
          let latex = moved.latex?.trimmingCharacters(in: .whitespacesAndNewlines), !latex.isEmpty,
          GraphExpression(latex: latex) != nil else {
      if equationDropTargetID != nil { equationDropTargetID = nil }
      return
    }
    let target = cards
      .filter { $0.id != movedID && $0.elementKind == .graph && $0.frame.contains(center) }
      .max(by: { $0.z < $1.z })?
      .id
    if equationDropTargetID != target { equationDropTargetID = target }
  }

  func clearEquationDropTarget() {
    if equationDropTargetID != nil { equationDropTargetID = nil }
  }

  func perpendicularPartner(of id: UUID) -> CardState? {
    guard let base = card(id: id),
          (base.elementKind == .line || base.elementKind == .arrow),
          let baseSegment = lineSegment(for: base) else { return nil }
    let tolerance: CGFloat = 24
    let minimumAngle = 65.0

    return cards.compactMap { candidate -> (card: CardState, distance: CGFloat, angleOffset: Double)? in
      guard candidate.id != id,
            candidate.elementKind == .line || candidate.elementKind == .arrow,
            let candidateSegment = lineSegment(for: candidate) else { return nil }
      let closestEndpointDistance = Self.closestEndpointDistance(baseSegment.endpoints, candidateSegment.endpoints)
      guard closestEndpointDistance <= tolerance else { return nil }
      let dot = abs(baseSegment.vector.dx * candidateSegment.vector.dx + baseSegment.vector.dy * candidateSegment.vector.dy)
      let cosine = min(max(dot / (baseSegment.length * candidateSegment.length), 0), 1)
      let acuteAngle = acos(Double(cosine)) * 180 / Double.pi
      guard acuteAngle >= minimumAngle else { return nil }
      return (candidate, closestEndpointDistance, abs(90 - acuteAngle))
    }
    .min(by: { lhs, rhs in
      lhs.distance != rhs.distance
        ? lhs.distance < rhs.distance
        : lhs.angleOffset < rhs.angleOffset
    })?
    .card
  }

  func convertElementToGraph(_ id: UUID, spec: CardState.GraphSpec) {
    guard let i = index(for: id), cards[i].elementKind == .line || cards[i].elementKind == .arrow else { return }
    let partner = perpendicularPartner(of: id)
    var targetFrame = cards[i].frame
    if let partner { targetFrame = targetFrame.union(partner.frame) }
    targetFrame.size.width = max(targetFrame.width, CardState.graphSize.width)
    targetFrame.size.height = max(targetFrame.height, CardState.graphSize.height)

    registerUndo()
    let previousSuppressUndo = suppressUndo
    suppressUndo = true
    if let partner { delete(partner.id) }
    suppressUndo = previousSuppressUndo

    guard let targetIndex = index(for: id) else {
      refreshBoundConnectors()
      scheduleSave()
      return
    }
    cards[targetIndex].kind = .graph
    cards[targetIndex].graph = spec
    cards[targetIndex].points = nil
    cards[targetIndex].startBindingID = nil
    cards[targetIndex].endBindingID = nil
    cards[targetIndex].startBindingAnchor = nil
    cards[targetIndex].endBindingAnchor = nil
    cards[targetIndex].frame = targetFrame
    if editingCardID == id { editingCardID = nil }
    refreshBoundConnectors()
    scheduleSave()
  }

  /// Esc-cancel on an equation card: keep its committed LaTeX as-is, but if it never held any (a
  /// freshly placed card the user backed out of), delete it — a blank equation shows nothing and,
  /// unlike blank text, isn't a useful write-spot. Called after the draft is discarded in the view.
  func pruneBlankEquation(_ id: UUID) {
    guard let i = index(for: id), cards[i].elementKind == .equation else { return }
    let committed = (cards[i].latex ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    if committed.isEmpty { delete(id, createStarterIfEmpty: false) }
  }

  // MARK: Promotions (the "promotion seam" — rough matter promoted into richer matter)

  /// Promote a recognized freehand stroke into the clean shape/line/arrow it was read as, keeping
  /// the card's id, tint, and z (continuity of matter) in a single undo step. Box shapes take the
  /// recognition's rect; lines/arrows mirror `addDrawnElement`'s two-point geometry exactly so a
  /// promoted line is indistinguishable from a drawn one. No-op unless the card is still a freehand.
  func convertFreehand(_ id: UUID, to kind: ShapeRecognizer.Kind) {
    guard let i = index(for: id), cards[i].elementKind == .freehand else { return }
    registerUndo()

    switch kind {
    case .rectangle(let rect), .ellipse(let rect), .diamond(let rect):
      cards[i].kind = shapeKind(for: kind)
      cards[i].frame = rect
      cards[i].points = nil
    case .line(let start, let end), .arrow(let start, let end):
      // Mirror `addDrawnElement`: a padded bounding box respecting `lineMinSize`, endpoints stored
      // normalized into that frame, so the promoted line reads exactly like a drawn one.
      let minSize = CardState.lineMinSize
      var minX = min(start.x, end.x), minY = min(start.y, end.y)
      var maxX = max(start.x, end.x), maxY = max(start.y, end.y)
      if maxX - minX < minSize.width { let pad = (minSize.width - (maxX - minX)) / 2; minX -= pad; maxX += pad }
      if maxY - minY < minSize.height { let pad = (minSize.height - (maxY - minY)) / 2; minY -= pad; maxY += pad }
      let frame = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
      cards[i].kind = (kind.isArrow ? .arrow : .line)
      cards[i].frame = frame
      cards[i].points = [
        CanvasPoint(x: Double((start.x - frame.minX) / frame.width), y: Double((start.y - frame.minY) / frame.height)),
        CanvasPoint(x: Double((end.x - frame.minX) / frame.width), y: Double((end.y - frame.minY) / frame.height)),
      ]
    }
    cards[i].whoWrote = nextAuthor
    // Rebuild the interaction from the rewritten card so the label/selection chrome reads the new kind.
    interactions[cards[i].id] = CardInteraction(cards[i])
    if ConnectorGeometry.isConnector(cards[i]) { bindConnectorIfPossible(id) }
    select(id)
    invalidateBoardTextContext()
    scheduleSave()
  }

  private func shapeKind(for kind: ShapeRecognizer.Kind) -> CanvasElementKind {
    switch kind {
    case .rectangle: .rectangle
    case .ellipse: .ellipse
    case .diamond: .diamond
    case .line: .line
    case .arrow: .arrow
    }
  }

  /// Promote a math-like text card into an equation card in one undo step, keeping id/frame/tint.
  /// The LaTeX is the text stripped of surrounding `$`/`$$` (mirroring how equation cards store raw
  /// math-mode source without delimiters), and the card's `text` is cleared the way an equation card
  /// carries none. No-op unless the card is still text.
  func convertTextToEquation(_ id: UUID) {
    guard let i = index(for: id), cards[i].elementKind == .text else { return }
    let latex = Self.strippedEquationLatex(plainText(for: cards[i]))
    registerUndo()
    cards[i].kind = .equation
    cards[i].latex = latex
    cards[i].text = ""
    cards[i].ink = nil
    cards[i].whoWrote = nextAuthor
    interactions[cards[i].id] = CardInteraction(cards[i])
    select(id)
    invalidateBoardTextContext()
    scheduleSave()
  }

  /// Promote a bullet-list text card into one text card per non-empty line, stacked from the
  /// original's origin: same width, auto-fit text height, 12pt board-unit gaps, all inheriting the
  /// original's tint. The original is deleted in the SAME undo step (its delete is suppressed, the
  /// way `convertElementToGraph` absorbs its partner). Non-bullet lines (e.g. a heading) become
  /// cards too, in order. Selects the new cards. No-op unless the card is still text.
  func splitTextCard(_ id: UUID) {
    guard let i = index(for: id), cards[i].elementKind == .text else { return }
    let lines = plainText(for: cards[i])
      .components(separatedBy: .newlines)
      .map { Self.strippedBulletMarker($0) }
      .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    guard lines.count > 1 else { return }

    let origin = CGPoint(x: cards[i].x, y: cards[i].y)
    let width = cards[i].w
    let tint = cards[i].tint
    let gap: CGFloat = 12

    registerUndo()
    // Append the new cards FIRST, then remove the original directly (not through `delete`, whose
    // empty-board guard would resurrect a blank first card if this split card were the board's only
    // one). One `registerUndo` above covers both, so a single undo restores the original card.
    var newIDs: [UUID] = []
    var y = origin.y
    for line in lines {
      let height = Self.fittedTextHeight(line, width: width)
      let card = CardState(text: line, x: Double(origin.x), y: Double(y),
                           w: Double(width), h: Double(height), z: nextZ,
                           whoWrote: nextAuthor, tint: tint)
      nextZ += 1
      cards.append(card)
      interactions[card.id] = CardInteraction(card)
      newIDs.append(card.id)
      y += height + gap
    }
    cards.removeAll { $0.id == id }
    interactions[id] = nil
    liveTextFrames[id] = nil
    selectedCardIDs = Set(newIDs)
    primarySelectedCardID = newIDs.last
    editingCardID = nil
    invalidateBoardTextContext()
    refreshBoundConnectors()
    scheduleSave()
  }

  // MARK: Promotion detection (pure, testable — precision first, false offers are worse than none)

  /// A text card is promotable to an equation only when its trimmed text is non-empty, single-line,
  /// and reads as math: either wrapped in `$…$`/`$$…$$` delimiters, or carrying a LaTeX command
  /// (`\command`). Precision-biased so prose never offers to become an equation.
  static func isMathLike(_ text: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !trimmed.contains(where: { $0.isNewline }) else { return false }
    if (trimmed.hasPrefix("$$") && trimmed.hasSuffix("$$") && trimmed.count > 4)
      || (trimmed.hasPrefix("$") && trimmed.hasSuffix("$") && trimmed.count > 2) {
      return true
    }
    return trimmed.range(of: "\\\\[a-zA-Z]+", options: .regularExpression) != nil
  }

  /// A text card is promotable to a split only when its text has ≥3 lines and ≥3 non-empty lines
  /// begin with a bullet marker (`- `, `* `, or `• `). A single stray dash never triggers a split.
  static func isBulletList(_ text: String) -> Bool {
    let lines = text.components(separatedBy: .newlines)
    guard lines.count >= 3 else { return false }
    let bulleted = lines.filter { line in
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      return !trimmed.isEmpty && (trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("• "))
    }
    return bulleted.count >= 3
  }

  /// Strip surrounding `$$…$$` or `$…$` delimiters and trim — the raw math-mode source an equation
  /// card stores (`latex`, no delimiters).
  static func strippedEquationLatex(_ text: String) -> String {
    var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if body.hasPrefix("$$"), body.hasSuffix("$$"), body.count > 4 {
      body = String(body.dropFirst(2).dropLast(2))
    } else if body.hasPrefix("$"), body.hasSuffix("$"), body.count > 2 {
      body = String(body.dropFirst().dropLast())
    }
    return body.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Strip a leading bullet marker (`- `, `* `, `• `) from a line, leaving the content; a line with
  /// no marker (a heading) is returned trimmed of trailing space but otherwise intact.
  static func strippedBulletMarker(_ line: String) -> String {
    let trimmedLeading = String(line.drop(while: { $0 == " " || $0 == "\t" }))
    for marker in ["- ", "* ", "• "] where trimmedLeading.hasPrefix(marker) {
      return String(trimmedLeading.dropFirst(marker.count))
    }
    return line.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
  }

  /// Height a text card needs to show `text` at `width`, measured the way the non-editing card
  /// renders it. Used for agent/programmatic edits and on load, where no live editor reports it.
  /// `fontScale` scales the measuring font (and line spacing) so a corner-scaled card (issue #77)
  /// measures at its own size; the default 1 keeps every legacy caller pixel-identical.
  static func fittedTextHeight(_ text: String, width: CGFloat, fontScale: CGFloat = 1) -> CGFloat {
    let scale = max(fontScale, 0.01)
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineSpacing = Theme.Typography.bodyLineSpacing * scale
    let font = ComposerPreferences.appFont(ofSize: Theme.Typography.body.pointSize * scale)
    let attributes: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: paragraph]
    let contentWidth = max(width - 32, 40)   // CanvasElementContent uses 16pt horizontal padding
    let measured = ((text.isEmpty ? " " : text) as NSString).boundingRect(
      with: NSSize(width: contentWidth, height: .greatestFiniteMagnitude),
      options: [.usesLineFragmentOrigin, .usesFontLeading],
      attributes: attributes).height
    return max(ceil(measured) + 36, CardState.textMinSize.height)   // 18pt vertical padding each side
  }

  /// The frame a text card needs to HUG `text` (issue #76): width follows the longest line up to a
  /// wrap cap (`textDefaultSize.width × fontScale` of content), then text wraps and height grows.
  /// Measured with the same font/paragraph attributes as the non-editing render, scaled by
  /// `fontScale`, using the same 16pt horizontal / 18pt vertical content padding as `fittedTextHeight`.
  /// Floors to `textMinSize` (120×40).
  static func fittedTextSize(_ text: String, fontScale: CGFloat) -> CGSize {
    let scale = max(fontScale, 0.01)
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineSpacing = Theme.Typography.bodyLineSpacing * scale
    let font = ComposerPreferences.appFont(ofSize: Theme.Typography.body.pointSize * scale)
    let attributes: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: paragraph]
    let string = (text.isEmpty ? " " : text) as NSString
    // Widest (unwrapped) line first — the card hugs it until it reaches the cap, then wraps.
    let natural = ceil(string.boundingRect(
      with: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
      options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes).width)
    let cap = CardState.textDefaultSize.width * scale   // 360 × scale of CONTENT width
    let width = min(natural, cap) + 32
    let height = fittedTextHeight(text, width: width, fontScale: scale)
    return CGSize(width: max(width, CardState.textMinSize.width), height: height)
  }

  /// Draw a line/arrow bound between two existing cards. An optional `reason` rides the connector
  /// as its label — the "why" behind the link. Arrow remains the default for existing callers.
  @discardableResult
  func connectCards(from: UUID,
                    to: UUID,
                    kind: CanvasElementKind = .arrow,
                    reason: String = "") -> UUID? {
    guard let source = cards.first(where: { $0.id == from }),
          let target = cards.first(where: { $0.id == to }),
          let card = ConnectorGeometry.makeBoundConnector(
            kind: kind,
            text: reason,
            source: source,
            target: target,
            z: nextZ,
            author: nextAuthor)
    else { return nil }
    registerUndo()
    nextZ += 1
    cards.append(card)
    interactions[card.id] = CardInteraction(card)
    selectedCardIDs = [card.id]
    primarySelectedCardID = card.id
    invalidateBoardTextContext()
    scheduleSave()
    return card.id
  }

  struct QuickConnectResult: Equatable {
    let connectorID: UUID
    let targetID: UUID
    let createdPeer: Bool
  }

  /// Complete a directional quick-connect as one model transaction. With no target, this creates a
  /// blank peer of the source's box kind at a deterministic gap; with a target, it only creates the
  /// connector. Selection advances to the target so repeated clicks can grow a diagram fluidly.
  @discardableResult
  func quickConnect(from sourceID: UUID,
                    direction: ConnectorDirection,
                    kind: CanvasElementKind = .arrow,
                    to existingTargetID: UUID? = nil) -> QuickConnectResult? {
    guard kind == .arrow || kind == .line,
          let source = cards.first(where: { $0.id == sourceID }),
          !source.locked,
          [.rectangle, .ellipse, .diamond].contains(source.elementKind)
    else { return nil }

    let target: CardState
    let createdPeer: Bool
    if let existingTargetID {
      guard let existing = cards.first(where: { $0.id == existingTargetID }),
            ConnectorGeometry.isEligibleTarget(existing, excluding: [sourceID])
      else { return nil }
      target = existing
      createdPeer = false
    } else {
      let frame = ConnectorGeometry.peerFrame(
        from: source.frame,
        peerSize: source.frame.size,
        direction: direction)
      target = CardState(
        kind: source.elementKind,
        text: "",
        x: frame.minX,
        y: frame.minY,
        w: frame.width,
        h: frame.height,
        z: nextZ,
        whoWrote: nextAuthor,
        tint: source.tint)
      createdPeer = true
    }

    let connectorZ = nextZ + (createdPeer ? 1 : 0)
    guard let connector = ConnectorGeometry.makeBoundConnector(
      kind: kind,
      text: "",
      source: source,
      target: target,
      z: connectorZ,
      author: nextAuthor,
      tint: source.tint)
    else { return nil }

    registerUndo()
    if createdPeer {
      cards.append(target)
      interactions[target.id] = CardInteraction(target)
      nextZ += 1
    }
    cards.append(connector)
    interactions[connector.id] = CardInteraction(connector)
    nextZ += 1
    selectedCardIDs = [target.id]
    primarySelectedCardID = target.id
    invalidateBoardTextContext()
    scheduleSave()
    return QuickConnectResult(
      connectorID: connector.id,
      targetID: target.id,
      createdPeer: createdPeer)
  }

  /// Mark a card superseded (faded) or active again.
  func setArchived(_ id: UUID, _ value: Bool) {
    guard let i = cards.firstIndex(where: { $0.id == id }), cards[i].isArchived != value else { return }
    registerUndo()
    cards[i].archived = value ? true : nil
    scheduleSave()
  }

  /// Provenance: archive `oldID`, drop a new card below it, and link old → new with the reason —
  /// so an idea's evolution (and the "why") stays visible on the board instead of being lost.
  @discardableResult
  func supersede(oldID: UUID, newText: String, reason: String) -> UUID? {
    guard let old = cards.first(where: { $0.id == oldID }) else { return nil }
    registerUndo()
    suppressUndo = true
    defer { suppressUndo = false; refreshBoundConnectors(); scheduleSave() }
    setArchived(oldID, true)
    let newID = insertText(newText, at: CGPoint(x: old.x, y: old.y + old.h + 64))
    _ = connectCards(from: oldID, to: newID, reason: reason)
    return newID
  }

  // MARK: Structured layout (agent draws by declaring structure, not coordinates)

  /// One declared diagram node: a stable `key` the caller invents (referenced by edges), its label
  /// text, and the box shape to draw it as (rectangle by default — a labeled box arrows can land on).
  struct DiagramNodeSpec { let key: String; let text: String; var shape: CanvasElementKind = .rectangle }
  /// A declared directed link by node key, optionally labeled with the "why".
  struct DiagramEdgeSpec { let from: String; let to: String; let reason: String }

  /// Build a whole diagram from a declaration of nodes + edges in ONE undo step: the agent says
  /// *what connects to what*, and `BoardLayout` computes clean, non-overlapping board positions —
  /// the spatial work an LLM can't do reliably by hand. Returns the caller's keys → created ids.
  @discardableResult
  func createDiagram(nodes specs: [DiagramNodeSpec], edges edgeSpecs: [DiagramEdgeSpec],
                     direction: LayoutDirection) -> [String: UUID] {
    guard !specs.isEmpty else { return [:] }
    registerUndo()
    suppressUndo = true
    beginBoardTextContextBatch()
    defer {
      suppressUndo = false
      endBoardTextContextBatch()
      refreshBoundConnectors()
      scheduleSave()
    }

    // Where the diagram starts: a fresh, empty board gets a clean margin (and we drop the lone
    // blank starter card); otherwise it drops below whatever's already there.
    let origin = diagramOrigin()
    if cards.count == 1, cards[0].elementKind == .text, cards[0].isBlank {
      interactions[cards[0].id] = nil
      cards.removeAll()
    }

    // 1. Create the node cards as labeled boxes (positions filled in once the layout is computed).
    //    A box gives every arrow a real boundary to terminate on, so connections read cleanly
    //    instead of stabbing through floating text.
    var keyToID: [String: UUID] = [:]
    var layoutNodes: [BoardLayout.Node] = []
    for spec in specs where keyToID[spec.key] == nil {
      let size = Self.fittedShapeSize(spec.text, shape: spec.shape)
      let card = CardState(kind: spec.shape, text: spec.text, x: origin.x, y: origin.y,
                           w: Double(size.width), h: Double(size.height), z: nextZ, whoWrote: nextAuthor)
      nextZ += 1
      cards.append(card)
      interactions[card.id] = CardInteraction(card)
      keyToID[spec.key] = card.id
      layoutNodes.append(BoardLayout.Node(id: card.id, size: size))
    }

    // 2. Lay out and apply positions before wiring edges, so bound arrows snap to final centers.
    var config = BoardLayout.Config()
    config.direction = direction
    config.origin = origin
    let edgesForLayout = edgeSpecs.compactMap { spec -> BoardLayout.Edge? in
      guard let from = keyToID[spec.from], let to = keyToID[spec.to], from != to else { return nil }
      return BoardLayout.Edge(from: from, to: to)
    }
    let positions = BoardLayout.layout(nodes: layoutNodes, edges: edgesForLayout, config: config)
    for (id, point) in positions {
      guard let i = cards.firstIndex(where: { $0.id == id }) else { continue }
      cards[i].x = Double(point.x)
      cards[i].y = Double(point.y)
    }

    // 3. Wire the labeled arrows.
    for spec in edgeSpecs {
      guard let from = keyToID[spec.from], let to = keyToID[spec.to], from != to else { continue }
      _ = connectCards(from: from, to: to, reason: spec.reason)
    }

    // 4. Select the new diagram so a Fit frames exactly it.
    selectedCardIDs = Set(keyToID.values)
    primarySelectedCardID = keyToID.values.first
    editingCardID = nil
    invalidateBoardTextContext()
    return keyToID
  }

  /// Re-flow everything on the board into a clean layered layout, anchored near where it already
  /// sits. Bound arrows/lines become the edges; freehand strokes are left untouched.
  func relayout(direction: LayoutDirection = .down) {
    let nodeCards = cards.filter { Self.isLayoutNode($0) }
    guard nodeCards.count > 1 else { return }
    let nodeIDs = Set(nodeCards.map(\.id))
    let edges: [BoardLayout.Edge] = cards.compactMap { card in
      guard card.elementKind == .arrow || card.elementKind == .line,
            let from = card.startBindingID, let to = card.endBindingID,
            nodeIDs.contains(from), nodeIDs.contains(to), from != to
      else { return nil }
      return BoardLayout.Edge(from: from, to: to)
    }

    registerUndo()
    suppressUndo = true
    defer { suppressUndo = false; refreshBoundConnectors(); scheduleSave() }

    var config = BoardLayout.Config()
    config.direction = direction
    config.origin = CGPoint(x: nodeCards.map(\.x).min() ?? 120, y: nodeCards.map(\.y).min() ?? 120)
    let layoutNodes = nodeCards.map { BoardLayout.Node(id: $0.id, size: CGSize(width: $0.w, height: $0.h)) }
    let positions = BoardLayout.layout(nodes: layoutNodes, edges: edges, config: config)
    for (id, point) in positions {
      guard let i = cards.firstIndex(where: { $0.id == id }) else { continue }
      cards[i].x = Double(point.x)
      cards[i].y = Double(point.y)
    }
  }

  /// Human "Tidy selection": re-flow ONLY the selected cards through the same `BoardLayout`
  /// machinery as `relayout`, using the selected subset as nodes and the arrows/lines among them as
  /// edges. The laid-out result is then translated so the subset's new bounding-box center matches
  /// its old one — tidying a corner of the board never teleports it. One undo step; the selection
  /// stays selected. No-ops with fewer than two layout nodes selected.
  func relayoutSelection(direction: LayoutDirection = .down) {
    let selectedNodes = cards.filter { selectedCardIDs.contains($0.id) && Self.isLayoutNode($0) }
    guard selectedNodes.count > 1 else { return }
    let nodeIDs = Set(selectedNodes.map(\.id))
    // Edges are the bound arrows/lines whose BOTH endpoints are in the selected subset — the same
    // rule relayout uses, narrowed to the subset so an edge to an off-board node never pulls layout.
    let edges: [BoardLayout.Edge] = cards.compactMap { card in
      guard card.elementKind == .arrow || card.elementKind == .line,
            let from = card.startBindingID, let to = card.endBindingID,
            nodeIDs.contains(from), nodeIDs.contains(to), from != to
      else { return nil }
      return BoardLayout.Edge(from: from, to: to)
    }

    let oldCenter = Self.centerOfRects(selectedNodes.map(\.frame))

    registerUndo()
    suppressUndo = true
    defer { suppressUndo = false; refreshBoundConnectors(); scheduleSave() }

    var config = BoardLayout.Config()
    config.direction = direction
    config.origin = CGPoint(x: selectedNodes.map(\.x).min() ?? 120, y: selectedNodes.map(\.y).min() ?? 120)
    let layoutNodes = selectedNodes.map { BoardLayout.Node(id: $0.id, size: CGSize(width: $0.w, height: $0.h)) }
    let positions = BoardLayout.layout(nodes: layoutNodes, edges: edges, config: config)

    // Recentre: BoardLayout places from `origin`, so the laid-out subset can drift. Shift it back so
    // its new bounding box shares the old center — the corner tidies in place.
    let laidRects = positions.compactMap { id, point -> CGRect? in
      guard let card = cards.first(where: { $0.id == id }) else { return nil }
      return CGRect(x: point.x, y: point.y, width: card.w, height: card.h)
    }
    let newCenter = Self.centerOfRects(laidRects)
    let shift = CGSize(width: oldCenter.x - newCenter.x, height: oldCenter.y - newCenter.y)

    for (id, point) in positions {
      guard let i = cards.firstIndex(where: { $0.id == id }) else { continue }
      cards[i].x = Double(point.x + shift.width)
      cards[i].y = Double(point.y + shift.height)
    }
  }

  /// Center of the union bounding box of `rects` (empty → origin).
  private static func centerOfRects(_ rects: [CGRect]) -> CGPoint {
    guard let union = unionRect(rects) else { return .zero }
    return CGPoint(x: union.midX, y: union.midY)
  }

  /// Insert a text card and let the board pick a non-overlapping spot — used when an agent adds a
  /// one-off card without (or not caring about) coordinates.
  @discardableResult
  func insertTextAutoPlaced(_ text: String) -> UUID {
    let size = Self.textInsertionSize(text)
    return insertText(text, at: autoPlacePoint(for: size))
  }

  /// Insert an equation and let the board pick a non-overlapping spot — used when an agent adds a
  /// one-off math card without coordinates.
  @discardableResult
  func insertEquationAutoPlaced(_ latex: String) -> UUID {
    insertEquation(latex, at: autoPlacePoint(for: CardState.equationSize))
  }

  /// Append captured text from the menu bar, Services menu, URL scheme, or loopback API.
  ///
  /// Prefer the card the user is editing or has selected. When there is no active card, the live
  /// canvas supplies its viewport center so capture still lands in the area the user is looking at.
  /// Callers without a viewport (the loopback bridge) retain the below-board fallback.
  @discardableResult
  func captureExternalText(_ text: String, around activeBoardPoint: CGPoint? = nil) -> UUID? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let size = Self.capturePlacementSize(trimmed)
    let activeID = editingCardID ?? primarySelectedCardID
    let activeFrame = activeID.flatMap { renderingFrame(for: $0) }
    let point: CGPoint
    if let activeFrame {
      point = autoPlacePoint(for: size, near: activeFrame)
    } else if let activeBoardPoint {
      point = autoPlacePoint(
        for: size,
        near: CGRect(origin: activeBoardPoint, size: .zero),
        includeAnchor: true)
    } else {
      point = autoPlacePoint(for: size)
    }
    let id = insertText(trimmed, at: point)
    beginEditing(id)
    return id
  }

  /// The frame `insertText` creates before its live editor reports a tighter content hug.
  private static func textInsertionSize(_ text: String) -> CGSize {
    let width = CardState.textDefaultSize.width
    return CGSize(width: width, height: fittedTextHeight(text, width: width))
  }

  /// Reserve enough room for both the inserted seed frame and the live editor's eventual hug.
  /// Long single lines can grow 32pt wider than `textDefaultSize` once content padding is applied;
  /// short captures begin at the seed width before their first layout callback shrinks them.
  static func capturePlacementSize(_ text: String) -> CGSize {
    let inserted = textInsertionSize(text)
    let fitted = fittedTextSize(text, fontScale: 1)
    return CGSize(width: max(inserted.width, fitted.width),
                  height: max(inserted.height, fitted.height))
  }

  /// Find the nearest clear grid slot around an active card or board point. Candidates expand in
  /// rings, preferring below/right/left/above so a stream of captures reads naturally while still
  /// escaping a busy cluster. The ordinary no-context auto-placement remains a separate fallback.
  func autoPlacePoint(for size: CGSize, near anchor: CGRect, includeAnchor: Bool = false) -> CGPoint {
    let gap: CGFloat = 36
    let anchorCenter = CGPoint(x: anchor.midX, y: anchor.midY)
    let stepX = max(size.width + gap, (anchor.width + size.width) / 2 + gap)
    let stepY = max(size.height + gap, (anchor.height + size.height) / 2 + gap)

    func point(dx: Int, dy: Int) -> CGPoint {
      CGPoint(
        x: anchorCenter.x + CGFloat(dx) * stepX - size.width / 2,
        y: anchorCenter.y + CGFloat(dy) * stepY - size.height / 2)
    }

    func isClear(_ origin: CGPoint) -> Bool {
      let candidate = CGRect(origin: origin, size: size).insetBy(dx: -gap / 2, dy: -gap / 2)
      return cards.allSatisfy { card in
        !(liveTextFrames[card.id] ?? card.frame).intersects(candidate)
      }
    }

    if includeAnchor {
      let origin = point(dx: 0, dy: 0)
      if isClear(origin) { return origin }
    }

    // A square ring of radius r has enough slots to escape ordinary dense clusters without a
    // board-wide vertical jump. The extra two rings account for large cards covering several slots.
    let maxRadius = max(4, Int(ceil(sqrt(Double(cards.count + 1)))) + 2)
    for radius in 1...maxRadius {
      let preferred = [(0, radius), (radius, 0), (-radius, 0), (0, -radius)]
      for offset in preferred {
        let origin = point(dx: offset.0, dy: offset.1)
        if isClear(origin) { return origin }
      }

      for dy in (-radius)...radius {
        for dx in (-radius)...radius where max(abs(dx), abs(dy)) == radius {
          guard !preferred.contains(where: { $0.0 == dx && $0.1 == dy }) else { continue }
          let origin = point(dx: dx, dy: dy)
          if isClear(origin) { return origin }
        }
      }
    }

    return autoPlacePoint(for: size)
  }

  /// A clear board point below existing content for an auto-placed element.
  func autoPlacePoint(for size: CGSize) -> CGPoint {
    guard !cards.isEmpty else { return CGPoint(x: 120, y: 120) }
    let maxY = cards.map { $0.y + $0.h }.max() ?? 80
    let minX = cards.map(\.x).min() ?? 120
    return CGPoint(x: minX, y: maxY + 48)
  }

  /// Origin for a freshly-built diagram: a clean margin on an empty board, otherwise below content.
  private func diagramOrigin() -> CGPoint {
    let meaningful = cards.filter { !($0.elementKind == .text && $0.isBlank) }
    guard !meaningful.isEmpty else { return CGPoint(x: 140, y: 120) }
    let maxY = meaningful.map { $0.y + $0.h }.max() ?? 80
    let minX = meaningful.map(\.x).min() ?? 140
    return CGPoint(x: minX, y: maxY + 72)
  }

  private static func isLayoutNode(_ card: CardState) -> Bool {
    switch card.elementKind {
    case .text, .rectangle, .ellipse, .diamond, .image, .equation, .graph, .sticky, .checklist, .table: return true
    case .line, .arrow, .freehand, .vectorPath: return false
    }
  }

  /// A comfortable card size for a diagram label: natural single-line width capped to a tidy
  /// column, with the height fitted to the wrapped text — so short labels read as small pills and
  /// long ones wrap instead of stretching the whole board.
  static func fittedTextSize(_ text: String, maxWidth: CGFloat = 232) -> CGSize {
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineSpacing = Theme.Typography.bodyLineSpacing
    let attributes: [NSAttributedString.Key: Any] = [.font: Theme.Typography.body, .paragraphStyle: paragraph]
    let natural = ((text.isEmpty ? " " : text) as NSString).size(withAttributes: attributes).width
    let contentWidth = min(max(natural, 64), maxWidth - 32)   // inside the 16pt horizontal padding
    let width = ceil(contentWidth) + 32
    return CGSize(width: width, height: fittedTextHeight(text, width: width))
  }

  /// The rectangular label block rendered by `NodeLabel`, including its content padding. Keeping
  /// this independently visible lets non-rectangular containers apply their real containment math.
  static func fittedShapeLabelBlockSize(
    _ text: String,
    maxWidth: CGFloat = ShapeLabelGeometry.defaultMaximumContainerWidth
  ) -> CGSize {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    let attributes: [NSAttributedString.Key: Any] = [.font: ComposerPreferences.appFont(ofSize: 14, weight: .semibold),
                                                      .paragraphStyle: paragraph]
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let ns = (trimmed.isEmpty ? " " : trimmed) as NSString
    let natural = ns.size(withAttributes: attributes).width
    let contentWidth = min(
      max(natural, 72),
      maxWidth - ShapeLabelGeometry.horizontalPadding * 2)
    let measured = ns.boundingRect(with: NSSize(width: contentWidth, height: .greatestFiniteMagnitude),
                                   options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes).height
    return ShapeLabelGeometry.paddedBlockSize(
      contentWidth: contentWidth, contentHeight: measured)
  }

  /// A box sized to hold a centered node label (the diagram-node font/padding), wrapping rather
  /// than truncating. Ellipses get their established optical inset; diamonds use their exact
  /// centered-rectangle containment constraint so tall multiline labels cannot cross an edge.
  static func fittedShapeSize(
    _ text: String,
    shape: CanvasElementKind = .rectangle,
    maxWidth: CGFloat = ShapeLabelGeometry.defaultMaximumContainerWidth
  ) -> CGSize {
    let block = fittedShapeLabelBlockSize(text, maxWidth: maxWidth)
    var width = block.width
    var height = block.height
    switch shape {
    case .ellipse: width = ceil(width * 1.24); height = ceil(height * 1.35)
    case .diamond:
      let container = ShapeLabelGeometry.diamondContainerSize(containing: block)
      width = container.width
      height = container.height
    default: break
    }
    return CGSize(
      width: max(width, CardState.shapeMinSize.width),
      height: max(height, CardState.shapeMinSize.height))
  }

  /// Commit a moved/resized card frame (board space).
  func setFrame(_ id: UUID, _ frame: CGRect) {
    guard let i = cards.firstIndex(where: { $0.id == id }) else { return }
    guard !cards[i].locked else { return }
    let minSize = cards[i].minimumSize
    let next = CGRect(
      x: frame.minX,
      y: frame.minY,
      width: max(frame.width, minSize.width),
      height: max(frame.height, minSize.height)
    )
    guard cards[i].frame != next else { return }
    registerUndo()
    if ConnectorGeometry.isConnector(cards[i]) {
      cards[i].startBindingID = nil
      cards[i].endBindingID = nil
      cards[i].startBindingAnchor = nil
      cards[i].endBindingAnchor = nil
    }
    cards[i].frame = next
    refreshBoundConnectors()
    scheduleSave()
  }

  /// Grow/shrink a text card to HUG what's typed (issue #76): recompute both width and height from
  /// its current text and font scale, top-left anchored (x,y unchanged — the card grows right and
  /// down). This is a layout consequence of editing (the keystroke already registered undo), so it
  /// never pushes its own undo step. Empty text keeps its current/seed frame (the placeholder needs
  /// room) rather than collapsing to the minimum.
  func fitTextSize(_ id: UUID) {
    guard let i = cards.firstIndex(where: { $0.id == id }), cards[i].elementKind == .text else { return }
    let text = plainText(for: cards[i])
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    let fitted = Self.fittedTextSize(text, fontScale: cards[i].textScale)
    guard abs(cards[i].w - Double(fitted.width)) > 0.5 || abs(cards[i].h - Double(fitted.height)) > 0.5 else { return }
    cards[i].w = Double(fitted.width)
    cards[i].h = Double(fitted.height)
    refreshBoundConnectors()
    scheduleSave()
  }

  /// Fit a rectangle/ellipse/diamond around its committed label with consistent content padding.
  /// The shape stays centered where the user placed it, and bound connectors are refreshed against
  /// the new boundary. Like text hugging, this is a consequence of the label edit that already owns
  /// the undo checkpoint, so fitting does not create a second undo step. An empty label preserves
  /// the user's current geometry instead of collapsing an intentional unlabelled shape.
  func fitShapeSize(_ id: UUID) {
    guard let i = cards.firstIndex(where: { $0.id == id }) else { return }
    let kind = cards[i].elementKind
    guard kind == .rectangle || kind == .ellipse || kind == .diamond else { return }
    let label = plainText(for: cards[i]).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !label.isEmpty else { return }
    let fitted = Self.fittedShapeSize(label, shape: kind)
    guard abs(cards[i].w - Double(fitted.width)) > 0.5 ||
            abs(cards[i].h - Double(fitted.height)) > 0.5 else { return }
    let center = Self.center(of: cards[i])
    cards[i].frame = CGRect(
      x: center.x - fitted.width / 2,
      y: center.y - fitted.height / 2,
      width: fitted.width,
      height: fitted.height)
    refreshBoundConnectors()
    scheduleSave()
  }

  /// Publish the editor's latest frame only at the edit boundary. Until then the frame lives in
  /// `liveTextFrames` and the editing card owns its local visual override, so layout callbacks do
  /// not replace the published `cards` array or rebuild every visible card.
  @discardableResult
  private func commitLiveTextFrame(_ id: UUID) -> Bool {
    guard let frame = liveTextFrames.removeValue(forKey: id),
          let i = cards.firstIndex(where: { $0.id == id }) else { return false }
    let committedFrame = CGRect(origin: cards[i].frame.origin, size: frame.size)
    guard cards[i].frame != committedFrame else { return true }
    cards[i].frame = committedFrame
    refreshBoundConnectors()
    scheduleSave()
    return true
  }

  /// Live-edit hug driven by the EDITOR's own layout (issue #76). While a card is being typed
  /// into, the mounted NSTextView is the only sizing authority: `fittedTextSize`'s NSString twin
  /// wraps ~10pt later than the view (different insets/fragment padding), and sizing from it left
  /// the frame a line short — the editor then scrolled to the caret and clipped the top line.
  /// Width follows the editor's unwrapped text (+ the card's 12pt mount padding each side, +2pt
  /// wrap slack) up to the same total cap the static hug uses; height is the editor's laid-out
  /// height + the mount's vertical padding. No undo step (a layout consequence of typing),
  /// top-left anchored, empty text keeps its seed frame.
  @discardableResult
  func fitTextEditing(_ id: UUID, naturalEditorWidth: CGFloat, editorContentHeight: CGFloat) -> CGRect? {
    // Only the ACTIVE edit session may write a live frame. The editor reports layout through
    // `DispatchQueue.main.async` (FreeWriteEditor.reportHeight), so a callback queued before the
    // edit ended can land after `commitLiveTextFrame` retired the override — accepting it would
    // resurrect stale geometry that the next save/export then persists.
    guard editingCardID == id,
          let i = cards.firstIndex(where: { $0.id == id }), cards[i].elementKind == .text else { return nil }
    guard !plainText(for: cards[i]).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    let cap = CardState.textDefaultSize.width * cards[i].textScale + 32
    let width = min(max(naturalEditorWidth + 24 + 2, CardState.textMinSize.width), cap)
    let height = max(editorContentHeight + 20, CardState.textMinSize.height)
    let frame = CGRect(x: cards[i].x, y: cards[i].y, width: width, height: height)
    let previous = liveTextFrames[id] ?? cards[i].frame
    guard abs(previous.width - width) > 0.5 || abs(previous.height - height) > 0.5 else { return previous }
    liveTextFrames[id] = frame
    scheduleSave()
    NotificationCenter.default.post(name: .composerTextCardLiveFrameChanged, object: id)
    return frame
  }

  /// Commit a corner-drag font scale on a text card (issue #77). One undo step restores BOTH the
  /// previous `fontScale` and frame, because aspect-locked scaling is the whole gesture's single
  /// intent — unlike the undo-free live typing fits above. `fontScale == 1` is stored as nil so a
  /// scaled-then-reset card round-trips as a legacy card.
  func scaleTextCard(_ id: UUID, fontScale: Double, frame: CGRect) {
    guard let i = cards.firstIndex(where: { $0.id == id }), cards[i].elementKind == .text, !cards[i].locked else { return }
    registerUndo()
    cards[i].fontScale = abs(fontScale - 1) < 0.0001 ? nil : fontScale
    let minSize = cards[i].minimumSize
    cards[i].frame = CGRect(x: frame.minX, y: frame.minY,
                            width: max(frame.width, minSize.width),
                            height: max(frame.height, minSize.height))
    refreshBoundConnectors()
    scheduleSave()
  }

  func bringToFront(_ id: UUID) {
    guard let i = cards.firstIndex(where: { $0.id == id }), cards[i].z != nextZ - 1 || nextZ == 1 else { return }
    registerUndo()
    cards[i].z = nextZ
    nextZ += 1
    scheduleSave()
  }

  func delete(_ id: UUID) {
    delete(id, createStarterIfEmpty: true)
  }

  private func delete(_ id: UUID, createStarterIfEmpty: Bool) {
    clearMovePreview()
    guard let i = index(for: id), !cards[i].locked else { return }
    registerUndo()
    cards.removeAll { $0.id == id }
    interactions[id] = nil
    liveTextFrames[id] = nil
    mountedCardIDs.remove(id)
    committedTextNotifications[id] = nil
    if editingCardID == id { editingCardID = nil }
    selectedCardIDs.remove(id)
    if primarySelectedCardID == id { primarySelectedCardID = selectedCardIDs.first }
    if cards.isEmpty, createStarterIfEmpty {
      let fresh = CardState.firstCard()
      cards = [fresh]
      interactions[fresh.id] = CardInteraction(fresh)
      selectedCardIDs = [fresh.id]
      primarySelectedCardID = fresh.id
    }
    refreshBoundConnectors()
    invalidateBoardTextContext()
    scheduleSave()
  }

  func selectAll() {
    selectedCardIDs = Set(cards.map(\.id))
    primarySelectedCardID = cards.max(by: { $0.z < $1.z })?.id
  }

  func select(in rect: CGRect, extending: Bool = false, toggling: Bool = false) {
    stopEditing()
    let hits = expandedGroups(Set(cards.filter { $0.frame.intersects(rect) }.map(\.id)))
    if toggling {
      selectedCardIDs.formSymmetricDifference(hits)
    } else if extending {
      selectedCardIDs.formUnion(hits)
    } else {
      selectedCardIDs = hits
    }
    primarySelectedCardID = cards
      .filter { selectedCardIDs.contains($0.id) }
      .max(by: { $0.z < $1.z })?
      .id
  }

  func deleteSelection() {
    clearMovePreview()
    guard !selectedCardIDs.isEmpty else { return }
    let deleting = unlockedIDs(in: selectedCardIDs)
    guard !deleting.isEmpty else { return }
    registerUndo()
    cards.removeAll { deleting.contains($0.id) }
    for id in deleting {
      interactions[id] = nil
      liveTextFrames[id] = nil
      mountedCardIDs.remove(id)
      committedTextNotifications[id] = nil
    }
    if let editingCardID, deleting.contains(editingCardID) { self.editingCardID = nil }
    selectedCardIDs = []
    primarySelectedCardID = nil
    if cards.isEmpty {
      let fresh = CardState.firstCard()
      cards = [fresh]
      interactions[fresh.id] = CardInteraction(fresh)
      selectedCardIDs = [fresh.id]
      primarySelectedCardID = fresh.id
    }
    refreshBoundConnectors()
    invalidateBoardTextContext()
    scheduleSave()
  }

  func selectedCardsForClipboard() -> [CardState] {
    // Through `renderingSnapshot` so a card copied mid-edit carries its live auto-fit frame, not
    // the last committed one — what you see when you hit ⌘C is what pastes.
    let selected = renderingSnapshot(for: cards.filter { selectedCardIDs.contains($0.id) })
    return selected.map { card in
      var copy = card
      copy.text = persistedText(for: card)
      return copy
    }
  }

  func duplicateSelection(offset: CGSize = CGSize(width: 28, height: 28)) {
    _ = insertCopies(selectedCardsForClipboard(), offset: offset)
  }

  @discardableResult
  func insertCopies(_ source: [CardState], offset: CGSize = CGSize(width: 28, height: 28)) -> [UUID] {
    guard !source.isEmpty else { return [] }
    registerUndo()
    var ids: [UUID] = []
    let ordered = source.sorted { a, b in
      if a.z != b.z { return a.z < b.z }
      if a.y != b.y { return a.y < b.y }
      return a.x < b.x
    }
    // Build the whole plan before materializing any card so connectors can remap bindings regardless
    // of z-order. Keep a distinct new id per occurrence (bulk callers may repeat a seed card), while
    // bindings resolve to the first copied occurrence of their target's old id. References to targets
    // outside `source` are deliberately detached: this same seam serves cross-board paste, where
    // retaining an old UUID could silently bind to unrelated data.
    let copyPlan = ordered.map { (original: $0, copiedID: UUID()) }
    var firstCopiedID: [UUID: UUID] = [:]
    for item in copyPlan where firstCopiedID[item.original.id] == nil {
      firstCopiedID[item.original.id] = item.copiedID
    }
    for item in copyPlan {
      let original = item.original
      var copy = original
      copy.id = item.copiedID
      copy.x += Double(offset.width)
      copy.y += Double(offset.height)
      copy.z = nextZ
      copy.whoWrote = nextAuthor
      if let target = original.startBindingID, let copiedTarget = firstCopiedID[target] {
        copy.startBindingID = copiedTarget
        // The normalized anchor remains valid because every copied target preserves its size.
      } else {
        copy.startBindingID = nil
        copy.startBindingAnchor = nil
      }
      if let target = original.endBindingID, let copiedTarget = firstCopiedID[target] {
        copy.endBindingID = copiedTarget
      } else {
        copy.endBindingID = nil
        copy.endBindingAnchor = nil
      }
      if copy.elementKind == .image, let path = copy.imagePath {
        copy.imagePath = Self.storedImagePath(for: path)
      }
      nextZ += 1
      cards.append(copy)
      interactions[copy.id] = CardInteraction(copy)
      ids.append(copy.id)
    }
    refreshBoundConnectors()
    selectedCardIDs = Set(ids)
    primarySelectedCardID = ids.last
    editingCardID = nil
    invalidateBoardTextContext()
    scheduleSave()
    return ids
  }

  func moveSelected(by delta: CGSize) {
    guard !selectedCardIDs.isEmpty, delta != .zero else { return }
    let moving = unlockedIDs(in: selectedCardIDs)
    guard !moving.isEmpty else { return }
    registerUndo()
    for i in cards.indices where moving.contains(cards[i].id) {
      cards[i].x += Double(delta.width)
      cards[i].y += Double(delta.height)
    }
    detachBindingsWhoseTargetsDidNotMove(with: moving)
    refreshBoundConnectors()
    scheduleSave()
  }

  /// The single source of truth for move snapping: snaps `proposed` (board-space delta) so the
  /// union bounding rect of `movingIDs` aligns to nearby peers, publishes the resulting guide lines,
  /// and returns the adjusted delta. Both move paths call this so preview and commit share the exact
  /// same rule (the bind-preview house rule) and both publish the same guides. `tolerance` is in
  /// board space (callers pass `8 / zoom` for the 8pt screen-space threshold). Peers are every
  /// non-moving, non-archived card frame. Returns `proposed` unchanged (and clears guides) when the
  /// moving set is empty or nothing lands within tolerance.
  func snappedDelta(for movingIDs: Set<UUID>, proposed: CGSize, tolerance: CGFloat) -> CGSize {
    guard !movingIDs.isEmpty else {
      if !snapGuides.isEmpty { snapGuides = [] }
      return proposed
    }
    let movingFrames = cards.filter { movingIDs.contains($0.id) }.map(\.frame)
    guard let union = Self.unionRect(movingFrames) else {
      if !snapGuides.isEmpty { snapGuides = [] }
      return proposed
    }
    let peers = cards
      .filter { !movingIDs.contains($0.id) && !$0.isArchived }
      .map(\.frame)
    let result = SnapEngine.snap(moving: union, proposedDelta: proposed, others: peers, tolerance: tolerance)
    if snapGuides != result.guides { snapGuides = result.guides }
    return result.delta
  }

  /// The tight bounding box of `frames`, or nil when empty. Used to snap a multi-card move as one
  /// rigid unit (a single card is its own frame).
  private static func unionRect(_ frames: [CGRect]) -> CGRect? {
    guard var union = frames.first else { return nil }
    for frame in frames.dropFirst() { union = union.union(frame) }
    return union
  }

  func updateMovePreview(by delta: CGSize) {
    updateMovePreview(by: delta, tolerance: 0)
  }

  /// Move preview with alignment snapping. `tolerance` is the board-space snap threshold (the view
  /// passes `8 / zoom`); `0` disables snapping for callers that don't thread a zoom.
  func updateMovePreview(by rawDelta: CGSize, tolerance: CGFloat) {
    let moving = unlockedIDs(in: selectedCardIDs)
    // A multi-selection can contain locked cards. Preview the unlocked subset even when it has
    // only one member, because BoardCardView still commits through finishMovePreview for the
    // original multi-selection.
    guard !moving.isEmpty else { return }
    if movePreviewIDs != moving {
      clearMovePreview()
      movePreviewIDs = moving
    }
    let delta = snappedDelta(for: moving, proposed: rawDelta, tolerance: tolerance)
    movePreviewDelta = delta
    for id in moving {
      interactions[id]?.dragDelta = delta
    }
    // finishMovePreview absorbs a lone unlocked equation into the graph under it, so the drop ring
    // must track this path too (it used to light up only for single-card drags — an absorb the
    // affordance never promised). ⌥-drag duplicates also flow through here.
    if moving.count == 1, let movedID = moving.first, let moved = card(id: movedID) {
      updateEquationDropTarget(movedID: movedID, center: CGPoint(
        x: moved.frame.midX + delta.width, y: moved.frame.midY + delta.height))
    }
  }

  /// ⌥-drag duplicate, called once when an option-drag leaves the click dead-zone: snapshot the
  /// board, leave the pressed selection in place (ids and arrow bindings intact), and insert bare
  /// in-place copies that become the selection — the rest of the drag moves the copies through the
  /// regular move preview. The paired finishMovePreview folds into this checkpoint, so one undo
  /// removes the copies and the gesture entirely.
  func beginDragDuplicate() {
    let source = selectedCardsForClipboard()
    guard !source.isEmpty else { return }
    registerUndo()
    let previousSuppressUndo = suppressUndo
    suppressUndo = true
    _ = insertCopies(source, offset: .zero)
    suppressUndo = previousSuppressUndo
    foldNextMoveUndo = true
  }

  func finishMovePreview(commit: Bool) {
    let ids = movePreviewIDs
    let delta = movePreviewDelta
    let folded = foldNextMoveUndo
    foldNextMoveUndo = false
    clearMovePreview()
    clearEquationDropTarget()
    guard commit, !ids.isEmpty, delta != .zero else { return }
    if !folded { registerUndo() }
    for i in cards.indices where ids.contains(cards[i].id) {
      cards[i].x += Double(delta.width)
      cards[i].y += Double(delta.height)
    }
    absorbMovedEquationIntoTopmostGraphIfNeeded(ids)
    detachBindingsWhoseTargetsDidNotMove(with: ids)
    refreshBoundConnectors()
    scheduleSave()
  }

  /// Single-card drags commit through `setFrame`, not `finishMovePreview` — this gives that path
  /// the same equation→graph drop. The absorb runs suppressed, so the caller's move snapshot owns
  /// the whole gesture (one undo restores the equation card at its pre-drag position).
  func absorbEquationDropIfNeeded(_ id: UUID) {
    absorbMovedEquationIntoTopmostGraphIfNeeded([id])
  }

  private func absorbMovedEquationIntoTopmostGraphIfNeeded(_ ids: Set<UUID>) {
    guard ids.count == 1,
          let movedID = ids.first,
          let moved = card(id: movedID),
          moved.elementKind == .equation else { return }
    let center = CGPoint(x: moved.frame.midX, y: moved.frame.midY)
    guard let graphID = cards
      .filter({ $0.id != movedID && $0.elementKind == .graph && $0.frame.contains(center) })
      .max(by: { $0.z < $1.z })?
      .id else { return }

    let previousSuppressUndo = suppressUndo
    suppressUndo = true
    _ = absorbEquationIntoGraph(movedID, into: graphID)
    suppressUndo = previousSuppressUndo
  }

  func groupSelection() {
    let grouping = selectedCardIDs
    guard grouping.count > 1 else { return }
    registerUndo()
    let groupID = UUID()
    for i in cards.indices where grouping.contains(cards[i].id) {
      cards[i].groupID = groupID
    }
    scheduleSave()
  }

  func ungroupSelection() {
    guard !selectedCardIDs.isEmpty else { return }
    let selectedGroups = Set(cards.compactMap { selectedCardIDs.contains($0.id) ? $0.groupID : nil })
    guard !selectedGroups.isEmpty else { return }
    registerUndo()
    for i in cards.indices where cards[i].groupID.map({ selectedGroups.contains($0) }) ?? false {
      cards[i].groupID = nil
    }
    scheduleSave()
  }

  /// The tint newly drawn elements take (nil = default ink). Set from the bottom bar's tint
  /// control; also mirrored there as the current swatch.
  @Published var currentTint: Int?

  /// Tint every selected element (shapes, lines, arrows, freehand, and text ink) with the slot
  /// index — nil restores the default ink. Image cards are untouched.
  func setTintForSelection(_ tint: Int?) {
    let tintable = cards.contains {
      selectedCardIDs.contains($0.id) && $0.elementKind != .image && $0.tint != tint
    }
    guard tintable else { return }
    registerUndo()
    for i in cards.indices where selectedCardIDs.contains(cards[i].id) && cards[i].elementKind != .image {
      cards[i].tint = tint
    }
    scheduleSave()
  }

  /// Tint one card (the text-selection action bar's color control targets the editing card).
  func setTint(_ tint: Int?, for id: UUID) {
    guard let index = cards.firstIndex(where: { $0.id == id }), cards[index].tint != tint else { return }
    registerUndo()
    cards[index].tint = tint
    scheduleSave()
  }

  /// The selection bar inked a text range in the live editor (serialized text unchanged). Arm an
  /// undo baseline from the pre-ink cache, then refresh the cache so the new runs persist. Must run
  /// AFTER the editor storage was mutated but the interaction cache still holds the old runs.
  func noteInkChanged(cardID: UUID) {
    guard let interaction = interactions[cardID] else { return }
    // Re-applying the same color is a no-op — don't burn an undo step or a save on it.
    guard interaction.editorInk != interaction.ink else { return }
    // Baseline = the board as it was before this inking: the cache still holds the old runs at
    // `registerUndo` time, so the undo snapshot captures the pre-ink state. Then commit the new runs.
    registerUndo()
    interaction.refreshInkFromEditor()
    scheduleSave()
  }

  func lockSelection(_ locked: Bool) {
    guard !selectedCardIDs.isEmpty else { return }
    guard cards.contains(where: { selectedCardIDs.contains($0.id) && $0.locked != locked }) else { return }
    registerUndo()
    for i in cards.indices where selectedCardIDs.contains(cards[i].id) {
      cards[i].isLocked = locked ? true : nil
    }
    scheduleSave()
  }

  func cancelMovePreview() {
    clearMovePreview()
  }

  /// Retire the alignment hairlines. The single-card move path publishes guides directly (it doesn't
  /// go through `clearMovePreview`), so its commit/cancel branches call this to end the gesture.
  func clearSnapGuides() {
    if !snapGuides.isEmpty { snapGuides = [] }
  }

  private func clearMovePreview() {
    for id in movePreviewIDs {
      interactions[id]?.dragDelta = .zero
    }
    movePreviewIDs = []
    movePreviewDelta = .zero
    // Guides belong to a live drag only — every commit/cancel/clear routes through here, so this is
    // the one place that guarantees the hairlines vanish the instant the gesture ends.
    if !snapGuides.isEmpty { snapGuides = [] }
  }

  /// A connector translated independently of a bound target must detach from that target; otherwise
  /// refresh would snap it back. When the target moved in the same rigid selection, retain the
  /// binding so the translated diagram stays a live graph rather than becoming loose strokes.
  private func detachBindingsWhoseTargetsDidNotMove(with ids: Set<UUID>) {
    for i in cards.indices where ids.contains(cards[i].id) && ConnectorGeometry.isConnector(cards[i]) {
      if let target = cards[i].startBindingID, !ids.contains(target) {
        cards[i].startBindingID = nil
        cards[i].startBindingAnchor = nil
      }
      if let target = cards[i].endBindingID, !ids.contains(target) {
        cards[i].endBindingID = nil
        cards[i].endBindingAnchor = nil
      }
    }
  }

  private func bindConnectorIfPossible(_ id: UUID) {
    guard let index = index(for: id),
          let connector = ConnectorGeometry.finalizingDrawn(cards[index], among: cards)
    else { return }
    cards[index] = connector
  }

  private func refreshBoundConnectors() {
    let refreshed = ConnectorGeometry.refreshing(in: cards)
    // Publish only on a real geometry change, so a no-op refresh doesn't rebuild the card layer.
    if refreshed != cards { cards = refreshed }
  }

  /// Read-only connector-seam query for the live endpoint preview. Preview and commit share the
  /// exact same target policy, so what highlights before release is what actually binds.
  func bindCandidate(at boardPoint: CGPoint, excluding: Set<UUID>) -> UUID? {
    ConnectorGeometry.bindingTarget(at: boardPoint, among: cards, excluding: excluding)
  }

  /// Move one endpoint of a selected line/arrow in board space. The geometry module preserves the
  /// opposite endpoint, detaches/rebinds only the moved end, and rebases normalized points. The
  /// entire drag commits through this one mutation, so it is exactly one undo step.
  @discardableResult
  func setConnectorEndpoint(_ endpoint: ConnectorEndpoint, of id: UUID, to boardPoint: CGPoint) -> Bool {
    guard let index = index(for: id), !cards[index].locked,
          let updated = ConnectorGeometry.moving(endpoint, of: cards[index], to: boardPoint, among: cards),
          updated != cards[index]
    else { return false }
    registerUndo()
    cards[index] = updated
    scheduleSave()
    return true
  }

  private func lineSegment(for card: CardState) -> (endpoints: (start: CGPoint, end: CGPoint), vector: CGVector, length: CGFloat)? {
    guard let resolved = ConnectorGeometry.endpoints(of: card) else { return nil }
    let endpoints = (start: resolved.start, end: resolved.end)
    let vector = CGVector(dx: endpoints.end.x - endpoints.start.x, dy: endpoints.end.y - endpoints.start.y)
    let length = hypot(vector.dx, vector.dy)
    guard length > 0 else { return nil }
    return (endpoints, vector, length)
  }

  private static func closestEndpointDistance(_ lhs: (start: CGPoint, end: CGPoint),
                                              _ rhs: (start: CGPoint, end: CGPoint)) -> CGFloat {
    [
      hypot(lhs.start.x - rhs.start.x, lhs.start.y - rhs.start.y),
      hypot(lhs.start.x - rhs.end.x, lhs.start.y - rhs.end.y),
      hypot(lhs.end.x - rhs.start.x, lhs.end.y - rhs.start.y),
      hypot(lhs.end.x - rhs.end.x, lhs.end.y - rhs.end.y),
    ].min() ?? .greatestFiniteMagnitude
  }

  private func card(id: UUID) -> CardState? {
    cards.first { $0.id == id }
  }

  private static func center(of card: CardState) -> CGPoint {
    CGPoint(x: card.x + card.w / 2, y: card.y + card.h / 2)
  }

  /// Called when a card's text changed (debounced persistence).
  func noteEdited(cardID: UUID, previousText: String) {
    // Editing the board can change which commands exist, so last copy's failure marks are stale.
    if !failedShellCommands.isEmpty { failedShellCommands = [] }
    // A live keystroke edit means the human authored this card now — flip its tag (e.g. when they
    // change a card the agent drew), so the agent can spot what changed on its next read.
    if editingCardID == cardID, let i = cards.firstIndex(where: { $0.id == cardID }), cards[i].whoWrote != Author.human {
      cards[i].whoWrote = Author.human
    }
    // `setText` already registers the mutation before publishing the interaction text. Consume its
    // explicit marker instead of inferring from `CardState.text`, which stays stale during inline
    // editing and can coincidentally equal a legitimate later edit.
    let isAlreadyCommitted: Bool
    if let committed = committedTextNotifications.removeValue(forKey: cardID) {
      isAlreadyCommitted = committed == interactions[cardID]?.plainText
    } else {
      isAlreadyCommitted = false
    }
    if textEditBaselines[cardID] == nil, !isAlreadyCommitted {
      textEditBaselines[cardID] = previousText
      let before = snapshot().map { card -> CardState in
        guard card.id == cardID else { return card }
        var copy = card
        copy.text = previousText
        return copy
      }
      registerUndo(historySnapshot(cards: before))
    }
    invalidateBoardTextContext()
    scheduleSave()
  }

  /// Tracks whether a card can currently observe `CardInteraction` publications.
  func setCardMounted(_ id: UUID, _ mounted: Bool) {
    if mounted {
      mountedCardIDs.insert(id)
    } else {
      mountedCardIDs.remove(id)
      committedTextNotifications[id] = nil
    }
  }

  // MARK: Derived context

  /// Read-only context for the linter: the OTHER cards' plain text, lightly labeled and
  /// length-capped so it stays inside the on-device window. `nil` for a lone card.
  func lintContext(excluding id: UUID) -> String? {
    let others = readingOrder().filter { $0.id != id }
      .compactMap { card -> String? in
        let text = plainText(for: card).trimmed
        return text.isEmpty ? nil : text
      }
    guard !others.isEmpty else { return nil }
    var budget = 2_400
    var lines: [String] = []
    for (index, text) in others.enumerated() {
      let clipped = String(text.prefix(budget))
      lines.append("Card \(index + 1): \(clipped)")
      budget -= clipped.count
      if budget <= 0 { break }
    }
    return lines.joined(separator: "\n")
  }

  /// Every card's plain text in spatial reading order — the source for both Compile
  /// (→ engine) and self-contained Copy (→ SelfContainedRenderer).
  func joinedPlainText() -> String {
    readingOrder()
      .compactMap { card -> String? in
        let text = plainText(for: card).trimmed
        return text.isEmpty ? nil : text
      }
      .joined(separator: "\n\n")
  }

  var hasContent: Bool {
    cards.contains { !plainText(for: $0).trimmed.isEmpty }
  }

  /// Copy-time variables defined anywhere on the board (`name = …` lines). A board is "one thing",
  /// so a `$name` in one card styles against a definition in any other. Used only for styling.
  /// The immutable context is derived once per explicit board-text revision.
  var definedVariableNames: Set<String> { boardTextContext.definedVariableNames }

  // MARK: Reading order

  /// Top→bottom, then left→right, with a row band so cards roughly level read left-to-right.
  func readingOrder() -> [CardState] {
    let band = 64.0
    return cards.sorted { a, b in
      let ay = (a.y / band).rounded(.down)
      let by = (b.y / band).rounded(.down)
      if ay != by { return ay < by }
      if a.x != b.x { return a.x < b.x }
      return a.z < b.z
    }
  }
}
