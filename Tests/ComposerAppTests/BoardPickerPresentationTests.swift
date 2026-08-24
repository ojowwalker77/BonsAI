import XCTest

@testable import ComposerApp

final class BoardPickerPresentationTests: XCTestCase {
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
