import XCTest
@testable import ComposerApp

@MainActor
final class ChecklistInteractionTests: XCTestCase {
  func testMeasuredCheckboxFramesFollowWrappedRowsInsteadOfInferringAStride() {
    let frames = [
      0: CGRect(x: 12, y: 16, width: 12, height: 12),
      // A long first row wrapped, so the second checkbox is much lower than a fixed stride.
      1: CGRect(x: 12, y: 92, width: 12, height: 12),
    ]

    XCTAssertEqual(
      ChecklistInteraction.itemIndex(at: CGPoint(x: 18, y: 98), renderedFrames: frames),
      1)
    XCTAssertNil(ChecklistInteraction.itemIndex(
      at: CGPoint(x: 18, y: 50), renderedFrames: frames))
  }

  func testMeasuredFramesHonorTextScaleAndKeepAMinimumScreenSpaceTarget() {
    let frames = [
      0: CGRect(x: 8, y: 18, width: 5, height: 5),
      1: CGRect(x: 8, y: 74, width: 18, height: 18),
    ]

    XCTAssertEqual(
      ChecklistInteraction.itemIndex(at: CGPoint(x: 20, y: 76), renderedFrames: frames),
      1,
      "the measured scaled row is used directly")
    let smallCenter = CGPoint(x: frames[0]!.midX, y: frames[0]!.midY)
    XCTAssertEqual(
      ChecklistInteraction.itemIndex(
        at: CGPoint(x: smallCenter.x + 11, y: smallCenter.y), renderedFrames: frames),
      0,
      "a tiny zoomed-out symbol still has a 24pt screen-space target")
    XCTAssertNil(ChecklistInteraction.itemIndex(
      at: CGPoint(x: smallCenter.x + 13, y: smallCenter.y), renderedFrames: frames))
  }

  func testOverlappingMinimumTargetsChooseTheNearestRenderedCheckbox() {
    let frames = [
      0: CGRect(x: 10, y: 10, width: 4, height: 4),
      1: CGRect(x: 10, y: 20, width: 4, height: 4),
    ]

    XCTAssertEqual(
      ChecklistInteraction.itemIndex(at: CGPoint(x: 12, y: 19), renderedFrames: frames),
      1)
  }

  func testLockedStructuredChecklistRejectsToggleAndEditWithoutUndoCheckpoint() throws {
    let board = BoardViewModel(store: DumpStore(inMemoryOnly: true))
    let original = [CardState.ChecklistItem(text: "Ship")]
    let id = board.insertStructured(.checklist, checklist: original, at: .zero)
    board.lockSelection(true)

    XCTAssertFalse(board.toggleChecklistItem(id, index: 0))
    XCTAssertFalse(board.setChecklist(id, [.init(text: "Changed", isChecked: true)]))
    XCTAssertEqual(try XCTUnwrap(board.cards.first { $0.id == id }.flatMap(\.checklist)), original)

    board.undo()
    XCTAssertFalse(try XCTUnwrap(board.cards.first { $0.id == id }).locked,
                   "rejected mutations must not add an undo checkpoint after the lock")
  }

  func testLockedMarkdownChecklistRejectsToggleWithoutUndoCheckpoint() throws {
    let board = BoardViewModel(store: DumpStore(inMemoryOnly: true))
    let original = "- [ ] Locked task"
    let id = board.insertText(original, at: .zero)
    board.lockSelection(true)

    board.toggleTextChecklistLine(id, lineIndex: 0)
    XCTAssertEqual(try XCTUnwrap(board.cards.first { $0.id == id }).text, original)

    board.undo()
    XCTAssertFalse(try XCTUnwrap(board.cards.first { $0.id == id }).locked,
                   "the rejected toggle must not add an undo checkpoint after the lock")
  }

  func testDropPlacementUsesTheHoveredRowHalf() {
    XCTAssertEqual(ChecklistInteraction.dropPlacement(at: 0, rowHeight: 34), .before)
    XCTAssertEqual(ChecklistInteraction.dropPlacement(at: 16.9, rowHeight: 34), .before)
    XCTAssertEqual(ChecklistInteraction.dropPlacement(at: 17, rowHeight: 34), .after)
    XCTAssertEqual(ChecklistInteraction.dropPlacement(at: 34, rowHeight: 34), .after)
  }

  func testReorderPlacementIsSymmetricInBothDirections() {
    let first = CardState.ChecklistItem(text: "First", isChecked: true)
    let second = CardState.ChecklistItem(text: "Second", isChecked: false)
    let third = CardState.ChecklistItem(text: "Third", isChecked: true)
    var items = [first, second, third]

    XCTAssertTrue(ChecklistInteraction.move(
      &items, itemID: first.id, to: third.id, placement: .before))
    XCTAssertEqual(items, [second, first, third])

    items = [first, second, third]
    XCTAssertTrue(ChecklistInteraction.move(
      &items, itemID: first.id, to: third.id, placement: .after))
    XCTAssertEqual(items, [second, third, first])

    items = [first, second, third]
    XCTAssertTrue(ChecklistInteraction.move(
      &items, itemID: third.id, to: first.id, placement: .before))
    XCTAssertEqual(items, [third, first, second])

    items = [first, second, third]
    XCTAssertTrue(ChecklistInteraction.move(
      &items, itemID: third.id, to: first.id, placement: .after))
    XCTAssertEqual(items, [first, third, second])
  }

  func testInvalidAndIdentityDropsDoNotMutateTheDraft() {
    let item = CardState.ChecklistItem(text: "Only", isChecked: true)
    var items = [item]

    XCTAssertFalse(ChecklistInteraction.move(
      &items, itemID: item.id, to: item.id, placement: .before))
    XCTAssertFalse(ChecklistInteraction.move(
      &items, itemID: UUID(), to: item.id, placement: .after))
    XCTAssertEqual(items, [item])
  }

  func testAdjacentDropsThatAlreadyMatchTheRequestedEdgeAreNoOps() {
    let first = CardState.ChecklistItem(text: "First")
    let second = CardState.ChecklistItem(text: "Second")
    var items = [first, second]

    XCTAssertFalse(ChecklistInteraction.move(
      &items, itemID: first.id, to: second.id, placement: .before))
    XCTAssertFalse(ChecklistInteraction.move(
      &items, itemID: second.id, to: first.id, placement: .after))
    XCTAssertEqual(items, [first, second])
  }

  func testValidNoOpDropIsAcceptedWithoutMutatingTheDraft() {
    let first = CardState.ChecklistItem(text: "First")
    let second = CardState.ChecklistItem(text: "Second")
    var items = [first, second]

    XCTAssertTrue(ChecklistDropAcceptance.perform(
      &items, itemID: first.id, targetID: second.id, placement: .before))
    XCTAssertEqual(items, [first, second])

    XCTAssertFalse(ChecklistDropAcceptance.perform(
      &items, itemID: UUID(), targetID: second.id, placement: .before))
    XCTAssertEqual(items, [first, second])
  }

  func testDragProviderSignalsWhenTheDragSessionReleasesIt() {
    var sessionEndCount = 0
    var provider: ChecklistDragItemProvider? = ChecklistDragItemProvider(itemID: UUID()) {
      sessionEndCount += 1
    }

    XCTAssertNotNil(provider)
    provider = nil
    XCTAssertEqual(sessionEndCount, 1)
  }
}
