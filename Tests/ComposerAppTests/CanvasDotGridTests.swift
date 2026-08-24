import XCTest
@testable import ComposerApp

final class CanvasDotGridTests: XCTestCase {
  func testSpacingTracksBoardZoom() {
    XCTAssertEqual(CanvasDotGridLayout.axis(scale: 0.35, translation: 0).spacing, 11.2, accuracy: 0.001)
    XCTAssertEqual(CanvasDotGridLayout.axis(scale: 1, translation: 0).spacing, 32, accuracy: 0.001)
    XCTAssertEqual(CanvasDotGridLayout.axis(scale: 2, translation: 0).spacing, 64, accuracy: 0.001)
  }

  func testPanSetsAStablePositivePhaseInBothDirections() {
    XCTAssertEqual(CanvasDotGridLayout.axis(scale: 1, translation: 7).first, 7, accuracy: 0.001)
    XCTAssertEqual(CanvasDotGridLayout.axis(scale: 1, translation: -7).first, 25, accuracy: 0.001)
    XCTAssertEqual(CanvasDotGridLayout.axis(scale: 1, translation: 39).first, 7, accuracy: 0.001)
    XCTAssertEqual(CanvasDotGridLayout.axis(scale: 1, translation: -39).first, 25, accuracy: 0.001)
  }

  func testEquivalentBoardTranslationsKeepTheSamePhaseAtZoom() {
    let spacing = CanvasDotGridLayout.axis(scale: 1.5, translation: 0).spacing
    let first = CanvasDotGridLayout.axis(scale: 1.5, translation: 13).first
    let repeated = CanvasDotGridLayout.axis(scale: 1.5, translation: 13 + spacing * 4).first
    XCTAssertEqual(first, repeated, accuracy: 0.001)
  }
}
