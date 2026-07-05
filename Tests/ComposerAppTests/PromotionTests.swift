import XCTest
import CoreGraphics
@testable import ComposerApp

/// The "promotion seam" mutations on `BoardViewModel`: freehand→shape/line/arrow, text→equation, and
/// a bullet text card split into one card per line. Each promotion keeps the card's tint (and, for
/// the in-place kind rewrites, its id) and is exactly one undo step. Also covers the pure detection
/// helpers (`isMathLike`, `isBulletList`) that decide when a chip is offered — precision-first.
@MainActor
final class PromotionTests: XCTestCase {
  /// In-memory store: `swift test` is unsandboxed, so the shared store IS the user's real board.
  private func makeBoard() -> BoardViewModel {
    BoardViewModel(store: DumpStore(inMemoryOnly: true))
  }

  /// A freehand card at a known frame/tint. Points are normalized into its 0…1 local frame, exactly
  /// as `addFreehandStroke` stores them.
  private func seedFreehand(_ board: BoardViewModel,
                            frame: CGRect = CGRect(x: 100, y: 100, width: 200, height: 160),
                            tint: Int? = 3) -> UUID {
    let card = CardState(
      kind: .freehand, x: Double(frame.minX), y: Double(frame.minY),
      w: Double(frame.width), h: Double(frame.height), z: 1,
      points: [CanvasPoint(x: 0, y: 0), CanvasPoint(x: 1, y: 1)], tint: tint)
    let ids = board.insertCopies([card], offset: .zero)
    XCTAssertEqual(ids.count, 1)
    return ids[0]
  }

  private func seedText(_ board: BoardViewModel, _ text: String, tint: Int? = 2) -> UUID {
    let card = CardState(kind: .text, text: text, x: 40, y: 40, w: 360, h: 120, z: 1, tint: tint)
    let ids = board.insertCopies([card], offset: .zero)
    XCTAssertEqual(ids.count, 1)
    return ids[0]
  }

  // MARK: convertFreehand — box shapes

  func testConvertFreehandToRectangleTakesTheRecognitionRectKeepingIdAndTint() {
    let board = makeBoard()
    let id = seedFreehand(board, tint: 4)
    let rect = CGRect(x: 10, y: 20, width: 300, height: 200)

    board.convertFreehand(id, to: .rectangle(rect))

    guard let card = board.cards.first(where: { $0.id == id }) else { return XCTFail("card keeps its id") }
    XCTAssertEqual(card.elementKind, .rectangle)
    XCTAssertEqual(card.frame, rect)
    XCTAssertNil(card.points, "a box shape carries no endpoints")
    XCTAssertEqual(card.tint, 4, "tint is preserved")
  }

  func testConvertFreehandToEllipseAndDiamondSetTheKind() {
    for (kindMaker, expected) in [
      (ShapeRecognizer.Kind.ellipse(CGRect(x: 0, y: 0, width: 120, height: 120)), CanvasElementKind.ellipse),
      (ShapeRecognizer.Kind.diamond(CGRect(x: 0, y: 0, width: 120, height: 90)), CanvasElementKind.diamond),
    ] {
      let board = makeBoard()
      let id = seedFreehand(board)
      board.convertFreehand(id, to: kindMaker)
      XCTAssertEqual(board.cards.first { $0.id == id }?.elementKind, expected)
    }
  }

  // MARK: convertFreehand — lines/arrows (mirror addDrawnElement geometry)

  func testConvertFreehandToLineMatchesDrawnGeometry() {
    let board = makeBoard()
    let id = seedFreehand(board, tint: 1)
    let start = CGPoint(x: 120, y: 140)
    let end = CGPoint(x: 320, y: 260)

    board.convertFreehand(id, to: .line(start: start, end: end))

    // Reference: what a freshly DRAWN line of the same endpoints produces.
    let reference = makeBoard()
    let refID = reference.addDrawnElement(.line, from: start, to: end)!
    let refCard = reference.cards.first { $0.id == refID }!

    guard let card = board.cards.first(where: { $0.id == id }) else { return XCTFail("card keeps id") }
    XCTAssertEqual(card.elementKind, .line)
    XCTAssertEqual(card.frame, refCard.frame, "promoted line's frame matches a drawn one")
    XCTAssertEqual(card.points, refCard.points, "endpoints are stored the same way")
    XCTAssertEqual(card.tint, 1)
  }

  func testConvertFreehandToArrowPadsAShortSegmentLikeADrawnArrow() {
    let board = makeBoard()
    let id = seedFreehand(board)
    // A near-horizontal segment shorter than lineMinSize.height must pad symmetrically, same as drawn.
    let start = CGPoint(x: 100, y: 200)
    let end = CGPoint(x: 300, y: 205)

    board.convertFreehand(id, to: .arrow(start: start, end: end))

    let reference = makeBoard()
    let refID = reference.addDrawnElement(.arrow, from: start, to: end)!
    let refCard = reference.cards.first { $0.id == refID }!

    let card = board.cards.first { $0.id == id }
    XCTAssertEqual(card?.elementKind, .arrow)
    XCTAssertEqual(card?.frame, refCard.frame)
    XCTAssertEqual(card?.points, refCard.points)
  }

  func testConvertFreehandIsOneUndoStepRestoringTheFreehandExactly() {
    let board = makeBoard()
    let frame = CGRect(x: 100, y: 100, width: 200, height: 160)
    let id = seedFreehand(board, frame: frame, tint: 3)
    let before = board.cards.first { $0.id == id }

    board.convertFreehand(id, to: .rectangle(CGRect(x: 10, y: 20, width: 300, height: 200)))
    board.undo()

    let restored = board.cards.first { $0.id == id }
    XCTAssertEqual(restored?.elementKind, .freehand, "one undo restores the freehand kind")
    XCTAssertEqual(restored?.frame, before?.frame, "and its frame")
    XCTAssertEqual(restored?.points, before?.points, "and its stroke points")
    XCTAssertEqual(restored?.tint, before?.tint)
  }

  func testConvertFreehandIgnoresNonFreehandCards() {
    let board = makeBoard()
    let id = seedText(board, "note")
    board.convertFreehand(id, to: .rectangle(CGRect(x: 0, y: 0, width: 100, height: 100)))
    XCTAssertEqual(board.cards.first { $0.id == id }?.elementKind, .text)
  }

  // MARK: convertTextToEquation

  func testConvertTextToEquationStripsDelimitersAndClearsText() {
    let board = makeBoard()
    let id = seedText(board, "$$\\frac{x}{2}$$", tint: 5)

    board.convertTextToEquation(id)

    guard let card = board.cards.first(where: { $0.id == id }) else { return XCTFail("card keeps id") }
    XCTAssertEqual(card.elementKind, .equation)
    XCTAssertEqual(card.latex, "\\frac{x}{2}", "surrounding $$ are stripped, LaTeX stored raw")
    XCTAssertTrue(card.text.isEmpty, "an equation card carries no plain text")
    XCTAssertEqual(card.tint, 5, "tint is preserved")
  }

  func testConvertTextToEquationStripsSingleDollars() {
    let board = makeBoard()
    let id = seedText(board, "$e=mc^2$")
    board.convertTextToEquation(id)
    XCTAssertEqual(board.cards.first { $0.id == id }?.latex, "e=mc^2")
  }

  func testConvertTextToEquationKeepsBareLatexUndelimited() {
    let board = makeBoard()
    let id = seedText(board, "\\alpha + \\beta")
    board.convertTextToEquation(id)
    XCTAssertEqual(board.cards.first { $0.id == id }?.latex, "\\alpha + \\beta")
  }

  func testConvertTextToEquationIsOneUndoStep() {
    let board = makeBoard()
    let id = seedText(board, "$$x^2$$", tint: 2)
    board.convertTextToEquation(id)

    board.undo()

    let restored = board.cards.first { $0.id == id }
    XCTAssertEqual(restored?.elementKind, .text, "one undo restores the text card")
    XCTAssertEqual(restored?.text, "$$x^2$$")
    XCTAssertEqual(restored?.tint, 2)
  }

  // MARK: splitTextCard

  func testSplitTextCardMakesOneCardPerLineStrippingBulletsInOrder() {
    let board = makeBoard()
    let id = seedText(board, "- first\n- second\n- third", tint: 6)
    let original = board.cards.first { $0.id == id }
    let originX = original?.x
    let originY = original?.y
    let originW = original?.w
    let priorIDs = Set(board.cards.map(\.id))

    board.splitTextCard(id)

    XCTAssertNil(board.cards.first { $0.id == id }, "the original bullet card is deleted")
    // Only the cards this split created (the board seeds a blank first card of its own).
    let newCards = board.cards.filter { !priorIDs.contains($0.id) }.sorted { $0.y < $1.y }
    XCTAssertEqual(newCards.map(\.text), ["first", "second", "third"], "bullets stripped, order kept")
    // Tint inherited, same width, stacked down from the original's origin.
    XCTAssertTrue(newCards.allSatisfy { $0.tint == 6 }, "each new card inherits the tint")
    XCTAssertTrue(newCards.allSatisfy { $0.w == originW }, "each new card keeps the original width")
    XCTAssertEqual(newCards.first?.x, originX)
    XCTAssertEqual(newCards.first?.y, originY)
    XCTAssertTrue((newCards.last?.y ?? 0) > (newCards.first?.y ?? 0), "cards stack downward")
  }

  func testSplitTextCardKeepsNonBulletHeadingLines() {
    let board = makeBoard()
    let priorIDs = Set(board.cards.map(\.id))
    let id = seedText(board, "Plan\n- ship it\n- test it\n- write docs")
    board.splitTextCard(id)
    let texts = board.cards.filter { !priorIDs.contains($0.id) }.sorted { $0.y < $1.y }.map(\.text)
    XCTAssertEqual(texts, ["Plan", "ship it", "test it", "write docs"], "the heading becomes a card too")
  }

  func testSplitTextCardIsOneUndoStepRestoringTheSingleCard() {
    let board = makeBoard()
    let priorIDs = Set(board.cards.map(\.id))
    let id = seedText(board, "- a\n- b\n- c", tint: 1)
    board.splitTextCard(id)
    XCTAssertEqual(board.cards.filter { !priorIDs.contains($0.id) }.count, 3)

    board.undo()

    let restored = board.cards.first { $0.id == id }
    XCTAssertNotNil(restored, "one undo restores the original card by id")
    XCTAssertEqual(restored?.text, "- a\n- b\n- c")
    XCTAssertEqual(restored?.tint, 1)
    XCTAssertEqual(board.cards.filter { !priorIDs.contains($0.id) && $0.id != id }.count, 0, "and removes the split cards")
  }

  // MARK: Detection helpers (pure — the chip's offer gate)

  func testIsMathLikeAcceptsDelimitedAndCommandForms() {
    XCTAssertTrue(BoardViewModel.isMathLike("$x^2$"))
    XCTAssertTrue(BoardViewModel.isMathLike("$$\\frac{a}{b}$$"))
    XCTAssertTrue(BoardViewModel.isMathLike("\\alpha = 3"))
    XCTAssertTrue(BoardViewModel.isMathLike("  \\sqrt{2}  "), "leading/trailing space is trimmed first")
  }

  func testIsMathLikeRejectsProseEmptyAndMultiline() {
    XCTAssertFalse(BoardViewModel.isMathLike("just a note"))
    XCTAssertFalse(BoardViewModel.isMathLike(""))
    XCTAssertFalse(BoardViewModel.isMathLike("   "))
    XCTAssertFalse(BoardViewModel.isMathLike("$x$\nand more"), "multi-line is never an equation")
    XCTAssertFalse(BoardViewModel.isMathLike("$"), "a lone $ is not a delimited equation")
  }

  func testIsBulletListNeedsThreeLinesAndThreeMarkers() {
    XCTAssertTrue(BoardViewModel.isBulletList("- a\n- b\n- c"))
    XCTAssertTrue(BoardViewModel.isBulletList("Heading\n* a\n* b\n* c"))
    XCTAssertTrue(BoardViewModel.isBulletList("• one\n• two\n• three"))
  }

  func testIsBulletListRejectsTooFewLinesOrMarkers() {
    XCTAssertFalse(BoardViewModel.isBulletList("- a\n- b"), "fewer than 3 lines")
    XCTAssertFalse(BoardViewModel.isBulletList("- a\nplain\nplain\nplain"), "fewer than 3 markers")
    XCTAssertFalse(BoardViewModel.isBulletList("a single - dash mid sentence"))
  }

  func testStrippedHelpersMatchTheMutations() {
    XCTAssertEqual(BoardViewModel.strippedEquationLatex("$$x^2$$"), "x^2")
    XCTAssertEqual(BoardViewModel.strippedEquationLatex("$y$"), "y")
    XCTAssertEqual(BoardViewModel.strippedEquationLatex("\\alpha"), "\\alpha")
    XCTAssertEqual(BoardViewModel.strippedBulletMarker("- item"), "item")
    XCTAssertEqual(BoardViewModel.strippedBulletMarker("• item"), "item")
    XCTAssertEqual(BoardViewModel.strippedBulletMarker("heading"), "heading")
  }
}
