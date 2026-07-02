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
  }

  /// Self-contained plain text (mention tokens serialized back to `@name`). Falls back to
  /// the last captured editor value while the heavy AppKit editor is unmounted. `text` is kept
  /// in serialized form while editing, and `captureEditorState()` refreshes this cache before an
  /// editor leaves the view tree, so reading a static card never needs to instantiate its editor.
  var plainText: String {
    plainTextCache
  }

  var attributedSnapshot: NSAttributedString? { attributedCache }

  func captureEditorState() {
    if let snapshot = controller.attributedSnapshot {
      attributedCache = snapshot
      plainTextCache = snapshot.composerPlainText
      count = snapshot.string.count
    } else if let plain = controller.plainTextIfLoaded {
      plainTextCache = plain
    }
  }

  func cachePlainText(_ value: String) {
    plainTextCache = value
  }
}

// MARK: - Board view-model

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

  private var interactions: [UUID: CardInteraction] = [:]
  private var movePreviewIDs: Set<UUID> = []
  private var movePreviewDelta: CGSize = .zero
  private var nextZ = 1
  private var undoStack: [HistorySnapshot] = []
  private var redoStack: [HistorySnapshot] = []
  private var textEditBaselines: [UUID: String] = [:]
  private var isRestoringHistory = false
  /// Set while a compound mutation (e.g. building a whole diagram) runs, so the inner
  /// `insertText`/`connectCards` calls don't each push their own undo step — the batch registers
  /// exactly one at the top.
  private var suppressUndo = false
  /// Who authored the next mutation: `Author.human` by default; the canvas bridge flips it to
  /// `Author.agent` while applying an agent's edits, so every card records who last wrote it.
  var nextAuthor = Author.human

  enum Author { static let human = 1; static let agent = 2 }
  private let maxHistoryDepth = 80
  /// Undo/redo kept per board, so flipping to another board and back doesn't lose your history.
  private var undoCache: [PersistentIdentifier: (undo: [HistorySnapshot], redo: [HistorySnapshot])] = [:]
  private var currentBoardID: PersistentIdentifier?

  init() {
    self.store = DumpStore.shared
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
    if card.elementKind == .image { return card.imagePath ?? "" }
    return interactions[card.id]?.plainText ?? card.text
  }

  var selectedInteraction: CardInteraction? { selectedCardID.flatMap { interactions[$0] } }
  var editingInteraction: CardInteraction? { editingCardID.flatMap { interactions[$0] } }
  var selectedCardID: UUID? { primarySelectedCardID }

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
    selectedCardIDs = [id]
    primarySelectedCardID = id
    editingCardID = id
  }

  /// The editor lost first responder.
  func endEditing(_ id: UUID) {
    interactions[id]?.captureEditorState()
    textEditBaselines[id] = nil
    if editingCardID == id { editingCardID = nil }
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
    textEditBaselines[id] = nil
    interactions[id]?.controller.resignFocus()
    editingCardID = nil
  }

  // MARK: Load / save

  /// Pull the current board's cards into the working set, rebuilding bundles.
  func loadFromStore() {
    // Stash the outgoing board's undo history, then restore the incoming board's (if any).
    if let previous = currentBoardID { undoCache[previous] = (undoStack, redoStack) }
    currentBoardID = store.currentID
    let loaded = store.currentCards
    cards = loaded
    // Fit every text card to its content — no live editor is mounted to report heights yet.
    for i in cards.indices where cards[i].elementKind == .text {
      cards[i].h = Double(Self.fittedTextHeight(cards[i].text, width: cards[i].w))
    }
    // Runtime bundles are created lazily as cards become visible or enter edit mode. A board can
    // contain hundreds of cards, but only a small cullable subset should carry editor state.
    interactions = [:]
    nextZ = (cards.map(\.z).max() ?? 0) + 1
    let restored = currentBoardID.flatMap { undoCache[$0] }
    undoStack = restored?.undo ?? []
    redoStack = restored?.redo ?? []
    textEditBaselines = [:]
    if let first = loaded.first?.id {
      selectedCardIDs = [first]
      primarySelectedCardID = first
    } else {
      selectedCardIDs = []
      primarySelectedCardID = nil
    }
    editingCardID = nil
  }

  /// Geometry + live plain text, ready to persist.
  private func snapshot() -> [CardState] {
    cards.map { card in
      var copy = card
      copy.text = plainText(for: card)
      return copy
    }
  }

  /// Build the persistence snapshot only when the debounce actually fires. This avoids cloning
  /// the entire board on every keystroke and keeps cancelled saves from retaining stale snapshots.
  func scheduleSave() { store.scheduleUpdate { [weak self] in self?.snapshot() } }
  func flushSave() { store.flush(cards: snapshot()) }

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

  private func restore(_ value: HistorySnapshot) {
    isRestoringHistory = true
    cards = value.cards
    interactions = [:]
    selectedCardIDs = value.selectedCardIDs.intersection(Set(value.cards.map(\.id)))
    primarySelectedCardID = selectedCardIDs.contains(value.primarySelectedCardID ?? UUID())
      ? value.primarySelectedCardID
      : selectedCardIDs.first
    editingCardID = nil
    nextZ = max(value.nextZ, (value.cards.map(\.z).max() ?? 0) + 1)
    clearMovePreview()
    textEditBaselines = [:]
    scheduleSave()
    isRestoringHistory = false
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
    scheduleSave()
    return card.id
  }

  @discardableResult
  func addElement(_ kind: CanvasElementKind, at center: CGPoint) -> UUID {
    if kind == .text { return addCard(at: center) }
    registerUndo()
    let size: CGSize = {
      switch kind {
      case .line, .arrow, .freehand: CardState.lineSize
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
      case .text, .rectangle, .ellipse, .diamond, .image:
        return nil
      }
    }()
    let card = CardState(
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
    nextZ += 1
    cards.append(card)
    if kind == .arrow { bindArrowIfPossible(card.id) }
    interactions[card.id] = CardInteraction(card)
    selectedCardIDs = [card.id]
    primarySelectedCardID = card.id
    editingCardID = nil
    scheduleSave()
    return card.id
  }

  /// Create a shape or line sized by a drag from `start` to `end` (board space). Lines/arrows
  /// keep the two points as their endpoints; boxes use the bounding frame. Clamped to a minimum.
  @discardableResult
  func addDrawnElement(_ kind: CanvasElementKind, from start: CGPoint, to end: CGPoint) -> UUID? {
    guard kind != .text, kind != .freehand, kind != .image else { return nil }
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
    if kind == .arrow { bindArrowIfPossible(card.id) }
    interactions[card.id] = CardInteraction(card)
    selectedCardIDs = [card.id]
    primarySelectedCardID = card.id
    editingCardID = nil
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
    scheduleSave()
    return card.id
  }

  @discardableResult
  func addImageObject(path: String, at center: CGPoint) -> UUID {
    registerUndo()
    let size = Self.imageCardSize(forPath: path)
    let card = CardState(
      kind: .image,
      text: "",
      x: Double(center.x - size.width / 2),
      y: Double(center.y - size.height / 2),
      w: Double(size.width),
      h: Double(size.height),
      z: nextZ,
      imagePath: path,
      whoWrote: nextAuthor
    )
    nextZ += 1
    cards.append(card)
    interactions[card.id] = CardInteraction(card)
    selectedCardIDs = [card.id]
    primarySelectedCardID = card.id
    editingCardID = nil
    scheduleSave()
    return card.id
  }

  /// A dropped image keeps its own aspect ratio: size the card to the image so its rounded border and
  /// the selection ring coincide instead of the image overflowing (or letterboxing) a fixed landscape
  /// default. Reads just the pixel dimensions — no full decode — and fits them into an on-board
  /// footprint; falls back to the shape default if the file can't be read.
  private static func imageCardSize(forPath path: String) -> CGSize {
    guard
      let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
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
    cards[i].text = text
    cards[i].whoWrote = nextAuthor
    let bundle = interaction(for: id)
    bundle.text = text
    bundle.cachePlainText(text)
    if cards[i].elementKind == .text { cards[i].h = Double(Self.fittedTextHeight(text, width: cards[i].w)) }
    scheduleSave()
  }

  /// Height a text card needs to show `text` at `width`, measured the way the non-editing card
  /// renders it. Used for agent/programmatic edits and on load, where no live editor reports it.
  static func fittedTextHeight(_ text: String, width: CGFloat) -> CGFloat {
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineSpacing = Theme.Typography.bodyLineSpacing
    let attributes: [NSAttributedString.Key: Any] = [.font: Theme.Typography.body, .paragraphStyle: paragraph]
    let contentWidth = max(width - 32, 40)   // CanvasElementContent uses 16pt horizontal padding
    let measured = ((text.isEmpty ? " " : text) as NSString).boundingRect(
      with: NSSize(width: contentWidth, height: .greatestFiniteMagnitude),
      options: [.usesLineFragmentOrigin, .usesFontLeading],
      attributes: attributes).height
    return max(ceil(measured) + 36, CardState.textMinSize.height)   // 18pt vertical padding each side
  }

  /// Draw an arrow bound between two existing cards (its geometry tracks their centers). An
  /// optional `reason` rides the arrow as its label — the "why" behind the link.
  @discardableResult
  func connectCards(from: UUID, to: UUID, reason: String = "") -> UUID? {
    guard from != to, cards.contains(where: { $0.id == from }), cards.contains(where: { $0.id == to }) else { return nil }
    registerUndo()
    let card = CardState(kind: .arrow, text: reason,
                         x: 0, y: 0, w: Double(CardState.lineSize.width), h: Double(CardState.lineSize.height),
                         z: nextZ, startBindingID: from, endBindingID: to, whoWrote: nextAuthor)
    nextZ += 1
    cards.append(card)
    interactions[card.id] = CardInteraction(card)
    if let index = cards.firstIndex(where: { $0.id == card.id }) { updateBoundArrowGeometry(at: index) }
    selectedCardIDs = [card.id]
    primarySelectedCardID = card.id
    scheduleSave()
    return card.id
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
    defer { suppressUndo = false; refreshBoundArrows(); scheduleSave() }
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
    defer { suppressUndo = false; refreshBoundArrows(); scheduleSave() }

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
    defer { suppressUndo = false; refreshBoundArrows(); scheduleSave() }

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

  /// Insert a text card and let the board pick a non-overlapping spot — used when an agent adds a
  /// one-off card without (or not caring about) coordinates.
  @discardableResult
  func insertTextAutoPlaced(_ text: String) -> UUID {
    let size = Self.fittedTextSize(text)
    return insertText(text, at: autoPlacePoint(for: size))
  }

  /// Append captured text from the menu bar, Services menu, URL scheme, or loopback API.
  @discardableResult
  func captureExternalText(_ text: String) -> UUID? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let id = insertTextAutoPlaced(trimmed)
    beginEditing(id)
    return id
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
    case .text, .rectangle, .ellipse, .diamond, .image: return true
    case .line, .arrow, .freehand: return false
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

  /// A box sized to hold a centered node label (the diagram-node font/padding), wrapping rather
  /// than truncating. Ellipses/diamonds get extra room so the label fits inside the inscribed area.
  static func fittedShapeSize(_ text: String, shape: CanvasElementKind = .rectangle, maxWidth: CGFloat = 216) -> CGSize {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14, weight: .semibold),
                                                      .paragraphStyle: paragraph]
    let ns = (text.isEmpty ? " " : text) as NSString
    let natural = ns.size(withAttributes: attributes).width
    let contentWidth = min(max(natural, 72), maxWidth - 24)   // 12pt horizontal padding each side
    let measured = ns.boundingRect(with: NSSize(width: contentWidth, height: .greatestFiniteMagnitude),
                                   options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes).height
    var width = ceil(contentWidth) + 24
    var height = max(ceil(measured) + 22, 54)
    switch shape {
    case .ellipse: width = ceil(width * 1.24); height = ceil(height * 1.35)
    case .diamond: width = ceil(width * 1.5); height = ceil(height * 1.5)
    default: break
    }
    return CGSize(width: width, height: height)
  }

  /// The point on `rect`'s edge along the line toward `target`, pushed out by `margin`. Used to land
  /// a bound arrow on a node's boundary instead of its center.
  static func boundaryPoint(of rect: CGRect, toward target: CGPoint, margin: CGFloat) -> CGPoint {
    let c = CGPoint(x: rect.midX, y: rect.midY)
    let dx = target.x - c.x, dy = target.y - c.y
    guard dx != 0 || dy != 0 else { return c }
    let tx = dx != 0 ? (rect.width / 2) / abs(dx) : .greatestFiniteMagnitude
    let ty = dy != 0 ? (rect.height / 2) / abs(dy) : .greatestFiniteMagnitude
    let t = Swift.min(tx, ty)
    let len = hypot(dx, dy)
    return CGPoint(x: c.x + dx * t + dx / len * margin, y: c.y + dy * t + dy / len * margin)
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
    if cards[i].elementKind == .arrow {
      cards[i].startBindingID = nil
      cards[i].endBindingID = nil
    }
    cards[i].frame = next
    refreshBoundArrows()
    scheduleSave()
  }

  /// Grow/shrink a text card's height to fit what's typed. This is a layout consequence of
  /// editing (the keystroke already registered undo), so it never pushes its own undo step and
  /// only touches height — width stays where the user left it.
  func fitTextHeight(_ id: UUID, to height: CGFloat) {
    guard let i = cards.firstIndex(where: { $0.id == id }), cards[i].elementKind == .text else { return }
    let target = max(height, CardState.textMinSize.height)
    guard abs(cards[i].h - Double(target)) > 0.5 else { return }
    cards[i].h = Double(target)
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
    clearMovePreview()
    guard let i = index(for: id), !cards[i].locked else { return }
    registerUndo()
    cards.removeAll { $0.id == id }
    interactions[id] = nil
    if editingCardID == id { editingCardID = nil }
    selectedCardIDs.remove(id)
    if primarySelectedCardID == id { primarySelectedCardID = selectedCardIDs.first }
    if cards.isEmpty {
      let fresh = CardState.firstCard()
      cards = [fresh]
      interactions[fresh.id] = CardInteraction(fresh)
      selectedCardIDs = [fresh.id]
      primarySelectedCardID = fresh.id
    }
    refreshBoundArrows()
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
    for id in deleting { interactions[id] = nil }
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
    refreshBoundArrows()
    scheduleSave()
  }

  func selectedCardsForClipboard() -> [CardState] {
    let selected = cards.filter { selectedCardIDs.contains($0.id) }
    return selected.map { card in
      var copy = card
      copy.text = plainText(for: card)
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
    for original in ordered {
      var copy = original
      copy.id = UUID()
      copy.x += Double(offset.width)
      copy.y += Double(offset.height)
      copy.z = nextZ
      copy.whoWrote = nextAuthor
      copy.startBindingID = nil
      copy.endBindingID = nil
      nextZ += 1
      cards.append(copy)
      interactions[copy.id] = CardInteraction(copy)
      ids.append(copy.id)
    }
    selectedCardIDs = Set(ids)
    primarySelectedCardID = ids.last
    editingCardID = nil
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
    detachMovedArrows(moving)
    refreshBoundArrows()
    scheduleSave()
  }

  func updateMovePreview(by delta: CGSize) {
    let moving = unlockedIDs(in: selectedCardIDs)
    // A multi-selection can contain locked cards. Preview the unlocked subset even when it has
    // only one member, because BoardCardView still commits through finishMovePreview for the
    // original multi-selection.
    guard !moving.isEmpty else { return }
    if movePreviewIDs != moving {
      clearMovePreview()
      movePreviewIDs = moving
    }
    movePreviewDelta = delta
    for id in moving {
      interactions[id]?.dragDelta = delta
    }
  }

  func finishMovePreview(commit: Bool) {
    let ids = movePreviewIDs
    let delta = movePreviewDelta
    clearMovePreview()
    guard commit, !ids.isEmpty, delta != .zero else { return }
    registerUndo()
    for i in cards.indices where ids.contains(cards[i].id) {
      cards[i].x += Double(delta.width)
      cards[i].y += Double(delta.height)
    }
    detachMovedArrows(ids)
    refreshBoundArrows()
    scheduleSave()
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

  private func clearMovePreview() {
    for id in movePreviewIDs {
      interactions[id]?.dragDelta = .zero
    }
    movePreviewIDs = []
    movePreviewDelta = .zero
  }

  private func detachMovedArrows(_ ids: Set<UUID>) {
    for i in cards.indices where ids.contains(cards[i].id) && cards[i].elementKind == .arrow {
      cards[i].startBindingID = nil
      cards[i].endBindingID = nil
    }
  }

  private func bindArrowIfPossible(_ id: UUID) {
    guard let i = index(for: id), cards[i].elementKind == .arrow else { return }
    let endpoints = lineEndpoints(for: cards[i])
    var excluded: Set<UUID> = [id]
    if let start = nearestConnectable(to: endpoints.start, excluding: excluded) {
      cards[i].startBindingID = start.id
      excluded.insert(start.id)
    }
    if let end = nearestConnectable(to: endpoints.end, excluding: excluded) {
      cards[i].endBindingID = end.id
    }
    if cards[i].startBindingID != nil || cards[i].endBindingID != nil {
      updateBoundArrowGeometry(at: i)
    }
  }

  private func refreshBoundArrows() {
    let existing = Set(cards.map(\.id))
    for i in cards.indices where cards[i].elementKind == .arrow {
      if let start = cards[i].startBindingID, !existing.contains(start) {
        cards[i].startBindingID = nil
      }
      if let end = cards[i].endBindingID, !existing.contains(end) {
        cards[i].endBindingID = nil
      }
      if cards[i].startBindingID != nil || cards[i].endBindingID != nil {
        updateBoundArrowGeometry(at: i)
      }
    }
  }

  private func nearestConnectable(to point: CGPoint, excluding excluded: Set<UUID>) -> CardState? {
    let maxDistance: CGFloat = 220
    return cards
      .filter { card in
        !excluded.contains(card.id) &&
        !card.locked &&
        card.elementKind != .line &&
        card.elementKind != .arrow &&
        card.elementKind != .freehand
      }
      .compactMap { card -> (CardState, CGFloat)? in
        let center = center(of: card)
        let distance = hypot(center.x - point.x, center.y - point.y)
        return distance <= maxDistance ? (card, distance) : nil
      }
      .min(by: { $0.1 < $1.1 })?
      .0
  }

  private func updateBoundArrowGeometry(at index: Int) {
    guard cards.indices.contains(index), cards[index].elementKind == .arrow else { return }
    let current = lineEndpoints(for: cards[index])
    let startCard = cards[index].startBindingID.flatMap { card(id: $0) }
    let endCard = cards[index].endBindingID.flatMap { card(id: $0) }
    let rawStart = startCard.map(center(of:)) ?? current.start
    let rawEnd = endCard.map(center(of:)) ?? current.end
    // Land each bound endpoint on its node's boundary (aiming at the other end), with a small gap
    // at the arrowhead — so the arrow touches the box edge instead of piercing the label.
    let start = startCard.map { Self.boundaryPoint(of: $0.frame, toward: rawEnd, margin: 1) } ?? rawStart
    let end = endCard.map { Self.boundaryPoint(of: $0.frame, toward: rawStart, margin: 7) } ?? rawEnd
    applyLineGeometry(to: index, start: start, end: end)
  }

  private func applyLineGeometry(to index: Int, start: CGPoint, end: CGPoint) {
    let padding: CGFloat = 18
    var minX = min(start.x, end.x) - padding
    var minY = min(start.y, end.y) - padding
    var maxX = max(start.x, end.x) + padding
    var maxY = max(start.y, end.y) + padding
    let minSize = cards[index].minimumSize
    if maxX - minX < minSize.width {
      let extra = (minSize.width - (maxX - minX)) / 2
      minX -= extra
      maxX += extra
    }
    if maxY - minY < minSize.height {
      let extra = (minSize.height - (maxY - minY)) / 2
      minY -= extra
      maxY += extra
    }
    let frame = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    cards[index].frame = frame
    cards[index].points = [
      CanvasPoint(
        x: Double((start.x - frame.minX) / frame.width),
        y: Double((start.y - frame.minY) / frame.height)
      ),
      CanvasPoint(
        x: Double((end.x - frame.minX) / frame.width),
        y: Double((end.y - frame.minY) / frame.height)
      ),
    ]
  }

  private func lineEndpoints(for card: CardState) -> (start: CGPoint, end: CGPoint) {
    let points = card.points ?? CardState.defaultLinePoints()
    let start = points.first?.cgPoint ?? CGPoint(x: 0.06, y: 0.88)
    let end = points.dropFirst().first?.cgPoint ?? CGPoint(x: 0.94, y: 0.12)
    return (
      CGPoint(x: card.x + start.x * card.w, y: card.y + start.y * card.h),
      CGPoint(x: card.x + end.x * card.w, y: card.y + end.y * card.h)
    )
  }

  private func card(id: UUID) -> CardState? {
    cards.first { $0.id == id }
  }

  private func center(of card: CardState) -> CGPoint {
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
    if textEditBaselines[cardID] == nil {
      textEditBaselines[cardID] = previousText
      let before = snapshot().map { card -> CardState in
        guard card.id == cardID else { return card }
        var copy = card
        copy.text = previousText
        return copy
      }
      registerUndo(historySnapshot(cards: before))
    }
    scheduleSave()
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
  var definedVariableNames: Set<String> {
    ShellTemplate.definedNames(in: joinedPlainText())
  }

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
