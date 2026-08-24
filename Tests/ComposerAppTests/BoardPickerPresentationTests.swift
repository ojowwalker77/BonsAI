import XCTest

@testable import ComposerApp

final class BoardPickerPresentationTests: XCTestCase {
  func testExpandedPickerPreservesCompactRestWidthAndUsefulTitleBudget() {
    let normalViewportWidth: CGFloat = 1_000
    let expandedWidth = BoardPickerLayoutPolicy.expandedSurfaceWidth(
      viewportWidth: normalViewportWidth)
    XCTAssertEqual(expandedWidth, 232)
    XCTAssertEqual(
      BoardPickerLayoutPolicy.expandedContentWidth(viewportWidth: normalViewportWidth)
        + WindowChrome.padH * 2,
      expandedWidth)
    XCTAssertGreaterThan(
      expandedWidth,
      BoardPickerLayoutPolicy.collapsedSurfaceWidth)
    XCTAssertGreaterThanOrEqual(
      BoardPickerLayoutPolicy.expandedTextBudget(viewportWidth: normalViewportWidth),
      120)
  }

  func testExpandedPickerStaysOutOfReservedActionsAtMinimumWindowWidth() {
    let viewportWidth: CGFloat = 640
    let expandedWidth = BoardPickerLayoutPolicy.expandedSurfaceWidth(
      viewportWidth: viewportWidth)

    XCTAssertLessThanOrEqual(
      WindowChrome.trafficLightInset + expandedWidth,
      viewportWidth - WindowChrome.topRightReservedWidth)
    XCTAssertGreaterThanOrEqual(
      BoardPickerLayoutPolicy.expandedTextBudget(viewportWidth: viewportWidth),
      96)
  }

  func testPickerClosesOnlyAfterPointerAndManagementReleaseIt() {
    XCTAssertTrue(BoardPickerPresentationPolicy.canClose(
      isHovering: false,
      hasActiveRename: false,
      hasDeleteConfirmation: false
    ))
    XCTAssertFalse(BoardPickerPresentationPolicy.canClose(
      isHovering: true,
      hasActiveRename: false,
      hasDeleteConfirmation: false
    ))
  }

  func testRenamePinsPickerOpenAfterPointerLeaves() {
    XCTAssertFalse(BoardPickerPresentationPolicy.canClose(
      isHovering: false,
      hasActiveRename: true,
      hasDeleteConfirmation: false
    ))
  }

  func testDeleteConfirmationPinsPickerOpenAfterPointerLeaves() {
    XCTAssertFalse(BoardPickerPresentationPolicy.canClose(
      isHovering: false,
      hasActiveRename: false,
      hasDeleteConfirmation: true
    ))
  }
}
