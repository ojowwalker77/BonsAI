import XCTest
@testable import ComposerApp

final class MenuBarControllerTests: XCTestCase {
  func testClickActionKeepsSingleClickCaptureImmediate() {
    XCTAssertEqual(MenuBarStatusClickAction.resolve(clickCount: 0), .toggleCapture)
    XCTAssertEqual(MenuBarStatusClickAction.resolve(clickCount: 1), .toggleCapture)
  }

  func testClickActionRestoresBoardForDoubleAndLaterClicks() {
    XCTAssertEqual(MenuBarStatusClickAction.resolve(clickCount: 2), .showBoard)
    XCTAssertEqual(MenuBarStatusClickAction.resolve(clickCount: 3), .showBoard)
  }

  @MainActor
  func testDoubleClickPostsShowInsteadOfToggleNotification() {
    let center = NotificationCenter()
    var showCount = 0
    var toggleCount = 0
    let showObserver = center.addObserver(
      forName: .composerShowWindow, object: nil, queue: nil
    ) { _ in showCount += 1 }
    let toggleObserver = center.addObserver(
      forName: .composerToggleWindow, object: nil, queue: nil
    ) { _ in toggleCount += 1 }
    defer {
      center.removeObserver(showObserver)
      center.removeObserver(toggleObserver)
    }

    MenuBarController(notificationCenter: center).dispatchStatusClick(clickCount: 2)

    XCTAssertEqual(showCount, 1)
    XCTAssertEqual(toggleCount, 0)
  }
}
