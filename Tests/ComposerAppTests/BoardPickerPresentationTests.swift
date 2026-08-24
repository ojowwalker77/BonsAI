import XCTest

@testable import ComposerApp

final class BoardPickerPresentationTests: XCTestCase {
  func testChromeTokensPreservePickerRowAndActionGeometry() {
    XCTAssertEqual(WindowChrome.boardPickerExpandedWidth, 232)
    XCTAssertEqual(WindowChrome.boardPickerRowHeight, 30)
    XCTAssertEqual(
      WindowChrome.boardPickerActionSlotWidth,
      WindowChrome.rowIconSide * 2 + WindowChrome.itemSpacing)
    XCTAssertLessThanOrEqual(WindowChrome.rowIconSide, WindowChrome.boardPickerRowHeight)
  }

  func testRowActionsStayVisibleAndEnabledForTheWholeHoverLifetime() {
    var state = BoardPickerRowInteractionState()
    XCTAssertFalse(state.showsActions)
    XCTAssertFalse(state.enablesActions)

    XCTAssertTrue(state.setHovered(true))
    XCTAssertTrue(state.showsActions)
    XCTAssertTrue(state.enablesActions)
    XCTAssertFalse(state.setHovered(true), "moving within the row must not restart hover")
    XCTAssertTrue(state.showsActions, "crossing into the reserved action slot keeps actions alive")

    XCTAssertFalse(state.setHovered(false))
    XCTAssertFalse(state.showsActions)
    XCTAssertFalse(state.enablesActions)
  }

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
    XCTAssertEqual(
      BoardPickerLayoutPolicy.expandedTextBudget(viewportWidth: normalViewportWidth),
      127)
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
    XCTAssertEqual(
      BoardPickerLayoutPolicy.expandedTextBudget(viewportWidth: viewportWidth),
      103)
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
