import XCTest
@testable import ComposerApp

final class CanvasDrawingDraftStateTests: XCTestCase {
  func testBoardReplacementCancelsCommitReadyPenAndOtherDrawingDrafts() throws {
    var pen = VectorPathDraft()
    XCTAssertNil(pen.finish(
      anchor: CGPoint(x: 10, y: 20),
      drag: CGPoint(x: 10, y: 20),
      closeTolerance: 8))
    XCTAssertNil(pen.finish(
      anchor: CGPoint(x: 120, y: 90),
      drag: CGPoint(x: 140, y: 100),
      closeTolerance: 8))
    XCTAssertNotNil(pen.commitOpen(), "The outgoing-board draft must be capable of committing")

    var state = CanvasDrawingDraftState(
      freehand: [CGPoint(x: 1, y: 2), CGPoint(x: 3, y: 4)],
      vector: pen,
      element: DragSegment(start: .zero, end: CGPoint(x: 40, y: 50)),
      bindTargetID: UUID())
    XCTAssertTrue(state.hasDraft)

    state.cancelForBoardReplacement()

    XCTAssertFalse(state.hasDraft)
    XCTAssertNil(state.freehand)
    XCTAssertNil(state.vector, "A path begun on board A must not survive to commit on board B")
    XCTAssertNil(state.element)
    XCTAssertNil(state.bindTargetID)
  }
}
