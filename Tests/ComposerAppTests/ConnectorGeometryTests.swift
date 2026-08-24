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

  func testDirectionalPeerFrameKeepsDeterministicEdgeGap() {
    let source = CGRect(x: 100, y: 200, width: 180, height: 100)
    let peer = ConnectorGeometry.peerFrame(
      from: source,
      peerSize: CGSize(width: 120, height: 80),
      direction: .left)

    XCTAssertEqual(source.minX - peer.maxX, 96, accuracy: 0.001)
    XCTAssertEqual(peer.midY, source.midY, accuracy: 0.001)
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

  func testQuickConnectCreatesSameKindPeerAndBoundArrowInOneUndo() throws {
    let board = BoardViewModel(store: DumpStore(inMemoryOnly: true))
    let sourceID = board.addElement(.diamond, at: CGPoint(x: 300, y: 300))
    let source = try XCTUnwrap(board.cards.first { $0.id == sourceID })
    let before = board.cards

    let result = try XCTUnwrap(board.quickConnect(from: sourceID, direction: .right))
    let peer = try XCTUnwrap(board.cards.first { $0.id == result.targetID })
    let connector = try XCTUnwrap(board.cards.first { $0.id == result.connectorID })

    XCTAssertTrue(result.createdPeer)
    XCTAssertEqual(peer.elementKind, .diamond)
    XCTAssertEqual(peer.frame.minX - source.frame.maxX, 96, accuracy: 0.001)
    XCTAssertEqual(peer.frame.midY, source.frame.midY, accuracy: 0.001)
    XCTAssertEqual(connector.elementKind, .arrow)
    XCTAssertEqual(connector.startBindingID, sourceID)
    XCTAssertEqual(connector.endBindingID, peer.id)

    board.undo()
    XCTAssertEqual(board.cards, before)
  }

  func testQuickConnectCanUseLineAndExistingTargetWithoutCreatingPeer() throws {
    let board = BoardViewModel(store: DumpStore(inMemoryOnly: true))
    let sourceID = board.addElement(.rectangle, at: CGPoint(x: 200, y: 200))
    let targetID = board.addElement(.ellipse, at: CGPoint(x: 600, y: 200))
    let countBefore = board.cards.count

    let result = try XCTUnwrap(board.quickConnect(
      from: sourceID,
      direction: .right,
      kind: .line,
      to: targetID))
    let connector = try XCTUnwrap(board.cards.first { $0.id == result.connectorID })

    XCTAssertFalse(result.createdPeer)
    XCTAssertEqual(board.cards.count, countBefore + 1)
    XCTAssertEqual(connector.elementKind, .line)
    XCTAssertEqual(connector.startBindingID, sourceID)
    XCTAssertEqual(connector.endBindingID, targetID)
  }

  func testQuickConnectedArrowTracksPeerMovement() throws {
    let board = BoardViewModel(store: DumpStore(inMemoryOnly: true))
    let sourceID = board.addElement(.rectangle, at: CGPoint(x: 200, y: 200))
    let result = try XCTUnwrap(board.quickConnect(from: sourceID, direction: .down))
    let before = try endpoints(try XCTUnwrap(board.cards.first { $0.id == result.connectorID }))
    let peer = try XCTUnwrap(board.cards.first { $0.id == result.targetID })

    let movedPeerFrame = peer.frame.offsetBy(dx: 55, dy: 30)
    board.setFrame(result.targetID, movedPeerFrame)

    let movedConnector = try XCTUnwrap(board.cards.first { $0.id == result.connectorID })
    let after = try endpoints(movedConnector)
    let dx = max(movedPeerFrame.minX - after.end.x, after.end.x - movedPeerFrame.maxX, 0)
    let dy = max(movedPeerFrame.minY - after.end.y, after.end.y - movedPeerFrame.maxY, 0)
    XCTAssertEqual(movedConnector.endBindingID, result.targetID)
    XCTAssertNotEqual(after.end, before.end)
    XCTAssertEqual(hypot(dx, dy), 7, accuracy: 0.2)
  }

  func testQuickConnectRejectsLockedSource() {
    let board = BoardViewModel(store: DumpStore(inMemoryOnly: true))
    let sourceID = board.addElement(.rectangle, at: CGPoint(x: 200, y: 200))
    board.lockSelection(true)

    XCTAssertNil(board.quickConnect(from: sourceID, direction: .down))
  }
}
