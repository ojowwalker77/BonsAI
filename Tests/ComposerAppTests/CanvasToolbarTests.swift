import XCTest

@testable import ComposerApp

final class CanvasToolbarTests: XCTestCase {
  func testCatalogDefinesEveryVisibleToolExactlyOnce() {
    let descriptors = CanvasToolbarCatalog.fullTools + CanvasToolbarCatalog.moreGroup.tools

    XCTAssertEqual(descriptors.count, Set(descriptors.map(\.tool)).count)
    XCTAssertEqual(
      Set(descriptors.map(\.tool)),
      [.select, .text, .rectangle, .ellipse, .diamond, .line, .arrow, .freehand,
       .vectorPen, .equation, .sticky, .checklist, .table]
    )
  }

  func testCompactGroupsReuseTheFullToolbarDescriptors() {
    let compactDescriptors = [CanvasToolbarCatalog.select, CanvasToolbarCatalog.text]
      + CanvasToolbarCatalog.shapeGroup.tools
      + CanvasToolbarCatalog.connectorGroup.tools
      + CanvasToolbarCatalog.drawingGroup.tools
      + [CanvasToolbarCatalog.equation]
      + CanvasToolbarCatalog.moreGroup.tools
    let fullDescriptors = CanvasToolbarCatalog.fullTools + CanvasToolbarCatalog.moreGroup.tools

    XCTAssertEqual(Set(compactDescriptors), Set(fullDescriptors))
  }

  func testShortcutsMatchExcalidraw() {
    let digits: [Int: CanvasTool] = [
      1: .select, 2: .rectangle, 3: .diamond, 4: .ellipse, 5: .arrow, 6: .line, 7: .freehand,
      8: .text, 9: .equation,
    ]
    for (digit, tool) in digits {
      XCTAssertEqual(CanvasToolbarCatalog.tool(forDigit: digit), tool, "digit \(digit)")
    }
    let letters: [String: CanvasTool] = [
      "v": .select, "r": .rectangle, "d": .diamond, "o": .ellipse, "a": .arrow, "l": .line,
      "p": .freehand, "x": .freehand, "t": .text, "b": .vectorPen,
    ]
    for (letter, tool) in letters {
      XCTAssertEqual(CanvasToolbarCatalog.tool(forLetter: letter), tool, "letter \(letter)")
    }
    XCTAssertNil(CanvasToolbarCatalog.tool(forLetter: CanvasToolbarCatalog.toolLockLetter))
  }

  func testEveryShortcutIsUnique() {
    let digits = CanvasToolbarCatalog.all.compactMap(\.shortcut)
    XCTAssertEqual(digits.count, Set(digits).count)
    let letters = CanvasToolbarCatalog.all.flatMap(\.letters)
    XCTAssertEqual(letters.count, Set(letters).count)
  }

  func testPersistenceSlotFootprintIsStableForEveryTool() {
    XCTAssertEqual(CanvasToolbarLayoutPolicy.persistenceSlotCount, 1)
    XCTAssertTrue(CanvasToolbarLayoutPolicy.showsPersistenceAction(for: .rectangle))
    XCTAssertTrue(CanvasToolbarLayoutPolicy.showsPersistenceAction(for: .vectorPen))
    XCTAssertFalse(CanvasToolbarLayoutPolicy.showsPersistenceAction(for: .select))
    XCTAssertFalse(CanvasToolbarLayoutPolicy.showsPersistenceAction(for: .text))
  }
}
