import XCTest
@testable import ComposerApp

@MainActor
private final class ManualMenuBarClickScheduler: MenuBarClickScheduling {
  private final class ScheduledClick: MenuBarScheduledClick {
    private(set) var isCancelled = false
    let action: @MainActor () -> Void

    init(action: @escaping @MainActor () -> Void) { self.action = action }
    func cancel() { isCancelled = true }
    func run() { if !isCancelled { action() } }
  }

  private var scheduled: [ScheduledClick] = []
  var pendingCount: Int { scheduled.filter { !$0.isCancelled }.count }

  func schedule(
    after delay: TimeInterval,
    action: @escaping @MainActor () -> Void
  ) -> any MenuBarScheduledClick {
    let click = ScheduledClick(action: action)
    scheduled.append(click)
    return click
  }

  func runPending() {
    let pending = scheduled
    scheduled.removeAll()
    pending.forEach { $0.run() }
  }
}

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
    let scheduler = ManualMenuBarClickScheduler()
    let controller = MenuBarController(doubleClickInterval: 10, clickScheduler: scheduler)
    var toggleCount = 0

    controller.dispatchStatusClick(clickCount: 1) { toggleCount += 1 }

    XCTAssertEqual(toggleCount, 0)
    XCTAssertEqual(scheduler.pendingCount, 1)
    scheduler.runPending()
    XCTAssertEqual(toggleCount, 1)
  }

  @MainActor
  func testDoubleClickCancelsDeferredCaptureBeforeShowingBoard() {
    let center = NotificationCenter()
    let scheduler = ManualMenuBarClickScheduler()
    let controller = MenuBarController(
      notificationCenter: center,
      doubleClickInterval: 10,
      clickScheduler: scheduler)
    var toggleCount = 0
    var showCount = 0
    let observer = center.addObserver(
      forName: .composerShowWindow, object: nil, queue: nil
    ) { _ in showCount += 1 }
    defer { center.removeObserver(observer) }

    controller.dispatchStatusClick(clickCount: 1) { toggleCount += 1 }
    controller.dispatchStatusClick(clickCount: 2) { toggleCount += 1 }
    scheduler.runPending()

    XCTAssertEqual(toggleCount, 0)
    XCTAssertEqual(showCount, 1)
  }

  @MainActor
  func testSupersedingSingleClickSuppressesStaleDeferredAction() {
    let scheduler = ManualMenuBarClickScheduler()
    let controller = MenuBarController(doubleClickInterval: 10, clickScheduler: scheduler)
    var staleToggleCount = 0
    var currentToggleCount = 0

    controller.dispatchStatusClick(clickCount: 1) { staleToggleCount += 1 }
    controller.dispatchStatusClick(clickCount: 1) { currentToggleCount += 1 }
    scheduler.runPending()

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
