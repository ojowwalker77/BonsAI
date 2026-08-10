import XCTest
@testable import ComposerApp

@MainActor
final class CanvasWorkspaceSessionTests: XCTestCase {
  func testAgentDraftBelongsToRemountStableWorkspaceSession() {
    let session = CanvasWorkspaceSession(
      store: DumpStore(inMemoryOnly: true, loadInitialContent: false)
    )
    session.agentDraft = "Keep this unsent prompt"

    session.prepareForRemount(.theme)

    XCTAssertEqual(session.agentDraft, "Keep this unsent prompt")
  }

  func testEveryFullRemountFlushesLatestBoardAndRetainsIdentityHistoryAndViewport() async throws {
    for trigger in CanvasRemountTrigger.allCases {
      let store = DumpStore(inMemoryOnly: true, loadInitialContent: false)
      let session = CanvasWorkspaceSession(store: store)
      let board = session.board
      let boardIdentity = ObjectIdentifier(board)
      let card = try XCTUnwrap(board.cards.first)
      let originalFrame = card.frame
      let latestFrame = CGRect(
        x: originalFrame.minX + 73,
        y: originalFrame.minY + 41,
        width: originalFrame.width + 29,
        height: originalFrame.height + 17
      )

      board.setText(card.id, "Latest edit before \(trigger)")
      board.setFrame(card.id, latestFrame)
      session.scale = 1.42
      session.pan = CGSize(width: 91, height: -37)

      // Both edits are still inside the 400 ms debounce window.
      XCTAssertNotEqual(store.currentCards.first?.text, "Latest edit before \(trigger)")

      session.prepareForRemount(trigger)

      XCTAssertEqual(ObjectIdentifier(session.board), boardIdentity)
      XCTAssertEqual(session.lastRemountTrigger, trigger)
      XCTAssertEqual(session.scale, 1.42)
      XCTAssertEqual(session.pan, CGSize(width: 91, height: -37))
      XCTAssertEqual(store.currentCards.first?.text, "Latest edit before \(trigger)")
      XCTAssertEqual(store.currentCards.first?.frame, latestFrame)

      let bridgeNode = try XCTUnwrap(CanvasBridge.shared.snapshot().nodes.first)
      XCTAssertEqual(bridgeNode.text, "Latest edit before \(trigger)")
      XCTAssertEqual(bridgeNode.x, latestFrame.minX)
      XCTAssertEqual(bridgeNode.y, latestFrame.minY)

      // The cancelled debounce must not perform a second write after the synchronous flush.
      let flushedAt = try XCTUnwrap(store.current).updatedAt
      try await Task.sleep(nanoseconds: 500_000_000)
      XCTAssertEqual(try XCTUnwrap(store.current).updatedAt, flushedAt)

      // The same model still owns both checkpoints: geometry first, then text.
      board.undo()
      XCTAssertNotEqual(board.cards.first?.frame, latestFrame)
      XCTAssertEqual(board.cards.first.map(board.plainText(for:)), "Latest edit before \(trigger)")
      board.undo()
      XCTAssertEqual(board.cards.first?.frame, originalFrame)
      XCTAssertEqual(board.cards.first.map(board.plainText(for:)), card.text)
      board.redo()
      board.redo()
      XCTAssertEqual(board.cards.first?.frame, latestFrame)
      XCTAssertEqual(board.cards.first.map(board.plainText(for:)), "Latest edit before \(trigger)")
    }
  }

  func testRemountFlushCannotOverwriteAnUnreadableProtectedPayload() throws {
    let store = DumpStore(inMemoryOnly: true, loadInitialContent: false)
    let dump = try XCTUnwrap(store.current)
    let unreadable = Data(#"{"cards":["#.utf8)
    dump.cardsData = unreadable
    dump.text = ""
    try store.container.mainContext.save()

    let session = CanvasWorkspaceSession(store: store)
    let cardID = try XCTUnwrap(session.board.cards.first?.id)
    session.board.setText(cardID, "Visible recovery edit")

    session.prepareForRemount(.theme)

    XCTAssertEqual(dump.cardsData, unreadable)
    XCTAssertEqual(store.recoveryData(for: dump), unreadable)
    XCTAssertNotNil(store.currentBoardProtection)
  }
}
