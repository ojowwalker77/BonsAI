import XCTest
@testable import ComposerApp

/// Pins the first round of canvas-quirk fixes: scroll interpretation, copy/group semantics, and
/// the undo trail of an abandoned text card.
@MainActor
final class CanvasInteractionFixesTests: XCTestCase {
  // MARK: Scroll input

  func testTrackpadScrollPansByItsPreciseDeltas() {
    XCTAssertEqual(
      CanvasScrollInput(deltaX: 3, deltaY: -7, hasPreciseDeltas: true, zoomModifier: false),
      .pan(CGSize(width: 3, height: -7)))
  }

  func testMouseWheelLinesAreScaledToAUsefulPanDistance() {
    XCTAssertEqual(
      CanvasScrollInput(deltaX: 0, deltaY: 1, hasPreciseDeltas: false, zoomModifier: false),
      .pan(CGSize(width: 0, height: CanvasScrollInput.wheelLinePoints)))
  }

  func testModifierScrollZoomsInTowardTheUserAndOutAway() throws {
    guard case .zoom(let zoomIn) = CanvasScrollInput(
      deltaX: 0, deltaY: 1, hasPreciseDeltas: false, zoomModifier: true) else {
      return XCTFail("⌘/⌃ + scroll must zoom")
    }
    guard case .zoom(let zoomOut) = CanvasScrollInput(
      deltaX: 0, deltaY: -1, hasPreciseDeltas: false, zoomModifier: true) else {
      return XCTFail("⌘/⌃ + scroll must zoom")
    }
    XCTAssertGreaterThan(zoomIn, 1)
    XCTAssertLessThan(zoomOut, 1)
  }

  func testOneScrollEventNeverMoreThanDoublesOrHalvesTheZoom() {
    XCTAssertEqual(
      CanvasScrollInput(deltaX: 0, deltaY: 10_000, hasPreciseDeltas: true, zoomModifier: true),
      .zoom(2))
    XCTAssertEqual(
      CanvasScrollInput(deltaX: 0, deltaY: -10_000, hasPreciseDeltas: true, zoomModifier: true),
      .zoom(0.5))
  }

  // MARK: Copies

  func testCopiesFormTheirOwnGroupAndAreNeverLocked() throws {
    let board = BoardViewModel(store: DumpStore(inMemoryOnly: true, loadInitialContent: false))
    let group = UUID()
    var first = CardState(text: "a", x: 0, y: 0, w: 100, h: 60, z: 1)
    first.groupID = group
    first.isLocked = true
    var second = CardState(text: "b", x: 200, y: 0, w: 100, h: 60, z: 2)
    second.groupID = group

    let ids = board.insertCopies([first, second], offset: .zero)
    let copies = ids.compactMap { id in board.cards.first { $0.id == id } }

    XCTAssertEqual(copies.count, 2)
    let copiedGroups = Set(copies.compactMap(\.groupID))
    XCTAssertEqual(copiedGroups.count, 1, "copied members of one group stay grouped together")
    XCTAssertFalse(copiedGroups.contains(group), "copies must not join the original group")
    XCTAssertTrue(copies.allSatisfy { !$0.locked })
  }

  // MARK: Abandoned text

  func testAbandonedFreshTextCardLeavesNoUndoStep() throws {
    let board = BoardViewModel(store: DumpStore(inMemoryOnly: true, loadInitialContent: false))
    let seed = try XCTUnwrap(board.cards.first)
    board.setText(seed.id, "keep me")
    let before = board.cards.map(\.id)

    let id = board.addCard(at: CGPoint(x: 400, y: 400))
    board.endEditing(id)
    XCTAssertEqual(board.cards.map(\.id), before)

    // Undo must step back past the seed edit, never resurrect the abandoned empty card.
    board.undo()
    XCTAssertFalse(board.cards.contains { $0.id == id })
  }
}
