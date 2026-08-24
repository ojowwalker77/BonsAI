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
}
