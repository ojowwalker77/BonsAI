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

  func testPersistenceSlotFootprintIsStableForEveryTool() {
    XCTAssertEqual(CanvasToolbarLayoutPolicy.persistenceSlotCount, 1)
    XCTAssertTrue(CanvasToolbarLayoutPolicy.showsPersistenceAction(for: .rectangle))
    XCTAssertTrue(CanvasToolbarLayoutPolicy.showsPersistenceAction(for: .vectorPen))
    XCTAssertFalse(CanvasToolbarLayoutPolicy.showsPersistenceAction(for: .select))
    XCTAssertFalse(CanvasToolbarLayoutPolicy.showsPersistenceAction(for: .text))
  }
}
