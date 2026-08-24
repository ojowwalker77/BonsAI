import XCTest
@testable import ComposerApp

final class ChecklistInteractionTests: XCTestCase {
  func testStructuredChecklistOnlyTargetsTheCheckboxColumn() {
    XCTAssertEqual(
      ChecklistInteraction.itemIndex(
        at: CGPoint(x: 20, y: 50), zoom: 1, itemCount: 3, layout: .structured),
      1)
    XCTAssertNil(ChecklistInteraction.itemIndex(
      at: CGPoint(x: 100, y: 50), zoom: 1, itemCount: 3, layout: .structured))
    XCTAssertNil(ChecklistInteraction.itemIndex(
      at: CGPoint(x: 20, y: 39), zoom: 1, itemCount: 3, layout: .structured),
      "the inter-row gap is not a checkbox")
    XCTAssertNil(ChecklistInteraction.itemIndex(
      at: CGPoint(x: 20, y: 8), zoom: 1, itemCount: 3, layout: .structured),
      "padding above the first row is not a checkbox")
  }

  func testMarkdownCheckboxHitRegionScalesWithZoom() {
    XCTAssertEqual(
      ChecklistInteraction.itemIndex(
        at: CGPoint(x: 40, y: 94), zoom: 2, itemCount: 3, layout: .markdown),
      1)
    XCTAssertNil(ChecklistInteraction.itemIndex(
      at: CGPoint(x: 120, y: 94), zoom: 2, itemCount: 3, layout: .markdown))
    XCTAssertNil(ChecklistInteraction.itemIndex(
      at: CGPoint(x: 40, y: 130), zoom: 2, itemCount: 2, layout: .markdown))
  }

  func testReorderMovesTheWholeStableItemInEitherDirection() {
    let first = CardState.ChecklistItem(text: "First", isChecked: true)
    let second = CardState.ChecklistItem(text: "Second", isChecked: false)
    let third = CardState.ChecklistItem(text: "Third", isChecked: true)
    var items = [first, second, third]

    XCTAssertTrue(ChecklistInteraction.move(&items, itemID: first.id, to: third.id))
    XCTAssertEqual(items, [second, third, first])
    XCTAssertTrue(ChecklistInteraction.move(&items, itemID: first.id, to: second.id))
    XCTAssertEqual(items, [first, second, third])
  }

  func testInvalidAndIdentityDropsDoNotMutateTheDraft() {
    let item = CardState.ChecklistItem(text: "Only", isChecked: true)
    var items = [item]

    XCTAssertFalse(ChecklistInteraction.move(&items, itemID: item.id, to: item.id))
    XCTAssertFalse(ChecklistInteraction.move(&items, itemID: UUID(), to: item.id))
    XCTAssertEqual(items, [item])
  }
}
