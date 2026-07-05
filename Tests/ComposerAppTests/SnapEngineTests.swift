import XCTest
@testable import ComposerApp

final class SnapEngineTests: XCTestCase {
  func testEdgeToEdgeSnap() {
    let result = SnapEngine.snap(
      moving: CGRect(x: 0, y: 0, width: 10, height: 10),
      proposedDelta: CGSize(width: 9, height: 0),
      others: [CGRect(x: 20, y: 25, width: 10, height: 10)],
      tolerance: 2
    )

    XCTAssertEqual(result.delta, CGSize(width: 10, height: 0))
    XCTAssertEqual(result.guides, [
      SnapEngine.Guide(axis: .vertical, position: 20, start: 0, end: 35)
    ])
  }

  func testCenterToCenterSnap() {
    let result = SnapEngine.snap(
      moving: CGRect(x: 0, y: 0, width: 10, height: 10),
      proposedDelta: CGSize(width: 104, height: 0),
      others: [CGRect(x: 100, y: 20, width: 20, height: 20)],
      tolerance: 2
    )

    XCTAssertEqual(result.delta, CGSize(width: 105, height: 0))
    XCTAssertEqual(result.guides, [
      SnapEngine.Guide(axis: .vertical, position: 110, start: 0, end: 40)
    ])
  }

  func testBothAxesSnapAtOnce() {
    let result = SnapEngine.snap(
      moving: CGRect(x: 0, y: 0, width: 10, height: 10),
      proposedDelta: CGSize(width: 9, height: 19),
      others: [CGRect(x: 20, y: 30, width: 10, height: 10)],
      tolerance: 2
    )

    XCTAssertEqual(result.delta, CGSize(width: 10, height: 20))
    XCTAssertEqual(result.guides, [
      SnapEngine.Guide(axis: .vertical, position: 20, start: 20, end: 40),
      SnapEngine.Guide(axis: .horizontal, position: 30, start: 10, end: 30)
    ])
  }

  func testSmallestAdjustmentWinsWhenMultipleCandidatesAreInTolerance() {
    let result = SnapEngine.snap(
      moving: CGRect(x: 0, y: 0, width: 100, height: 20),
      proposedDelta: .zero,
      others: [
        CGRect(x: 103, y: 37, width: 20, height: 20),
        CGRect(x: 86, y: 82, width: 20, height: 20)
      ],
      tolerance: 5
    )

    XCTAssertEqual(result.delta, CGSize(width: 3, height: 0))
    XCTAssertEqual(result.guides, [
      SnapEngine.Guide(axis: .vertical, position: 103, start: 0, end: 57)
    ])
  }

  func testGuideSpanCoversMovingAndAlignedRect() {
    let result = SnapEngine.snap(
      moving: CGRect(x: 0, y: 50, width: 10, height: 10),
      proposedDelta: CGSize(width: 9, height: 0),
      others: [CGRect(x: 20, y: -10, width: 10, height: 15)],
      tolerance: 2
    )

    XCTAssertEqual(result.guides, [
      SnapEngine.Guide(axis: .vertical, position: 20, start: -10, end: 60)
    ])
  }

  func testMultiRectSharedGuideMergesIntoOne() {
    let result = SnapEngine.snap(
      moving: CGRect(x: 0, y: 0, width: 10, height: 10),
      proposedDelta: CGSize(width: 9, height: 0),
      others: [
        CGRect(x: 20, y: 40, width: 10, height: 10),
        CGRect(x: 20, y: -20, width: 15, height: 10)
      ],
      tolerance: 2
    )

    XCTAssertEqual(result.guides, [
      SnapEngine.Guide(axis: .vertical, position: 20, start: -20, end: 50)
    ])
  }

  func testNoCandidatesPassesThroughDeltaAndHasNoGuides() {
    let proposed = CGSize(width: 7, height: -4)
    let result = SnapEngine.snap(
      moving: CGRect(x: 0, y: 0, width: 10, height: 10),
      proposedDelta: proposed,
      others: [CGRect(x: 100, y: 100, width: 10, height: 10)],
      tolerance: 2
    )

    XCTAssertEqual(result.delta, proposed)
    XCTAssertEqual(result.guides, [])
  }

  func testToleranceBoundaryIsInclusiveButJustPastDoesNotSnap() {
    let moving = CGRect(x: 0, y: 0, width: 10, height: 10)
    let other = CGRect(x: 20, y: 40, width: 10, height: 10)

    let exact = SnapEngine.snap(
      moving: moving,
      proposedDelta: CGSize(width: 8, height: 0),
      others: [other],
      tolerance: 2
    )
    XCTAssertEqual(exact.delta, CGSize(width: 10, height: 0))
    XCTAssertEqual(exact.guides, [
      SnapEngine.Guide(axis: .vertical, position: 20, start: 0, end: 50)
    ])

    let justPast = SnapEngine.snap(
      moving: moving,
      proposedDelta: CGSize(width: 7.99, height: 0),
      others: [other],
      tolerance: 2
    )
    XCTAssertEqual(justPast.delta.width, 7.99, accuracy: 0.000001)
    XCTAssertEqual(justPast.delta.height, 0, accuracy: 0.000001)
    XCTAssertEqual(justPast.guides, [])
  }

  func testZeroSizeOthersAreIgnoredGracefully() {
    let result = SnapEngine.snap(
      moving: CGRect(x: 0, y: 0, width: 10, height: 10),
      proposedDelta: CGSize(width: 9, height: 0),
      others: [
        CGRect(x: 20, y: 0, width: 0, height: 0),
        CGRect(x: 100, y: 100, width: 10, height: 10)
      ],
      tolerance: 2
    )

    XCTAssertEqual(result.delta, CGSize(width: 9, height: 0))
    XCTAssertEqual(result.guides, [])
  }
}
