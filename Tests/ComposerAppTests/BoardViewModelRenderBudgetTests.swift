import XCTest
import SwiftData
@testable import ComposerApp

@MainActor
final class BoardViewModelRenderBudgetTests: XCTestCase {
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
