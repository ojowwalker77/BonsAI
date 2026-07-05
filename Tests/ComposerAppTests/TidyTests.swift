import XCTest
@testable import ComposerApp

/// The human-facing Tidy commands (`relayoutSelection`) and the move-snap wiring in `BoardViewModel`
/// (`snappedDelta` + `snapGuides` publication). The pure snap math lives in `SnapEngineTests`; these
/// guard the VM contract the UI depends on: preview==commit snapping, guides that always retire, a
/// selection re-flow that stays put, and the ⌥-duplicate undo grain.
@MainActor
final class TidyTests: XCTestCase {
  /// In-memory store: `swift test` is unsandboxed, so the shared store IS the user's real board.
  private func makeBoard() -> BoardViewModel {
    BoardViewModel(store: DumpStore(inMemoryOnly: true))
  }

  /// Insert `count` rectangles in a rough row and return their ids in insertion order. The board
  /// ships a starter card; drop every pre-existing card so peer snapping is deterministic.
  private func seedCards(_ board: BoardViewModel, count: Int) -> [UUID] {
    let preexisting = board.cards.map(\.id)
    let specs = (0..<count).map { i in
      CardState(kind: .rectangle, x: Double(i) * 200, y: Double(i) * 30, w: 120, h: 60, z: i)
    }
    let ids = board.insertCopies(specs, offset: .zero)
    XCTAssertEqual(ids.count, count)
    for id in preexisting { board.delete(id) }
    return ids
  }

  private func frame(of id: UUID, in board: BoardViewModel) -> CGRect {
    board.cards.first { $0.id == id }!.frame
  }

  private func select(_ ids: [UUID], in board: BoardViewModel) {
    for (i, id) in ids.enumerated() { board.select(id, extending: i > 0) }
  }

  // MARK: Tidy selection

  func testRelayoutSelectionMovesOnlySelectedCards() {
    let board = makeBoard()
    let ids = seedCards(board, count: 4)
    let selected = [ids[0], ids[1]]
    let untouched = [ids[2], ids[3]]
    let framesBefore = untouched.map { frame(of: $0, in: board) }

    select(selected, in: board)
    board.relayoutSelection()

    for (id, before) in zip(untouched, framesBefore) {
      XCTAssertEqual(frame(of: id, in: board), before, "a non-selected card must not move")
    }
    XCTAssertEqual(board.selectedCardIDs, Set(selected), "selection is preserved")
  }

  func testRelayoutSelectionKeepsBoundingBoxCenter() {
    let board = makeBoard()
    let ids = seedCards(board, count: 3)
    let selected = [ids[0], ids[1], ids[2]]

    func center(_ ids: [UUID]) -> CGPoint {
      let rects = ids.map { frame(of: $0, in: board) }
      let union = rects.dropFirst().reduce(rects[0]) { $0.union($1) }
      return CGPoint(x: union.midX, y: union.midY)
    }

    let before = center(selected)
    select(selected, in: board)
    board.relayoutSelection()
    let after = center(selected)

    XCTAssertEqual(after.x, before.x, accuracy: 1, "subset center holds on x")
    XCTAssertEqual(after.y, before.y, accuracy: 1, "subset center holds on y")
  }

  func testRelayoutSelectionIsOneUndoStep() {
    let board = makeBoard()
    let ids = seedCards(board, count: 3)
    let selected = [ids[0], ids[1], ids[2]]
    let framesBefore = selected.map { frame(of: $0, in: board) }

    select(selected, in: board)
    board.relayoutSelection()
    board.undo()

    for (id, before) in zip(selected, framesBefore) {
      XCTAssertEqual(frame(of: id, in: board), before, "one undo restores every selected frame")
    }
  }

  func testRelayoutSelectionNoOpsBelowTwo() {
    let board = makeBoard()
    let ids = seedCards(board, count: 3)
    let framesBefore = ids.map { frame(of: $0, in: board) }

    board.select(ids[0])              // one card selected → nothing to tidy
    board.relayoutSelection()

    for (id, before) in zip(ids, framesBefore) {
      XCTAssertEqual(frame(of: id, in: board), before, "a lone selection is a no-op")
    }
  }

  // MARK: Snap wiring

  func testSnappedDeltaSnapsToPeerEdgeAndPublishesGuide() {
    let board = makeBoard()
    let ids = seedCards(board, count: 2)   // card 0 at x=0, card 1 at x=200
    let mover = ids[0]

    // Nudge card 0 so its left edge lands 3pt shy of card 1's left edge (x=200) — inside tolerance.
    let proposed = CGSize(width: 197, height: 0)
    let snapped = board.snappedDelta(for: [mover], proposed: proposed, tolerance: 8)

    XCTAssertEqual(snapped.width, 200, accuracy: 0.001, "left edge snaps to the peer's left edge")
    XCTAssertFalse(board.snapGuides.isEmpty, "a snap publishes at least one guide")
  }

  func testSnappedDeltaEmptyMovingSetClearsGuides() {
    let board = makeBoard()
    _ = seedCards(board, count: 2)
    // Prime a guide, then a no-op call with an empty set must retire it.
    _ = board.snappedDelta(for: [], proposed: .zero, tolerance: 8)
    XCTAssertTrue(board.snapGuides.isEmpty)
  }

  func testMovePreviewPublishesGuidesAndCommitClearsThem() {
    let board = makeBoard()
    let ids = seedCards(board, count: 2)
    board.select(ids[0])

    board.updateMovePreview(by: CGSize(width: 197, height: 0), tolerance: 8)
    XCTAssertFalse(board.snapGuides.isEmpty, "preview publishes guides while snapping")

    board.finishMovePreview(commit: true)
    XCTAssertTrue(board.snapGuides.isEmpty, "committing retires the guides")
  }

  func testCancelledMovePreviewClearsGuides() {
    let board = makeBoard()
    let ids = seedCards(board, count: 2)
    board.select(ids[0])

    board.updateMovePreview(by: CGSize(width: 197, height: 0), tolerance: 8)
    XCTAssertFalse(board.snapGuides.isEmpty)

    board.finishMovePreview(commit: false)
    XCTAssertTrue(board.snapGuides.isEmpty, "cancelling retires the guides too")
  }

  func testPreviewSnapMatchesCommit() {
    let board = makeBoard()
    let ids = seedCards(board, count: 2)
    let mover = ids[0]
    board.select(mover)

    let raw = CGSize(width: 197, height: 0)
    let previewSnapped = board.snappedDelta(for: [mover], proposed: raw, tolerance: 8)
    let before = frame(of: mover, in: board)

    board.updateMovePreview(by: raw, tolerance: 8)
    board.finishMovePreview(commit: true)

    let after = frame(of: mover, in: board)
    XCTAssertEqual(after.minX - before.minX, previewSnapped.width, accuracy: 0.001,
                   "what the preview snapped to is exactly what committed")
  }

  func testOptionDuplicateDragFoldsToOneUndo() {
    let board = makeBoard()
    let ids = seedCards(board, count: 2)
    board.select(ids[0])
    let countBefore = board.cards.count

    // ⌥-drag: snapshot + insert copies, then move + commit the copies through the preview.
    board.beginDragDuplicate()
    XCTAssertEqual(board.cards.count, countBefore + 1, "a copy was inserted")
    board.updateMovePreview(by: CGSize(width: 40, height: 40), tolerance: 8)
    board.finishMovePreview(commit: true)

    board.undo()
    XCTAssertEqual(board.cards.count, countBefore, "one undo removes the whole ⌥-duplicate gesture")
    XCTAssertTrue(board.snapGuides.isEmpty)
  }
}
