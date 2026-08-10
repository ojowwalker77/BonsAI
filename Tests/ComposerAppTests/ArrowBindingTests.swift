import XCTest
@testable import ComposerApp

/// Arrows must land where they were drawn (1.4.5 feedback: the old center-ray re-route read as
/// "aim-assist"). A drawn endpoint that binds keeps its aim via a normalized anchor on the bound
/// card; the anchor tracks the card as it moves.
@MainActor
final class ArrowBindingTests: XCTestCase {
  private func makeBoard() -> BoardViewModel {
    BoardViewModel(store: DumpStore(inMemoryOnly: true))
  }

  /// The arrow card's endpoints in board space (mirror of the VM's private `lineEndpoints`).
  private func endpoints(of card: CardState) -> (start: CGPoint, end: CGPoint) {
    let points = card.points ?? CardState.defaultLinePoints()
    let s = points[0].cgPoint
    let e = points[1].cgPoint
    return (
      CGPoint(x: card.x + s.x * card.w, y: card.y + s.y * card.h),
      CGPoint(x: card.x + e.x * card.w, y: card.y + e.y * card.h)
    )
  }

  func testDrawnArrowLandsWhereAimed() {
    let board = makeBoard()
    let boxID = board.addElement(.rectangle, at: CGPoint(x: 300, y: 300))
    guard let box = board.cards.first(where: { $0.id == boxID }) else { return XCTFail("no box") }

    // Aim at the box's top-LEFT corner region — far from where a center ray from this start
    // would exit the frame.
    let drawnStart = CGPoint(x: box.frame.minX - 200, y: box.frame.minY - 120)
    let drawnEnd = CGPoint(x: box.frame.minX + 8, y: box.frame.minY + 6)
    guard let arrowID = board.addDrawnElement(.arrow, from: drawnStart, to: drawnEnd),
          let arrow = board.cards.first(where: { $0.id == arrowID })
    else { return XCTFail("no arrow") }

    XCTAssertEqual(arrow.endBindingID, boxID)
    let committed = endpoints(of: arrow)
    // The bound tip stays at the aimed corner (clipped to the frame edge along the drawn
    // segment) — the center-ray route would land it tens of points away.
    XCTAssertLessThan(hypot(committed.end.x - drawnEnd.x, committed.end.y - drawnEnd.y), 12)
    // The unbound tail is untouched.
    XCTAssertLessThan(hypot(committed.start.x - drawnStart.x, committed.start.y - drawnStart.y), 1)
  }

  func testAnchorTracksTheCardAsItMoves() {
    let board = makeBoard()
    let boxID = board.addElement(.rectangle, at: CGPoint(x: 300, y: 300))
    guard let box = board.cards.first(where: { $0.id == boxID }) else { return XCTFail("no box") }

    let drawnEnd = CGPoint(x: box.frame.minX + 8, y: box.frame.minY + 6)
    guard let arrowID = board.addDrawnElement(
      .arrow, from: CGPoint(x: box.frame.minX - 200, y: box.frame.minY - 120), to: drawnEnd),
      let anchor = board.cards.first(where: { $0.id == arrowID })?.endBindingAnchor
    else { return XCTFail("no bound arrow") }

    // Move the box; the arrow's tip must follow to the SAME normalized spot on the frame.
    let delta = CGSize(width: 140, height: 90)
    board.setFrame(boxID, box.frame.offsetBy(dx: delta.width, dy: delta.height))
    guard let moved = board.cards.first(where: { $0.id == boxID }),
          let arrow = board.cards.first(where: { $0.id == arrowID })
    else { return XCTFail("cards vanished") }

    let expected = CGPoint(
      x: moved.frame.minX + CGFloat(anchor.x) * moved.frame.width,
      y: moved.frame.minY + CGFloat(anchor.y) * moved.frame.height)
    let committed = endpoints(of: arrow)
    XCTAssertLessThan(hypot(committed.end.x - expected.x, committed.end.y - expected.y), 1)
  }

  /// A save/export taken MID-EDIT applies the text card's live auto-fit frame; the bound arrows in
  /// that same snapshot must be re-anchored against it (not left aimed at the committed frame) —
  /// and the published board must stay untouched (snapshotting is side-effect-free).
  func testRenderingSnapshotReanchorsBoundArrowsToLiveEditFrame() {
    let board = makeBoard()
    let textID = board.insertText("target", at: CGPoint(x: 300, y: 300))
    guard let target = board.cards.first(where: { $0.id == textID }) else { return XCTFail("no card") }

    let drawnEnd = CGPoint(x: target.frame.minX + 4, y: target.frame.minY + 4)
    guard let arrowID = board.addDrawnElement(
      .arrow, from: CGPoint(x: target.frame.minX - 200, y: target.frame.minY - 150), to: drawnEnd),
      let anchor = board.cards.first(where: { $0.id == arrowID })?.endBindingAnchor
    else { return XCTFail("no bound arrow") }
    let committedArrowTip = endpoints(of: board.cards.first { $0.id == arrowID }!).end

    // Live-hug the text card to a new size mid-edit (no commit).
    board.beginEditing(textID)
    guard let live = board.fitTextEditing(textID, naturalEditorWidth: 500, editorContentHeight: 320) else {
      return XCTFail("no live frame")
    }

    let snapshot = board.renderingSnapshot(for: board.cards)
    guard let snapText = snapshot.first(where: { $0.id == textID }),
          let snapArrow = snapshot.first(where: { $0.id == arrowID })
    else { return XCTFail("snapshot missing cards") }
    XCTAssertEqual(snapText.frame.size, live.size)

    // The snapshot's tip sits at the stored anchor resolved against the LIVE frame.
    let expected = CGPoint(
      x: snapText.frame.minX + CGFloat(anchor.x) * snapText.frame.width,
      y: snapText.frame.minY + CGFloat(anchor.y) * snapText.frame.height)
    let snapTip = endpoints(of: snapArrow).end
    XCTAssertLessThan(hypot(snapTip.x - expected.x, snapTip.y - expected.y), 1)

    // The live board's committed arrow is untouched by taking the snapshot.
    let boardTip = endpoints(of: board.cards.first { $0.id == arrowID }!).end
    XCTAssertLessThan(hypot(boardTip.x - committedArrowTip.x, boardTip.y - committedArrowTip.y), 0.001)
  }
}
