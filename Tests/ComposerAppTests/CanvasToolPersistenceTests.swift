import XCTest
@testable import ComposerApp

final class CanvasToolPersistenceTests: XCTestCase {
  func testContinuousDrawingRemainsOptIn() {
    XCTAssertFalse(ComposerPreferences.defaultContinuousDrawingEnabled)
  }

  func testOnlyRepeatableDrawingToolsCanStayActive() {
    let repeatable: [CanvasTool] = [.rectangle, .ellipse, .diamond, .line, .arrow, .freehand, .vectorPen]
    let oneShot: [CanvasTool] = [.select, .text, .equation, .image, .sticky, .checklist, .table]

    for tool in repeatable {
      XCTAssertTrue(tool.isRepeatableDrawingTool)
      XCTAssertEqual(tool.afterSuccessfulPlacement(continuousDrawing: true), tool)
      XCTAssertEqual(tool.afterSuccessfulPlacement(continuousDrawing: false), .select)
    }
    for tool in oneShot {
      XCTAssertFalse(tool.isRepeatableDrawingTool)
      XCTAssertEqual(tool.afterSuccessfulPlacement(continuousDrawing: true), .select)
      XCTAssertEqual(tool.afterSuccessfulPlacement(continuousDrawing: false), .select)
    }
  }
}
