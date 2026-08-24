import XCTest
@testable import ComposerApp

@MainActor
final class CanvasElementEditingTests: XCTestCase {
  func testEditingCapabilityMatchesAvailableSurfaces() {
    let editable: [CanvasElementKind] = [
      .text, .rectangle, .ellipse, .diamond, .line, .arrow, .equation, .graph,
      .sticky, .checklist, .table,
    ]
    for kind in editable { XCTAssertTrue(kind.supportsEditing, "\(kind) should advertise editing") }
    XCTAssertFalse(CanvasElementKind.freehand.supportsEditing)
    XCTAssertFalse(CanvasElementKind.image.supportsEditing)
  }

  func testUnsupportedKindsCannotLeaveAnInvisibleEditSession() throws {
    let board = BoardViewModel(store: DumpStore(inMemoryOnly: true))
    let source = [
      CardState(kind: .freehand, x: 0, y: 0, points: CardState.defaultFreehandPoints()),
      CardState(kind: .image, x: 100, y: 100, imagePath: "missing.png"),
    ]
    let ids = board.insertCopies(source, offset: .zero)

    for id in ids {
      board.beginEditing(id)
      XCTAssertNil(board.editingCardID)
    }
  }

  func testSupportedKindStillEntersEditing() throws {
    let board = BoardViewModel(store: DumpStore(inMemoryOnly: true))
    let id = board.addElement(.rectangle, at: .zero)

    board.beginEditing(id)

    XCTAssertEqual(board.editingCardID, id)
    XCTAssertEqual(board.selectedCardIDs, [id])
  }

  func testLockedElementCannotEnterEditing() throws {
    let board = BoardViewModel(store: DumpStore(inMemoryOnly: true))
    let id = board.addElement(.rectangle, at: .zero)
    board.lockSelection(true)

    board.beginEditing(id)

    XCTAssertNil(board.editingCardID)
  }

  func testSelectedConnectorEditAffordanceYieldsToEndpointHandles() {
    XCTAssertTrue(CanvasEditAffordancePolicy.isAvailable(for: .line, whileSelected: false))
    XCTAssertTrue(CanvasEditAffordancePolicy.isAvailable(for: .arrow, whileSelected: false))
    XCTAssertFalse(CanvasEditAffordancePolicy.isAvailable(for: .line, whileSelected: true))
    XCTAssertFalse(CanvasEditAffordancePolicy.isAvailable(for: .arrow, whileSelected: true))
    XCTAssertTrue(CanvasEditAffordancePolicy.isAvailable(for: .rectangle, whileSelected: true))
  }

  func testHoverEditAffordanceHasAUsableScreenSpaceTarget() {
    XCTAssertGreaterThanOrEqual(CanvasEditAffordancePolicy.minimumHitSide, 28)
  }
}
