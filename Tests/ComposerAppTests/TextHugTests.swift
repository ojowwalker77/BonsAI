import XCTest
@testable import ComposerApp

/// Content-hugging text sizing (issue #76) and corner-drag font scaling (issue #77). Covers the pure
/// measurement (`fittedTextSize`) and the VM commit contract (`scaleTextCard`: one undo restores both
/// the scale and the frame; `fontScale == 1` round-trips as a legacy card).
@MainActor
final class TextHugTests: XCTestCase {
  private func makeBoard() -> BoardViewModel {
    BoardViewModel(store: DumpStore(inMemoryOnly: true))
  }

  // MARK: - fittedTextSize

  func testShortTextHugsAndFloorsToMinimum() {
    let size = BoardViewModel.fittedTextSize("Hi", fontScale: 1)
    // A tiny card never collapses below the text minimum.
    XCTAssertGreaterThanOrEqual(size.width, CardState.textMinSize.width)
    XCTAssertGreaterThanOrEqual(size.height, CardState.textMinSize.height)
    // …and a two-character line stays far under the wrap cap.
    XCTAssertLessThan(size.width, CardState.textDefaultSize.width)
  }

  func testLongLineCapsWidthAndGrowsHeight() {
    let long = String(repeating: "wrap ", count: 80)
    let size = BoardViewModel.fittedTextSize(long, fontScale: 1)
    // Once natural width exceeds the cap, width pins to cap + 32pt horizontal padding.
    XCTAssertEqual(size.width, CardState.textDefaultSize.width + 32, accuracy: 0.5)
    // Wrapping many words makes it taller than a single line.
    XCTAssertGreaterThan(size.height, CardState.textMinSize.height * 2)
  }

  func testFontScaleWidensTheWrapCap() {
    let long = String(repeating: "wrap ", count: 80)
    let base = BoardViewModel.fittedTextSize(long, fontScale: 1)
    let scaled = BoardViewModel.fittedTextSize(long, fontScale: 2)
    // The cap is CONTENT width × scale, so the capped card is ~2× as wide (padding aside).
    XCTAssertEqual(scaled.width - 32, (base.width - 32) * 2, accuracy: 1)
  }

  // MARK: - scaleTextCard

  func testScaleTextCardStoresScaleAndFrameThenUndoRestoresBoth() {
    let board = makeBoard()
    for id in board.cards.map(\.id) { board.delete(id) }
    let id = board.insertText("scale me", at: CGPoint(x: 40, y: 40))
    let before = board.cards.first { $0.id == id }!.frame

    let target = CGRect(x: 40, y: 40, width: before.width * 2, height: before.height * 2)
    board.scaleTextCard(id, fontScale: 2.0, frame: target)

    let after = board.cards.first { $0.id == id }!
    XCTAssertEqual(after.fontScale, 2.0)
    XCTAssertEqual(after.textScale, 2, accuracy: 0.0001)
    XCTAssertEqual(after.frame, target)

    board.undo()
    let restored = board.cards.first { $0.id == id }!
    XCTAssertNil(restored.fontScale)          // one undo restores the scale…
    XCTAssertEqual(restored.frame, before)    // …and the frame together.
  }

  func testScaleOfOneRoundTripsAsLegacyCard() {
    let board = makeBoard()
    let id = board.insertText("unscaled", at: .zero)
    let frame = board.cards.first { $0.id == id }!.frame
    board.scaleTextCard(id, fontScale: 1.0, frame: frame)
    // fontScale == 1 is stored as nil so the card decodes like a board that never had the feature.
    XCTAssertNil(board.cards.first { $0.id == id }!.fontScale)
  }
}
