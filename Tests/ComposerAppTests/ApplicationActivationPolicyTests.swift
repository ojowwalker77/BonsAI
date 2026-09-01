import AppKit
import XCTest
@testable import ComposerApp

@MainActor
final class ApplicationActivationPolicyTests: XCTestCase {
  func testVisibleDockResolvesToRegularApplication() {
    XCTAssertEqual(
      ApplicationActivationPolicyController.policy(hidesDockIcon: false),
      .regular
    )
  }

  func testHiddenDockResolvesToAccessoryApplication() {
    XCTAssertEqual(
      ApplicationActivationPolicyController.policy(hidesDockIcon: true),
      .accessory
    )
  }

  func testApplyUsesInjectedPolicySetterAndRestoresVisibleWorkspaceFocus() {
    var appliedPolicies: [NSApplication.ActivationPolicy] = []
    var activationCount = 0
    let controller = ApplicationActivationPolicyController(
      setPolicy: {
        appliedPolicies.append($0)
        return true
      },
      activate: { activationCount += 1 }
    )

    XCTAssertTrue(controller.apply(hidesDockIcon: true, restoreFocus: true))

    XCTAssertEqual(appliedPolicies, [.accessory])
    XCTAssertEqual(activationCount, 1)
  }

  func testApplyLeavesHiddenWorkspaceInactive() {
    var activationCount = 0
    let controller = ApplicationActivationPolicyController(
      setPolicy: { _ in true },
      activate: { activationCount += 1 }
    )

    XCTAssertTrue(controller.apply(hidesDockIcon: false, restoreFocus: false))

    XCTAssertEqual(activationCount, 0)
  }

  func testFailedPolicyChangeDoesNotAttemptToRestoreFocus() {
    var activationCount = 0
    let controller = ApplicationActivationPolicyController(
      setPolicy: { _ in false },
      activate: { activationCount += 1 }
    )

    XCTAssertFalse(controller.apply(hidesDockIcon: true, restoreFocus: true))
    XCTAssertEqual(activationCount, 0)
  }
}
