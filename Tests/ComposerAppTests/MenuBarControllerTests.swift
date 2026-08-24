import XCTest
@testable import ComposerApp

final class MenuBarControllerTests: XCTestCase {
  func testClickActionDefersSingleClickCapture() {
    XCTAssertEqual(MenuBarStatusClickAction.resolve(clickCount: 0), .deferToggleCapture)
    XCTAssertEqual(MenuBarStatusClickAction.resolve(clickCount: 1), .deferToggleCapture)
  }

  func testClickActionCancelsDeferredCaptureAndRestoresBoardForDoubleClicks() {
    XCTAssertEqual(MenuBarStatusClickAction.resolve(clickCount: 2), .cancelDeferredToggleAndShowBoard)
    XCTAssertEqual(MenuBarStatusClickAction.resolve(clickCount: 3), .cancelDeferredToggleAndShowBoard)
  }

  @MainActor
  func testSingleClickTogglesCaptureOnlyAfterDoubleClickInterval() {
    let controller = MenuBarController(doubleClickInterval: 0.01)
    var toggleCount = 0

    controller.dispatchStatusClick(clickCount: 1) { toggleCount += 1 }

    XCTAssertEqual(toggleCount, 0)
    RunLoop.main.run(until: Date().addingTimeInterval(0.03))
    XCTAssertEqual(toggleCount, 1)
  }

  @MainActor
  func testDoubleClickCancelsDeferredCaptureBeforeShowingBoard() {
    let center = NotificationCenter()
    let controller = MenuBarController(notificationCenter: center, doubleClickInterval: 0.01)
    var toggleCount = 0
    var showCount = 0
    let observer = center.addObserver(
      forName: .composerShowWindow, object: nil, queue: nil
    ) { _ in showCount += 1 }
    defer { center.removeObserver(observer) }

    controller.dispatchStatusClick(clickCount: 1) { toggleCount += 1 }
    controller.dispatchStatusClick(clickCount: 2) { toggleCount += 1 }
    RunLoop.main.run(until: Date().addingTimeInterval(0.03))

    XCTAssertEqual(toggleCount, 0)
    XCTAssertEqual(showCount, 1)
  }

  @MainActor
  func testSupersedingSingleClickSuppressesStaleDeferredAction() {
    let controller = MenuBarController(doubleClickInterval: 0.01)
    var staleToggleCount = 0
    var currentToggleCount = 0

    controller.dispatchStatusClick(clickCount: 1) { staleToggleCount += 1 }
    controller.dispatchStatusClick(clickCount: 1) { currentToggleCount += 1 }
    RunLoop.main.run(until: Date().addingTimeInterval(0.03))

    XCTAssertEqual(staleToggleCount, 0)
    XCTAssertEqual(currentToggleCount, 1)
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
