import XCTest

@testable import ComposerApp

final class ConnectorGeometryTests: XCTestCase {
  func testEndpointDragTranslationIsConvertedFromScreenToBoardAtZoom() {
    let moved = ConnectorEndpointDrag.boardPoint(
      from: CGPoint(x: 80, y: 120),
      translation: CGSize(width: 30, height: -18),
      zoom: 1.5)

    XCTAssertEqual(moved.x, 100, accuracy: 0.001)
    XCTAssertEqual(moved.y, 108, accuracy: 0.001)
  }

  private func shape(_ kind: CanvasElementKind = .rectangle,
                     id: UUID = UUID(),
                     frame: CGRect) -> CardState {
    CardState(
      id: id,
      kind: kind,
      x: frame.minX,
      y: frame.minY,
      w: frame.width,
      h: frame.height)
  }

  private func connector(_ kind: CanvasElementKind = .line,
                         start: CGPoint,
                         end: CGPoint) -> CardState {
    let frame = CGRect(
      x: min(start.x, end.x),
      y: min(start.y, end.y),
      width: max(abs(end.x - start.x), 1),
      height: max(abs(end.y - start.y), 1))
    return CardState(
      kind: kind,
      x: frame.minX,
      y: frame.minY,
      w: frame.width,
      h: frame.height,
      points: [
        CanvasPoint(
          x: Double((start.x - frame.minX) / frame.width),
          y: Double((start.y - frame.minY) / frame.height)),
        CanvasPoint(
          x: Double((end.x - frame.minX) / frame.width),
          y: Double((end.y - frame.minY) / frame.height)),
      ])
  }

  func testMovingOneEndpointPreservesTheOtherInBoardSpace() throws {
    let original = connector(start: CGPoint(x: 40, y: 80), end: CGPoint(x: 260, y: 150))
    let before = try XCTUnwrap(ConnectorGeometry.endpoints(of: original))

    let updated = try XCTUnwrap(ConnectorGeometry.moving(
      .end,
      of: original,
      to: CGPoint(x: 420, y: 310),
      among: [original]))
    let after = try XCTUnwrap(ConnectorGeometry.endpoints(of: updated))

    XCTAssertEqual(after.start.x, before.start.x, accuracy: 0.001)
    XCTAssertEqual(after.start.y, before.start.y, accuracy: 0.001)
    XCTAssertEqual(after.end.x, 420, accuracy: 0.001)
    XCTAssertEqual(after.end.y, 310, accuracy: 0.001)
  }

  func testFreshLineBindsAtBothDrawnEnds() throws {
    let source = shape(frame: CGRect(x: 0, y: 0, width: 120, height: 90))
    let target = shape(frame: CGRect(x: 360, y: 40, width: 120, height: 90))
    let drawn = connector(
      start: CGPoint(x: source.frame.maxX - 2, y: source.frame.midY),
      end: CGPoint(x: target.frame.minX + 2, y: target.frame.midY))

    let bound = try XCTUnwrap(ConnectorGeometry.finalizingDrawn(drawn, among: [source, target, drawn]))

    XCTAssertEqual(bound.startBindingID, source.id)
    XCTAssertEqual(bound.endBindingID, target.id)
    XCTAssertNotNil(bound.startBindingAnchor)
    XCTAssertNotNil(bound.endBindingAnchor)
  }

  func testProgrammaticArrowReservesTipClearanceButLineDoesNot() throws {
    let source = shape(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
    let target = shape(frame: CGRect(x: 300, y: 0, width: 100, height: 100))
    let line = try XCTUnwrap(ConnectorGeometry.makeBoundConnector(
      kind: .line, text: "", source: source, target: target, z: 1, author: nil))
    let arrow = try XCTUnwrap(ConnectorGeometry.makeBoundConnector(
      kind: .arrow, text: "", source: source, target: target, z: 1, author: nil))
    let lineEnds = try XCTUnwrap(ConnectorGeometry.endpoints(of: line))
    let arrowEnds = try XCTUnwrap(ConnectorGeometry.endpoints(of: arrow))

    XCTAssertEqual(lineEnds.start.x, arrowEnds.start.x, accuracy: 0.001)
    XCTAssertEqual(lineEnds.end.x, target.frame.minX - 1, accuracy: 0.001)
    XCTAssertEqual(arrowEnds.end.x, target.frame.minX - 7, accuracy: 0.001)
  }
}

@MainActor
final class ConnectorMutationTests: XCTestCase {
  private func endpoints(_ card: CardState) throws -> ConnectorGeometry.Endpoints {
    try XCTUnwrap(ConnectorGeometry.endpoints(of: card))
  }

  func testLineBindingTracksMovedTarget() throws {
    let board = BoardViewModel(store: DumpStore(inMemoryOnly: true))
    let sourceID = board.addElement(.rectangle, at: CGPoint(x: 200, y: 200))
    let targetID = board.addElement(.ellipse, at: CGPoint(x: 600, y: 200))
    let source = try XCTUnwrap(board.cards.first { $0.id == sourceID })
    let initialTarget = try XCTUnwrap(board.cards.first { $0.id == targetID })
    let lineID = try XCTUnwrap(board.addDrawnElement(
      .line,
      from: CGPoint(x: source.frame.maxX - 2, y: source.frame.midY),
      to: CGPoint(x: initialTarget.frame.minX + 2, y: initialTarget.frame.midY)))
    let before = try endpoints(try XCTUnwrap(board.cards.first { $0.id == lineID }))
    let target = try XCTUnwrap(board.cards.first { $0.id == targetID })

    board.setFrame(targetID, target.frame.offsetBy(dx: 90, dy: 70))

    let after = try endpoints(try XCTUnwrap(board.cards.first { $0.id == lineID }))
    XCTAssertEqual(after.end.x - before.end.x, 90, accuracy: 0.001)
    XCTAssertEqual(after.end.y - before.end.y, 70, accuracy: 0.001)
  }

  func testEndpointMutationRebindsOnlyMovedEndAndUndoesOnce() throws {
    let board = BoardViewModel(store: DumpStore(inMemoryOnly: true))
    let sourceID = board.addElement(.rectangle, at: CGPoint(x: 200, y: 200))
    let firstTargetID = board.addElement(.ellipse, at: CGPoint(x: 600, y: 200))
    let nextTargetID = board.addElement(.diamond, at: CGPoint(x: 600, y: 500))
    let connectorID = try XCTUnwrap(board.connectCards(from: sourceID, to: firstTargetID, kind: .arrow))
    let original = try XCTUnwrap(board.cards.first { $0.id == connectorID })
    let originalEndpoints = try endpoints(original)
    let nextTarget = try XCTUnwrap(board.cards.first { $0.id == nextTargetID })

    XCTAssertTrue(board.setConnectorEndpoint(.end, of: connectorID, to: CGPoint(
      x: nextTarget.frame.minX + 4,
      y: nextTarget.frame.midY)))

    let changed = try XCTUnwrap(board.cards.first { $0.id == connectorID })
    let changedEndpoints = try endpoints(changed)
    XCTAssertEqual(changed.startBindingID, sourceID)
    XCTAssertEqual(changed.endBindingID, nextTargetID)
    // The old anchor-less center route freezes to the same boundary spot when endpoint editing
    // begins. Its former 1pt outside margin collapses onto that boundary, but the handle does not
    // jump to another side of the source card as the segment direction changes.
    XCTAssertEqual(changedEndpoints.start.x, originalEndpoints.start.x, accuracy: 1.01)
    XCTAssertEqual(changedEndpoints.start.y, originalEndpoints.start.y, accuracy: 1.01)

    board.undo()
    XCTAssertEqual(board.cards.first { $0.id == connectorID }, original)
  }

  func testEndpointMutationDetachesWhenDroppedOnEmptyBoard() throws {
    let board = BoardViewModel(store: DumpStore(inMemoryOnly: true))
    let sourceID = board.addElement(.rectangle, at: CGPoint(x: 200, y: 200))
    let targetID = board.addElement(.ellipse, at: CGPoint(x: 600, y: 200))
    let connectorID = try XCTUnwrap(board.connectCards(from: sourceID, to: targetID, kind: .line))

    XCTAssertTrue(board.setConnectorEndpoint(.end, of: connectorID, to: CGPoint(x: 900, y: 700)))

    let changed = try XCTUnwrap(board.cards.first { $0.id == connectorID })
    XCTAssertEqual(changed.startBindingID, sourceID)
    XCTAssertNil(changed.endBindingID)
    XCTAssertNil(changed.endBindingAnchor)
  }
}
