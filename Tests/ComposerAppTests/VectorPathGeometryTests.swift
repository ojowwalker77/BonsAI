import XCTest
@testable import ComposerApp

final class VectorPathGeometryTests: XCTestCase {
  func testClickCreatesCornerAndDragCreatesSymmetricSmoothNode() throws {
    var draft = VectorPathDraft()
    XCTAssertNil(draft.finish(anchor: CGPoint(x: 10, y: 20), drag: CGPoint(x: 10, y: 20), closeTolerance: 8))
    draft.update(anchor: CGPoint(x: 80, y: 50), drag: CGPoint(x: 105, y: 65))
    XCTAssertNil(draft.finish(anchor: CGPoint(x: 80, y: 50), drag: CGPoint(x: 105, y: 65), closeTolerance: 8))

    let placement = try XCTUnwrap(draft.commitOpen())
    XCTAssertNil(placement.spec.nodes[0].incoming)
    XCTAssertNil(placement.spec.nodes[0].outgoing)
    let anchor = try XCTUnwrap(VectorPathGeometry.controlPoint(.anchor, nodeAt: 1, in: placement.spec, frame: placement.frame))
    let incoming = try XCTUnwrap(VectorPathGeometry.controlPoint(.incoming, nodeAt: 1, in: placement.spec, frame: placement.frame))
    let outgoing = try XCTUnwrap(VectorPathGeometry.controlPoint(.outgoing, nodeAt: 1, in: placement.spec, frame: placement.frame))
    XCTAssertEqual(incoming.x + outgoing.x, anchor.x * 2, accuracy: 0.001)
    XCTAssertEqual(incoming.y + outgoing.y, anchor.y * 2, accuracy: 0.001)
  }

  func testOpenCommitNeedsTwoNodesAndFirstNodeClickClosesThree() throws {
    var draft = VectorPathDraft()
    XCTAssertNil(draft.finish(anchor: CGPoint(x: 10, y: 10), drag: CGPoint(x: 10, y: 10), closeTolerance: 8))
    XCTAssertNil(draft.commitOpen())
    XCTAssertNil(draft.finish(anchor: CGPoint(x: 100, y: 10), drag: CGPoint(x: 100, y: 10), closeTolerance: 8))
    XCTAssertFalse(try XCTUnwrap(draft.commitOpen()).spec.isClosed)
    XCTAssertNil(draft.finish(anchor: CGPoint(x: 100, y: 90), drag: CGPoint(x: 100, y: 90), closeTolerance: 8))

    let closed = try XCTUnwrap(draft.finish(
      anchor: CGPoint(x: 13, y: 12), drag: CGPoint(x: 13, y: 12), closeTolerance: 8))
    XCTAssertTrue(closed.spec.isClosed)
    XCTAssertEqual(closed.spec.nodes.count, 3)
  }

  func testHoverRubberBandsFromLastCommittedNode() {
    var draft = VectorPathDraft()
    XCTAssertNil(draft.finish(anchor: CGPoint(x: 20, y: 30), drag: CGPoint(x: 20, y: 30), closeTolerance: 8))
    draft.hover(at: CGPoint(x: 90, y: 75))

    XCTAssertEqual(draft.previewPath.currentPoint.x, 90, accuracy: 0.001)
    XCTAssertEqual(draft.previewPath.currentPoint.y, 75, accuracy: 0.001)
    XCTAssertEqual(draft.anchorPoints.last, CGPoint(x: 90, y: 75))

    draft.hover(at: nil)
    XCTAssertEqual(draft.previewPath.currentPoint.x, 20, accuracy: 0.001)
    XCTAssertEqual(draft.previewPath.currentPoint.y, 30, accuracy: 0.001)
  }

  func testPlacementNormalizesEveryAnchorAndHandle() throws {
    var draft = VectorPathDraft()
    XCTAssertNil(draft.finish(anchor: CGPoint(x: -40, y: 12), drag: CGPoint(x: -55, y: 30), closeTolerance: 8))
    XCTAssertNil(draft.finish(anchor: CGPoint(x: 130, y: 95), drag: CGPoint(x: 165, y: 70), closeTolerance: 8))
    let placement = try XCTUnwrap(draft.commitOpen())

    for node in placement.spec.nodes {
      for point in [node.anchor, node.incoming, node.outgoing].compactMap({ $0 }) {
        XCTAssertTrue((0...1).contains(point.x))
        XCTAssertTrue((0...1).contains(point.y))
      }
    }
  }

  func testHandleEditRemainsSymmetricAndRefitsWithoutMovingOtherAnchor() throws {
    var draft = VectorPathDraft()
    XCTAssertNil(draft.finish(anchor: CGPoint(x: 0, y: 0), drag: CGPoint(x: 0, y: 0), closeTolerance: 8))
    XCTAssertNil(draft.finish(anchor: CGPoint(x: 100, y: 80), drag: CGPoint(x: 120, y: 95), closeTolerance: 8))
    let initial = try XCTUnwrap(draft.commitOpen())
    let firstBefore = try XCTUnwrap(VectorPathGeometry.controlPoint(.anchor, nodeAt: 0, in: initial.spec, frame: initial.frame))

    let moved = try XCTUnwrap(VectorPathGeometry.moving(
      .outgoing, nodeAt: 1, by: CGSize(width: 30, height: -12), in: initial.spec, frame: initial.frame))
    let firstAfter = try XCTUnwrap(VectorPathGeometry.controlPoint(.anchor, nodeAt: 0, in: moved.spec, frame: moved.frame))
    let anchor = try XCTUnwrap(VectorPathGeometry.controlPoint(.anchor, nodeAt: 1, in: moved.spec, frame: moved.frame))
    let incoming = try XCTUnwrap(VectorPathGeometry.controlPoint(.incoming, nodeAt: 1, in: moved.spec, frame: moved.frame))
    let outgoing = try XCTUnwrap(VectorPathGeometry.controlPoint(.outgoing, nodeAt: 1, in: moved.spec, frame: moved.frame))
    XCTAssertEqual(firstAfter.x, firstBefore.x, accuracy: 0.001)
    XCTAssertEqual(firstAfter.y, firstBefore.y, accuracy: 0.001)
    XCTAssertEqual(incoming.x + outgoing.x, anchor.x * 2, accuracy: 0.001)
    XCTAssertEqual(incoming.y + outgoing.y, anchor.y * 2, accuracy: 0.001)
  }

  func testMissingClosedFlagDecodesAsOpen() throws {
    let data = Data(#"{"nodes":[]}"#.utf8)
    XCTAssertFalse(try JSONDecoder().decode(VectorPathSpec.self, from: data).isClosed)
  }
}

@MainActor
final class VectorPathBoardTests: XCTestCase {
  func testPlacementUsesCurrentTintAndUndoesAsOneInsertion() throws {
    var draft = VectorPathDraft()
    XCTAssertNil(draft.finish(anchor: CGPoint(x: 10, y: 20), drag: CGPoint(x: 10, y: 20), closeTolerance: 8))
    XCTAssertNil(draft.finish(anchor: CGPoint(x: 150, y: 90), drag: CGPoint(x: 170, y: 100), closeTolerance: 8))
    let placement = try XCTUnwrap(draft.commitOpen())
    let board = BoardViewModel(store: DumpStore(inMemoryOnly: true))
    board.currentTint = 2

    let id = try XCTUnwrap(board.addVectorPath(placement))

    let card = try XCTUnwrap(board.cards.first(where: { $0.id == id }))
    XCTAssertEqual(card.elementKind, .vectorPath)
    XCTAssertEqual(card.vectorPath, placement.spec)
    XCTAssertEqual(card.tint, 2)
    XCTAssertEqual(board.selectedCardIDs, [id])
    board.undo()
    XCTAssertFalse(board.cards.contains(where: { $0.id == id }))
  }

  func testCompletedNodeGestureIsOneUndoStep() throws {
    var draft = VectorPathDraft()
    XCTAssertNil(draft.finish(anchor: CGPoint(x: 10, y: 20), drag: CGPoint(x: 10, y: 20), closeTolerance: 8))
    XCTAssertNil(draft.finish(anchor: CGPoint(x: 150, y: 90), drag: CGPoint(x: 170, y: 100), closeTolerance: 8))
    let board = BoardViewModel(store: DumpStore(inMemoryOnly: true))
    let id = try XCTUnwrap(board.addVectorPath(try XCTUnwrap(draft.commitOpen())))
    let before = try XCTUnwrap(board.cards.first(where: { $0.id == id }))
    board.beginEditing(id)
    let moved = try XCTUnwrap(VectorPathGeometry.moving(
      .anchor,
      nodeAt: 0,
      by: CGSize(width: 35, height: -18),
      in: try XCTUnwrap(before.vectorPath),
      frame: before.frame))

    XCTAssertTrue(board.setVectorPath(id, placement: moved))
    XCTAssertNotEqual(board.cards.first(where: { $0.id == id }), before)

    board.undo()
    XCTAssertEqual(board.cards.first(where: { $0.id == id }), before)
    board.undo()
    XCTAssertFalse(board.cards.contains(where: { $0.id == id }))
  }

  func testZoomedAnchorPreviewPlacementEqualsCommittedPlacement() throws {
    let (board, id, before) = try makeEditingVectorBoard()
    let spec = try XCTUnwrap(before.vectorPath)
    let anchorBefore = try XCTUnwrap(VectorPathGeometry.controlPoint(
      .anchor, nodeAt: 0, in: spec, frame: before.frame))
    let screenTranslation = CGSize(width: 55, height: -30)
    let zoom: CGFloat = 2.5
    let preview = try XCTUnwrap(VectorPathControlDrag.placement(
      .anchor,
      nodeAt: 0,
      screenTranslation: screenTranslation,
      zoom: zoom,
      in: spec,
      frame: before.frame))

    XCTAssertTrue(board.setVectorPath(id, placement: preview))
    let committed = try XCTUnwrap(board.cards.first(where: { $0.id == id }))
    XCTAssertEqual(committed.frame, preview.frame)
    XCTAssertEqual(committed.vectorPath, preview.spec)
    let anchorAfter = try XCTUnwrap(VectorPathGeometry.controlPoint(
      .anchor, nodeAt: 0, in: preview.spec, frame: preview.frame))
    let boardTranslation = VectorPathControlDrag.boardTranslation(
      from: screenTranslation, zoom: zoom)
    XCTAssertEqual(anchorAfter.x, anchorBefore.x + boardTranslation.width, accuracy: 0.001)
    XCTAssertEqual(anchorAfter.y, anchorBefore.y + boardTranslation.height, accuracy: 0.001)
  }

  func testZoomedHandlePreviewPlacementEqualsCommittedPlacement() throws {
    let (board, id, before) = try makeEditingVectorBoard()
    let spec = try XCTUnwrap(before.vectorPath)
    let handleBefore = try XCTUnwrap(VectorPathGeometry.controlPoint(
      .outgoing, nodeAt: 1, in: spec, frame: before.frame))
    let screenTranslation = CGSize(width: -36, height: 63)
    let zoom: CGFloat = 1.8
    let preview = try XCTUnwrap(VectorPathControlDrag.placement(
      .outgoing,
      nodeAt: 1,
      screenTranslation: screenTranslation,
      zoom: zoom,
      in: spec,
      frame: before.frame))

    XCTAssertTrue(board.setVectorPath(id, placement: preview))
    let committed = try XCTUnwrap(board.cards.first(where: { $0.id == id }))
    XCTAssertEqual(committed.frame, preview.frame)
    XCTAssertEqual(committed.vectorPath, preview.spec)
    let handleAfter = try XCTUnwrap(VectorPathGeometry.controlPoint(
      .outgoing, nodeAt: 1, in: preview.spec, frame: preview.frame))
    let boardTranslation = VectorPathControlDrag.boardTranslation(
      from: screenTranslation, zoom: zoom)
    XCTAssertEqual(handleAfter.x, handleBefore.x + boardTranslation.width, accuracy: 0.001)
    XCTAssertEqual(handleAfter.y, handleBefore.y + boardTranslation.height, accuracy: 0.001)
  }

  func testZeroMotionControlClickDoesNotRefitOrAddUndo() throws {
    // Deliberately loose legacy/import geometry: refitting these reviewer coordinates would change
    // both frame and normalization even though a control click has no pointer translation.
    let original = VectorPathPlacement(
      frame: CGRect(x: 37, y: 91, width: 311, height: 173),
      spec: VectorPathSpec(nodes: [
        VectorPathNode(anchor: CanvasPoint(x: 0.19, y: 0.28)),
        VectorPathNode(
          anchor: CanvasPoint(x: 0.76, y: 0.67),
          incoming: CanvasPoint(x: 0.62, y: 0.49),
          outgoing: CanvasPoint(x: 0.90, y: 0.85)),
      ]))
    let board = BoardViewModel(store: DumpStore(inMemoryOnly: true))
    let id = try XCTUnwrap(board.addVectorPath(original))
    let before = try XCTUnwrap(board.cards.first(where: { $0.id == id }))

    let clickPlacement = VectorPathControlDrag.placement(
      .anchor,
      nodeAt: 0,
      screenTranslation: .zero,
      zoom: 2.25,
      in: try XCTUnwrap(before.vectorPath),
      frame: before.frame)

    XCTAssertNil(clickPlacement)
    XCTAssertNil(VectorPathControlDrag.placement(
      .anchor,
      nodeAt: 0,
      screenTranslation: CGSize(width: 0.3, height: -0.4),
      zoom: 2.25,
      in: try XCTUnwrap(before.vectorPath),
      frame: before.frame),
      "subpixel pointer jitter must behave like a bare click")
    XCTAssertEqual(board.cards.first(where: { $0.id == id }), before)
    board.undo()
    XCTAssertFalse(
      board.cards.contains(where: { $0.id == id }),
      "one undo must remove the insertion; a zero-motion click must not add an undo checkpoint")
  }

  func testLockedVectorRejectsGeometryAndTintWithoutAddingUndo() throws {
    let (board, id, _) = try makeEditingVectorBoard()
    board.lockSelection(true)
    let locked = try XCTUnwrap(board.cards.first(where: { $0.id == id }))
    let spec = try XCTUnwrap(locked.vectorPath)
    let moved = try XCTUnwrap(VectorPathControlDrag.placement(
      .anchor,
      nodeAt: 0,
      screenTranslation: CGSize(width: 30, height: -18),
      zoom: 1.5,
      in: spec,
      frame: locked.frame))

    XCTAssertFalse(board.setVectorPath(id, placement: moved))
    board.setTint(3, for: id)
    board.setTintForSelection(2)
    XCTAssertEqual(board.cards.first(where: { $0.id == id }), locked)

    board.undo()
    let unlocked = try XCTUnwrap(board.cards.first(where: { $0.id == id }))
    XCTAssertFalse(unlocked.locked, "one undo must reach the lock action; rejected edits add none")
    XCTAssertEqual(unlocked.frame, locked.frame)
    XCTAssertEqual(unlocked.vectorPath, locked.vectorPath)
    XCTAssertEqual(unlocked.tint, locked.tint)
  }

  private func makeEditingVectorBoard() throws -> (BoardViewModel, UUID, CardState) {
    var draft = VectorPathDraft()
    XCTAssertNil(draft.finish(
      anchor: CGPoint(x: 10, y: 20),
      drag: CGPoint(x: 10, y: 20),
      closeTolerance: 8))
    XCTAssertNil(draft.finish(
      anchor: CGPoint(x: 150, y: 90),
      drag: CGPoint(x: 170, y: 100),
      closeTolerance: 8))
    let board = BoardViewModel(store: DumpStore(inMemoryOnly: true))
    let id = try XCTUnwrap(board.addVectorPath(try XCTUnwrap(draft.commitOpen())))
    board.beginEditing(id)
    return (board, id, try XCTUnwrap(board.cards.first(where: { $0.id == id })))
  }
}
