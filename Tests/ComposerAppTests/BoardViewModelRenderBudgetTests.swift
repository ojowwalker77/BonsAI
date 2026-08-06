import XCTest
@testable import ComposerApp

@MainActor
final class BoardViewModelRenderBudgetTests: XCTestCase {
  func testBoardTextContextDerivesOnceAndInvalidatesAcrossTextLifecycle() throws {
    let store = DumpStore(inMemoryOnly: true, loadInitialContent: false)
    let board = BoardViewModel(store: store)
    let seed = try XCTUnwrap(board.cards.first)
    let derivationsBeforeEdit = board.boardTextContextDerivationCount

    // A representative board is intentionally large enough to make a per-card whole-board parse
    // visible in instrumentation, while `insertCopies` remains one user operation/revision.
    _ = board.insertCopies(Array(repeating: seed, count: 100), offset: .zero)
    let definition = try XCTUnwrap(board.cards.first)
    let derivationsBeforeDefinition = board.boardTextContextDerivationCount

    board.setText(definition.id, "name=(value)")
    XCTAssertEqual(board.boardTextContext.definedVariableNames, Set(["name"]))
    XCTAssertEqual(board.boardTextContextDerivationCount, derivationsBeforeDefinition + 1)

    // Re-reading the immutable context for every visible card does not derive it again.
    for _ in board.cards { _ = board.boardTextContext }
    XCTAssertEqual(board.boardTextContextDerivationCount, derivationsBeforeDefinition + 1)

    let afterDefinition = board.boardTextContext.revision
    let inserted = board.insertText("$name", at: .zero)
    XCTAssertGreaterThan(board.boardTextContext.revision, afterDefinition)
    board.delete(inserted)
    XCTAssertGreaterThan(board.boardTextContext.revision, afterDefinition)

    let beforeUndo = board.boardTextContext.revision
    board.undo()
    XCTAssertGreaterThan(board.boardTextContext.revision, beforeUndo)
    let beforeRedo = board.boardTextContext.revision
    board.redo()
    XCTAssertGreaterThan(board.boardTextContext.revision, beforeRedo)

    let beforeLoad = board.boardTextContext.revision
    board.flushSave()
    board.loadFromStore()
    XCTAssertGreaterThan(board.boardTextContext.revision, beforeLoad)
    XCTAssertGreaterThan(board.boardTextContextDerivationCount, derivationsBeforeEdit)
  }

  func testOneEditorRevisionDerivesTextContextOnce() throws {
    let store = DumpStore(inMemoryOnly: true, loadInitialContent: false)
    let board = BoardViewModel(store: store)
    let card = try XCTUnwrap(board.cards.first)
    let before = board.boardTextContextDerivationCount
    let interaction = board.interaction(for: card.id)

    interaction.cachePlainText("name=(value)")
    board.noteEdited(cardID: card.id, previousText: "")

    XCTAssertEqual(board.boardTextContextDerivationCount, before + 1)
    XCTAssertEqual(board.boardTextContext.definedVariableNames, Set(["name"]))
  }

  func testInactiveHistoryIsBoundedAndActiveHistoryStaysOutOfCache() throws {
    let store = DumpStore(inMemoryOnly: true, loadInitialContent: false)
    let board = BoardViewModel(store: store)

    for index in 0..<(BoardViewModel.maxCachedHistoryBoards + 3) {
      let card = try XCTUnwrap(board.cards.first)
      board.setText(card.id, "board (index)")
      board.flushSave()
      store.newDump()
      board.loadFromStore()
    }

    XCTAssertLessThanOrEqual(board.cachedHistoryBoardCount, BoardViewModel.maxCachedHistoryBoards)
    XCTAssertLessThanOrEqual(board.cachedHistorySnapshotCardCount,
                             BoardViewModel.maxCachedHistorySnapshotCards)

    // The current board owns its live stacks, not an evictable cache entry.
    let activeCard = try XCTUnwrap(board.cards.first)
    board.setText(activeCard.id, "active")
    board.undo()
    XCTAssertNotEqual(board.plainText(for: activeCard), "active")
  }
}
