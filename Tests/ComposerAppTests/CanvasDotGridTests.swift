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

  func testMinZoomUsesAdaptiveBoardStrideAndScreenSpaceSeparation() {
    let layout = CanvasDotGridLayout.layout(
      scale: 0.35,
      translation: .zero,
      viewportSize: CGSize(width: 3840, height: 2160))

    XCTAssertGreaterThan(layout.boardStep, 1)
    XCTAssertGreaterThanOrEqual(
      layout.xAxis.spacing, CanvasDotGridLayout.minimumScreenSpacing)
    XCTAssertEqual(layout.xAxis.spacing, layout.yAxis.spacing, accuracy: 0.001)
  }

  func testLargeRetinaViewportNeverExceedsDotBudgetAtMinZoom() {
    let layout = CanvasDotGridLayout.layout(
      scale: 0.35,
      translation: CGSize(width: -17, height: 29),
      viewportSize: CGSize(width: 7680, height: 4320))

    XCTAssertLessThanOrEqual(layout.dotCount, CanvasDotGridLayout.maximumDotCount)
  }

  func testLowZoomPanPhasesStayWithinThePerFramePathBudget() {
    let viewport = CGSize(width: 7680, height: 4320)
    let translations = stride(from: -120, through: 120, by: 12).map {
      CGSize(width: CGFloat($0), height: CGFloat(-$0 / 2))
    }
    let layouts = translations.map {
      CanvasDotGridLayout.layout(scale: 0.35, translation: $0, viewportSize: viewport)
    }

    XCTAssertTrue(layouts.allSatisfy { $0.dotCount <= 4_000 })
    XCTAssertGreaterThanOrEqual(layouts.map(\.boardStep).min() ?? 0, 9)
    XCTAssertLessThan(layouts.map(\.dotCount).max() ?? .max, 3_500)
  }

  func testAdaptiveStrideKeepsPhaseStableAcrossEquivalentTranslations() {
    let size = CGSize(width: 5120, height: 2880)
    let original = CanvasDotGridLayout.layout(
      scale: 0.35, translation: CGSize(width: 13, height: -9), viewportSize: size)
    let repeated = CanvasDotGridLayout.layout(
      scale: 0.35,
      translation: CGSize(
        width: 13 + original.xAxis.spacing * 4,
        height: -9 - original.yAxis.spacing * 3),
      viewportSize: size)

    XCTAssertEqual(original.boardStep, repeated.boardStep)
    XCTAssertEqual(original.xAxis.first, repeated.xAxis.first, accuracy: 0.001)
    XCTAssertEqual(original.yAxis.first, repeated.yAxis.first, accuracy: 0.001)
  }
}
