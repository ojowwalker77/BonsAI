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

    for mode in [
      CanvasViewportDragMode.placing, .drawing, .vectorPress, .vectorDrawing,
    ] {
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

  func testClickCreatedVectorNodeFreezesScrollFromMouseDownThroughMouseUp() {
    let mode = CanvasPointerPressMode.resolve(tool: .vectorPen, isSpacePressed: false)
    var pan = CGSize(width: 37, height: -12)

    if CanvasViewportTransformPolicy.allowsPanOrZoom(during: mode) {
      pan.width += 24
    }

    XCTAssertEqual(mode, .vectorPress)
    XCTAssertEqual(pan, CGSize(width: 37, height: -12))
    XCTAssertEqual(
      CanvasPointerPressMode.resolve(tool: .vectorPen, isSpacePressed: true),
      .panning,
      "Space-pan must retain pointer ownership over the selected drawing tool")
  }

  @MainActor
  func testQueuedViewportCallbacksAreDroppedWhenVectorPressBegins() async {
    let throttle = ViewportEventThrottle()
    var mode = CanvasViewportDragMode.maybeTap
    var appliedScroll: CGSize?
    var appliedZoom: (CGFloat, CGPoint)?
    let canApply = { CanvasViewportTransformPolicy.allowsPanOrZoom(during: mode) }

    throttle.enqueueScroll(CGSize(width: 10, height: -4), canApply: canApply) {
      appliedScroll = $0
    }
    throttle.enqueueZoom(1.2, anchoredAt: CGPoint(x: 40, y: 60), canApply: canApply) {
      appliedZoom = ($0, $1)
    }

    // Model the mouse-down that arrives after the events were accepted but before their throttled
    // callbacks run. Both callbacks must re-check the now-frozen pointer mode.
    mode = CanvasPointerPressMode.resolve(tool: .vectorPen, isSpacePressed: false)
    try? await Task.sleep(nanoseconds: 30_000_000)

    XCTAssertNil(appliedScroll)
    XCTAssertNil(appliedZoom)

    // Positive control: prove the delayed callback actually runs once pointer ownership is
    // released, so the nil assertions above cannot pass merely because the throttle never fired.
    mode = .maybeTap
    throttle.enqueueScroll(CGSize(width: 5, height: 5), canApply: canApply) {
      appliedScroll = $0
    }
    try? await Task.sleep(nanoseconds: 30_000_000)
    XCTAssertEqual(appliedScroll, CGSize(width: 5, height: 5))
  }
}
