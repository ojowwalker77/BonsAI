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

  func testLiveDrawingModesFreezeViewportTransform() {
    let originalScale: CGFloat = 1.75
    let originalPan = CGSize(width: 92, height: -41)

    for mode in [CanvasViewportDragMode.placing, .drawing, .vectorDrawing] {
      var scale = originalScale
      var pan = originalPan
      if CanvasViewportTransformPolicy.allowsPanOrZoom(during: mode) {
        scale *= 1.2
        pan.width += 25
      }
      XCTAssertEqual(scale, originalScale, "\(mode) must suppress pinch zoom")
      XCTAssertEqual(pan, originalPan, "\(mode) must suppress scroll pan")
    }

    XCTAssertTrue(CanvasViewportTransformPolicy.allowsPanOrZoom(during: .maybeTap))
    XCTAssertTrue(CanvasViewportTransformPolicy.allowsPanOrZoom(during: .selecting))
    XCTAssertTrue(CanvasViewportTransformPolicy.allowsPanOrZoom(during: .panning))
  }
}
