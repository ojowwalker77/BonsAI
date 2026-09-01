import XCTest
@testable import ComposerApp

/// Shape labels hug their rectangle/ellipse/diamond containers (issue #109). The fit is a layout
/// consequence of the label mutation: it keeps the node centered, refreshes bound connectors, and
/// remains part of the label edit's single undo step.
@MainActor
final class ShapeLabelFitTests: XCTestCase {
  private func makeBoard() -> BoardViewModel {
    BoardViewModel(store: DumpStore(inMemoryOnly: true))
  }

  private func card(_ id: UUID, in board: BoardViewModel) throws -> CardState {
    try XCTUnwrap(board.cards.first { $0.id == id })
  }

  private func endpoints(of card: CardState) -> (start: CGPoint, end: CGPoint) {
    let points = card.points ?? CardState.defaultLinePoints()
    let start = points[0].cgPoint
    let end = points[1].cgPoint
    return (
      CGPoint(x: card.x + start.x * card.w, y: card.y + start.y * card.h),
      CGPoint(x: card.x + end.x * card.w, y: card.y + end.y * card.h))
  }

  func testProgrammaticLabelsFitEveryBoxShapeAndKeepItsCenter() throws {
    for kind in [CanvasElementKind.rectangle, .ellipse, .diamond] {
      let board = makeBoard()
      let id = board.addElement(kind, at: CGPoint(x: 420, y: 260))
      let before = try card(id, in: board).frame

      board.setText(id, "Approve request")

      let after = try card(id, in: board).frame
      let expected = BoardViewModel.fittedShapeSize("Approve request", shape: kind)
      XCTAssertEqual(after.size.width, expected.width, accuracy: 0.5)
      XCTAssertEqual(after.size.height, expected.height, accuracy: 0.5)
      XCTAssertEqual(after.midX, before.midX, accuracy: 0.5)
      XCTAssertEqual(after.midY, before.midY, accuracy: 0.5)

      board.undo()
      let restored = try card(id, in: board)
      XCTAssertEqual(restored.text, "")
      XCTAssertEqual(restored.frame, before)
    }
  }

  func testCommittedUserLabelKeepsTextAndAutoFitInOneUndoStep() throws {
    let board = makeBoard()
    let id = board.addElement(.rectangle, at: CGPoint(x: 300, y: 180))
    let before = try card(id, in: board)
    board.beginEditing(id)
    let interaction = board.interaction(for: id)
    let label = "A label that wraps cleanly across several words"

    board.setText(id, label)
    // Mirror the view's `onChange` after `setText` publishes the new interaction value.
    board.noteEdited(cardID: id, previousText: before.text)
    board.endEditing(id)

    let fitted = BoardViewModel.fittedShapeSize(label, shape: .rectangle)
    let committed = try card(id, in: board)
    XCTAssertEqual(committed.frame.size.width, fitted.width, accuracy: 0.5)
    XCTAssertEqual(committed.frame.size.height, fitted.height, accuracy: 0.5)
    XCTAssertEqual(interaction.plainText, label)

    board.undo()
    let restored = try card(id, in: board)
    XCTAssertEqual(restored.text, before.text)
    XCTAssertEqual(restored.frame, before.frame)
  }

  func testMountedProgrammaticLabelUpdateKeepsUndoAtomic() throws {
    let board = makeBoard()
    let id = board.addElement(.rectangle, at: CGPoint(x: 300, y: 180))
    let before = try card(id, in: board)
    board.setCardMounted(id, true)

    board.setText(id, "Programmatic label")
    // Mirror the mounted card view observing the published interaction value.
    board.noteEdited(cardID: id, previousText: before.text)

    board.undo()
    let restored = try card(id, in: board)
    XCTAssertEqual(restored.text, before.text)
    XCTAssertEqual(restored.frame, before.frame)
  }

  func testLongLabelCapsWidthAndGrowsHeight() {
    let short = BoardViewModel.fittedShapeSize("Short", shape: .rectangle)
    let long = BoardViewModel.fittedShapeSize(String(repeating: "readable label ", count: 30), shape: .rectangle)

    XCTAssertLessThan(short.width, long.width)
    XCTAssertEqual(long.width, 216, accuracy: 0.5)
    XCTAssertGreaterThan(long.height, short.height * 3)
  }

  func testExplicitMultilineLabelKeepsEveryLineVisibleAndCentered() throws {
    let board = makeBoard()
    let id = board.addElement(.rectangle, at: CGPoint(x: 360, y: 240))
    let before = try card(id, in: board).frame
    let label = "Discovery\nDesign\nImplementation\nVerification"

    board.setText(id, label)

    let after = try card(id, in: board).frame
    let oneLine = BoardViewModel.fittedShapeSize("Discovery", shape: .rectangle)
    XCTAssertEqual(after.size, BoardViewModel.fittedShapeSize(label, shape: .rectangle))
    XCTAssertGreaterThan(after.height, oneLine.height)
    XCTAssertEqual(after.midX, before.midX, accuracy: 0.5)
    XCTAssertEqual(after.midY, before.midY, accuracy: 0.5)
    XCTAssertEqual(board.plainText(for: try card(id, in: board)), label)

    board.undo()
    XCTAssertEqual(try card(id, in: board).frame, before)
    XCTAssertEqual(board.plainText(for: try card(id, in: board)), "")
  }

  func testCappedEightLineLabelFitsInsideVisibleDiamondPath() throws {
    let board = makeBoard()
    let id = board.addElement(.diamond, at: CGPoint(x: 360, y: 240))
    let before = try card(id, in: board).frame
    let line = "A deliberately long capped-width decision label"
    let label = Array(repeating: line, count: 8).joined(separator: "\n")

    board.setText(id, label)

    let block = BoardViewModel.fittedShapeLabelBlockSize(label)
    let container = BoardViewModel.fittedShapeSize(label, shape: .diamond)
    XCTAssertEqual(
      block.width,
      ShapeLabelGeometry.defaultMaximumContainerWidth,
      accuracy: 0.5,
      "each explicit line should exercise the same width cap used by NodeLabel")
    XCTAssertTrue(ShapeLabelGeometry.diamondContains(paddedBlock: block, in: container))
    XCTAssertLessThanOrEqual(
      block.width / (container.width - ShapeLabelGeometry.shapePathInset * 2)
        + block.height / (container.height - ShapeLabelGeometry.shapePathInset * 2),
      1.000_001,
      "all four corners of the measured padded label block must stay inside the diamond")

    let fitted = try card(id, in: board).frame
    XCTAssertEqual(fitted.size, container)
    XCTAssertEqual(fitted.midX, before.midX, accuracy: 0.5)
    XCTAssertEqual(fitted.midY, before.midY, accuracy: 0.5)
  }

  func testFittedDiamondContainmentIsStableWhenZoomedOut() {
    let label = Array(repeating: "Zoomed decision label", count: 6).joined(separator: "\n")
    let block = BoardViewModel.fittedShapeLabelBlockSize(label)
    let container = BoardViewModel.fittedShapeSize(label, shape: .diamond)

    for zoom: CGFloat in [0.1, 0.25, 0.5, 0.9, 1, 2] {
      let inset = ShapeLabelGeometry.renderedShapePathInset(at: zoom)
      let screenInteriorWidth = container.width * zoom - inset * 2
      let screenInteriorHeight = container.height * zoom - inset * 2
      let containment = block.width * zoom / screenInteriorWidth
        + block.height * zoom / screenInteriorHeight

      XCTAssertLessThanOrEqual(
        containment,
        1.000_001,
        "zoom \(zoom) must preserve the board-space diamond containment constraint")
    }
  }

  func testShortLabelRespectsShapeMinimum() {
    let size = BoardViewModel.fittedShapeSize("Fit", shape: .rectangle)

    XCTAssertGreaterThanOrEqual(size.width, CardState.shapeMinSize.width)
    XCTAssertGreaterThanOrEqual(size.height, CardState.shapeMinSize.height)
  }

  func testClearingLabelPreservesManualShapeFrame() throws {
    let board = makeBoard()
    let id = board.addElement(.diamond, at: CGPoint(x: 300, y: 180))
    let manual = CGRect(x: 70, y: 90, width: 310, height: 190)
    board.setFrame(id, manual)

    board.setText(id, "   \n")

    XCTAssertEqual(try card(id, in: board).frame, manual)
  }

  func testAutoFitRefreshesBoundArrowAgainstNewShapeBoundary() throws {
    let board = makeBoard()
    let shapeID = board.addElement(.rectangle, at: CGPoint(x: 300, y: 300))
    let shape = try card(shapeID, in: board)
    let aimedEnd = CGPoint(x: shape.frame.minX + 8, y: shape.frame.minY + 6)
    let arrowID = try XCTUnwrap(board.addDrawnElement(
      .arrow,
      from: CGPoint(x: shape.frame.minX - 200, y: shape.frame.minY - 120),
      to: aimedEnd))
    let anchor = try XCTUnwrap(card(arrowID, in: board).endBindingAnchor)

    board.setText(shapeID, "Fit")

    let fittedShape = try card(shapeID, in: board)
    let fittedArrow = try card(arrowID, in: board)
    let expectedEnd = CGPoint(
      x: fittedShape.frame.minX + CGFloat(anchor.x) * fittedShape.frame.width,
      y: fittedShape.frame.minY + CGFloat(anchor.y) * fittedShape.frame.height)
    let actualEnd = endpoints(of: fittedArrow).end
    XCTAssertLessThan(hypot(actualEnd.x - expectedEnd.x, actualEnd.y - expectedEnd.y), 1)
  }

  func testLaterInlineEditCanReturnToStaleCardTextAndStillUndo() throws {
    let board = makeBoard()
    let id = board.insertText("A", at: CGPoint(x: 40, y: 40))
    let interaction = board.interaction(for: id)

    board.beginEditing(id)
    interaction.text = "B"
    interaction.cachePlainText("B")
    board.noteEdited(cardID: id, previousText: "A")
    board.endEditing(id)

    // Inline editing intentionally leaves CardState.text at "A". Returning to that same value in
    // a later session is still a real B → A edit and must capture B as its undo baseline.
    board.beginEditing(id)
    interaction.text = "A"
    interaction.cachePlainText("A")
    board.noteEdited(cardID: id, previousText: "B")
    board.endEditing(id)

    board.undo()
    XCTAssertEqual(board.plainText(for: try card(id, in: board)), "B")
  }
}
