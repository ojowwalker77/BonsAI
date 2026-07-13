import XCTest
@testable import ComposerApp

@MainActor
final class NewCanvasElementsTests: XCTestCase {
  func testStructuredElementsRoundTrip() throws {
    let cards = [
      CardState(kind: .sticky, text: "Remember this", x: 1, y: 2, stickyTitle: "Release"),
      CardState(kind: .checklist, x: 3, y: 4,
                checklist: [.init(text: "Ship", isChecked: true), .init(text: "Celebrate")]),
      CardState(kind: .table, x: 5, y: 6,
                table: .init(columns: ["Name", "Owner"], rows: [["Canvas", "Jo"]])),
    ]
    let decoded = try JSONDecoder().decode([CardState].self, from: JSONEncoder().encode(cards))
    XCTAssertEqual(decoded, cards)
  }

  func testLegacyCardWithoutStructuredPayloadsStillDecodes() throws {
    let json = #"{"id":"00000000-0000-0000-0000-000000000001","text":"legacy","x":1,"y":2,"w":360,"h":220,"z":0}"#.data(using: .utf8)!
    let card = try JSONDecoder().decode(CardState.self, from: json)
    XCTAssertEqual(card.elementKind, .text)
    XCTAssertNil(card.checklist)
    XCTAssertNil(card.table)
    XCTAssertNil(card.stickyTitle)
  }

  func testStickyTitleAndBodyEditAsOneUndoStep() {
    let board = BoardViewModel(store: DumpStore(inMemoryOnly: true))
    let id = board.insertStructured(.sticky, title: "Old", text: "Body", at: .zero)
    XCTAssertTrue(board.setSticky(id, title: "New", body: "Updated body"))
    let changed = board.cards.first(where: { $0.id == id })
    XCTAssertEqual(changed?.stickyTitle, "New")
    XCTAssertEqual(changed?.text, "Updated body")
    XCTAssertEqual(changed.map { board.plainText(for: $0) }, "New\n\nUpdated body")
    board.undo()
    let restored = board.cards.first(where: { $0.id == id })
    XCTAssertEqual(restored?.stickyTitle, "Old")
    XCTAssertEqual(restored?.text, "Body")
  }

  func testChecklistEditIsOneUndoStepAndRejectsBadTargets() {
    let board = BoardViewModel(store: DumpStore(inMemoryOnly: true))
    let id = board.insertStructured(.checklist, checklist: [.init(text: "First")], at: .zero)
    XCTAssertTrue(board.setChecklist(id, [.init(text: "Changed"), .init(text: "Added")]))
    XCTAssertEqual(board.cards.first(where: { $0.id == id })?.checklist?.map(\.text), ["Changed", "Added"])
    board.undo()
    XCTAssertEqual(board.cards.first(where: { $0.id == id })?.checklist?.map(\.text), ["First"])
    XCTAssertFalse(board.setChecklist(UUID(), []))
    XCTAssertFalse(board.toggleChecklistItem(id, index: 99))
  }

  func testTableEditIsOneUndoStepAndRejectsWrongKind() {
    let board = BoardViewModel(store: DumpStore(inMemoryOnly: true))
    let original = CardState.TableSpec(columns: ["A"], rows: [["1"]])
    let changed = CardState.TableSpec(columns: ["A", "B"], rows: [["1", "2"]])
    let id = board.insertStructured(.table, table: original, at: .zero)
    XCTAssertTrue(board.setTable(id, changed))
    XCTAssertEqual(board.cards.first(where: { $0.id == id })?.table, changed)
    board.undo()
    XCTAssertEqual(board.cards.first(where: { $0.id == id })?.table, original)
    XCTAssertFalse(board.setChecklist(id, []))
  }
}
