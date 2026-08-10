import XCTest
import SwiftData
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

  func testDiagramBatchesBoardTextContextDerivation() {
    let board = BoardViewModel(store: DumpStore(inMemoryOnly: true, loadInitialContent: false))
    let before = board.boardTextContextDerivationCount

    _ = board.createDiagram(
      nodes: [
        .init(key: "source", text: "source=(value)"),
        .init(key: "target", text: "$source"),
      ],
      edges: [
        .init(from: "source", to: "target", reason: "first"),
        .init(from: "source", to: "target", reason: "second"),
      ],
      direction: .right)

    XCTAssertEqual(board.boardTextContextDerivationCount, before + 1)
    XCTAssertEqual(board.boardTextContext.definedVariableNames, Set(["source"]))
  }

  func testInactiveHistoryIsBoundedAndActiveHistoryStaysOutOfCache() throws {
    let store = DumpStore(inMemoryOnly: true, loadInitialContent: false)
    let board = BoardViewModel(store: store)
    let firstBoardID = try XCTUnwrap(store.currentID)
    let firstCard = try XCTUnwrap(board.cards.first)

    board.setText(firstCard.id, "retained")
    XCTAssertTrue(board.flushSave())
    store.newDump()
    board.loadFromStore()

    // Switching away retains history, and switching back restores behavior rather than merely
    // keeping a cache entry that cannot be used.
    XCTAssertTrue(board.cachedHistoryBoardIDs.contains(firstBoardID))
    store.select(firstBoardID)
    board.loadFromStore()
    board.undo()
    XCTAssertEqual(board.plainText(for: try XCTUnwrap(board.cards.first)), "")
    board.redo()
    XCTAssertEqual(board.plainText(for: try XCTUnwrap(board.cards.first)), "retained")

    // Move away again so the restored board becomes the least-recently-used inactive entry.
    XCTAssertTrue(board.flushSave())
    store.newDump()
    board.loadFromStore()

    for index in 0...BoardViewModel.maxCachedHistoryBoards {
      let card = try XCTUnwrap(board.cards.first)
      board.setText(card.id, "board \(index)")
      XCTAssertTrue(board.flushSave())
      store.newDump()
      board.loadFromStore()
    }

    XCTAssertFalse(board.cachedHistoryBoardIDs.contains(firstBoardID))
    XCTAssertLessThanOrEqual(board.cachedHistoryBoardCount, BoardViewModel.maxCachedHistoryBoards)
    XCTAssertLessThanOrEqual(board.cachedHistorySnapshotCardCount,
                             BoardViewModel.maxCachedHistorySnapshotCards)

    // The current board owns its live stacks, not an evictable cache entry.
    let activeCard = try XCTUnwrap(board.cards.first)
    board.setText(activeCard.id, "active")
    board.undo()
    XCTAssertNotEqual(board.plainText(for: activeCard), "active")
  }

  func testInactiveHistorySnapshotCardBudgetEvictsLeastRecentlyUsedBoard() throws {
    let store = DumpStore(inMemoryOnly: true, loadInitialContent: false)
    let board = BoardViewModel(store: store)
    let cardsPerLargeHistory = BoardViewModel.maxCachedHistorySnapshotCards / 2 + 1

    func fillCurrentBoardAndMoveOn(label: String) throws -> PersistentIdentifier {
      let boardID = try XCTUnwrap(store.currentID)
      let seed = try XCTUnwrap(board.cards.first)
      _ = board.insertCopies(
        Array(repeating: seed, count: cardsPerLargeHistory - 1),
        offset: .zero)
      // The second undo checkpoint captures the large card array in this board's history.
      board.setText(seed.id, label)
      XCTAssertTrue(board.flushSave())
      store.newDump()
      board.loadFromStore()
      return boardID
    }

    let leastRecentlyUsed = try fillCurrentBoardAndMoveOn(label: "first")
    XCTAssertTrue(board.cachedHistoryBoardIDs.contains(leastRecentlyUsed))
    let retained = try fillCurrentBoardAndMoveOn(label: "second")

    XCTAssertFalse(board.cachedHistoryBoardIDs.contains(leastRecentlyUsed))
    XCTAssertTrue(board.cachedHistoryBoardIDs.contains(retained))
    XCTAssertLessThanOrEqual(board.cachedHistoryBoardCount, BoardViewModel.maxCachedHistoryBoards)
    XCTAssertLessThanOrEqual(board.cachedHistorySnapshotCardCount,
                             BoardViewModel.maxCachedHistorySnapshotCards)
  }
}
