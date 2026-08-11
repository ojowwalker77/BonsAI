import XCTest
@testable import ComposerApp

@MainActor
final class QuickCaptureTests: XCTestCase {
  func testCaptureLandsBesideTheActiveCardInsteadOfBelowTheWholeBoard() throws {
    let board = makeBoard()
    let anchorID = try XCTUnwrap(board.cards.first?.id)
    let anchorFrame = CGRect(x: 980, y: 720, width: 360, height: 72)
    board.setText(anchorID, "Active thought")
    board.setFrame(anchorID, anchorFrame)
    board.beginEditing(anchorID)

    let capturedID = try XCTUnwrap(board.captureExternalText("Captured nearby"))
    let captured = try XCTUnwrap(board.cards.first(where: { $0.id == capturedID }))

    XCTAssertEqual(captured.frame.minX, anchorFrame.minX, accuracy: 0.5)
    XCTAssertGreaterThanOrEqual(captured.frame.minY, anchorFrame.maxY + 35.5)
    XCTAssertEqual(board.primarySelectedCardID, capturedID)
    XCTAssertEqual(board.editingCardID, capturedID)
  }

  func testCaptureUsesViewportContextWhenThereIsNoActiveCard() throws {
    let board = makeBoard()
    let existingID = try XCTUnwrap(board.cards.first?.id)
    board.setText(existingID, "Existing")
    board.setFrame(existingID, CGRect(x: 80, y: 80, width: 360, height: 60))
    board.deselectAll()
    let activeBoardPoint = CGPoint(x: 1_400, y: 900)

    let capturedID = try XCTUnwrap(
      board.captureExternalText("Captured in view", around: activeBoardPoint))
    let captured = try XCTUnwrap(board.cards.first(where: { $0.id == capturedID }))

    XCTAssertEqual(captured.frame.midX, activeBoardPoint.x, accuracy: 0.5)
    XCTAssertEqual(captured.frame.midY, activeBoardPoint.y, accuracy: 0.5)
  }

  func testContextualCaptureSkipsAnOccupiedNearbySlot() throws {
    let board = makeBoard()
    let anchorID = try XCTUnwrap(board.cards.first?.id)
    let anchorFrame = CGRect(x: 600, y: 500, width: 360, height: 60)
    board.setText(anchorID, "Anchor")
    board.setFrame(anchorID, anchorFrame)

    let blockerID = board.insertText("Blocker", at: CGPoint(x: 500, y: anchorFrame.maxY + 8))
    let blockerFrame = CGRect(x: 500, y: anchorFrame.maxY + 8, width: 560, height: 320)
    board.setFrame(blockerID, blockerFrame)
    board.select(anchorID)

    let capturedID = try XCTUnwrap(board.captureExternalText("Find a clear place"))
    let captured = try XCTUnwrap(board.cards.first(where: { $0.id == capturedID }))

    XCTAssertFalse(captured.frame.intersects(anchorFrame))
    XCTAssertFalse(captured.frame.intersects(blockerFrame))
  }

  func testRevealMinimallyPansAnOffscreenCaptureIntoView() throws {
    let session = makeSession()
    let cardID = try XCTUnwrap(session.board.cards.first?.id)
    session.board.setFrame(cardID, CGRect(x: 1_200, y: 850, width: 360, height: 80))
    session.scale = 1.25
    session.pan = CGSize(width: -40, height: 25)
    let viewport = CGSize(width: 800, height: 600)

    XCTAssertTrue(session.revealCard(cardID, in: viewport))

    let frame = try XCTUnwrap(session.board.cards.first(where: { $0.id == cardID })?.frame)
    let rendered = CGRect(
      x: frame.minX * session.scale + session.pan.width,
      y: frame.minY * session.scale + session.pan.height,
      width: frame.width * session.scale,
      height: frame.height * session.scale)
    XCTAssertGreaterThanOrEqual(rendered.minX, 47.5)
    XCTAssertLessThanOrEqual(rendered.maxX, viewport.width - 47.5)
    XCTAssertGreaterThanOrEqual(rendered.minY, 47.5)
    XCTAssertLessThanOrEqual(rendered.maxY, viewport.height - 47.5)
  }

  func testRevealDoesNotMoveAnAlreadyVisibleCapture() throws {
    let session = makeSession()
    let cardID = try XCTUnwrap(session.board.cards.first?.id)
    session.board.setFrame(cardID, CGRect(x: 100, y: 120, width: 360, height: 80))
    session.pan = CGSize(width: 12, height: -8)
    let originalPan = session.pan

    XCTAssertFalse(session.revealCard(cardID, in: CGSize(width: 800, height: 600)))
    XCTAssertEqual(session.pan, originalPan)
  }

  func testRevealUsesTheEditorsLiveFrame() throws {
    let session = makeSession()
    let cardID = try XCTUnwrap(session.board.cards.first?.id)
    session.board.setText(cardID, "Growing capture")
    session.board.setFrame(cardID, CGRect(x: 100, y: 70, width: 360, height: 60))
    session.board.beginEditing(cardID)
    let liveFrame = try XCTUnwrap(session.board.fitTextEditing(
      cardID,
      naturalEditorWidth: 300,
      editorContentHeight: 500))
    let viewport = CGSize(width: 800, height: 300)

    XCTAssertTrue(session.revealCard(cardID, in: viewport))

    let renderedMidY = liveFrame.midY * session.scale + session.pan.height
    XCTAssertEqual(renderedMidY, viewport.height / 2, accuracy: 0.5)
  }

  func testRevealIncludesAnInFlightPanGesture() throws {
    let session = makeSession()
    let cardID = try XCTUnwrap(session.board.cards.first?.id)
    session.board.setFrame(cardID, CGRect(x: 900, y: 100, width: 360, height: 80))
    let originalPan = session.pan

    XCTAssertFalse(session.revealCard(
      cardID,
      in: CGSize(width: 800, height: 600),
      transientPan: CGSize(width: -700, height: 0)))
    XCTAssertEqual(session.pan, originalPan)
  }

  private func makeBoard() -> BoardViewModel {
    BoardViewModel(store: DumpStore(inMemoryOnly: true, loadInitialContent: false))
  }

  private func makeSession() -> CanvasWorkspaceSession {
    CanvasWorkspaceSession(
      store: DumpStore(inMemoryOnly: true, loadInitialContent: false))
  }
}
