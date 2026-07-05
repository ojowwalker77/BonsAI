import CoreGraphics
import XCTest
@testable import ComposerApp

final class ShapeRecognizerTests: XCTestCase {
  func testRecognizesRectangle() {
    var jitter = SeededJitter(seed: 1, amplitude: 1.4)
    let points = jitteredPolyline([
      CGPoint(x: 40, y: 50),
      CGPoint(x: 180, y: 50),
      CGPoint(x: 180, y: 140),
      CGPoint(x: 40, y: 140),
      CGPoint(x: 40, y: 50)
    ], jitter: &jitter)

    let recognition = requireRecognition(points)
    guard case .rectangle(let frame) = recognition.kind else {
      return XCTFail("Expected rectangle, got \(recognition.kind)")
    }
    assertRect(frame, near: CGRect(x: 40, y: 50, width: 140, height: 90), tolerance: 10)
    XCTAssertGreaterThan(recognition.confidence, 0.72)
  }

  func testRecognizesEllipse() {
    var jitter = SeededJitter(seed: 2, amplitude: 1.8)
    let points = ellipsePoints(in: CGRect(x: 60, y: 40, width: 150, height: 90), jitter: &jitter)

    let recognition = requireRecognition(points)
    guard case .ellipse(let frame) = recognition.kind else {
      return XCTFail("Expected ellipse, got \(recognition.kind)")
    }
    assertRect(frame, near: CGRect(x: 60, y: 40, width: 150, height: 90), tolerance: 10)
    XCTAssertGreaterThan(recognition.confidence, 0.72)
  }

  func testRecognizesDiamond() {
    var jitter = SeededJitter(seed: 3, amplitude: 1.6)
    let points = jitteredPolyline([
      CGPoint(x: 120, y: 35),
      CGPoint(x: 210, y: 115),
      CGPoint(x: 120, y: 195),
      CGPoint(x: 30, y: 115),
      CGPoint(x: 120, y: 35)
    ], jitter: &jitter)

    let recognition = requireRecognition(points)
    guard case .diamond(let frame) = recognition.kind else {
      return XCTFail("Expected diamond, got \(recognition.kind)")
    }
    assertRect(frame, near: CGRect(x: 30, y: 35, width: 180, height: 160), tolerance: 10)
    XCTAssertGreaterThan(recognition.confidence, 0.70)
  }

  func testRecognizesDiagonalLine() {
    var jitter = SeededJitter(seed: 4, amplitude: 1.1)
    let points = jitteredLine(from: CGPoint(x: 20, y: 30), to: CGPoint(x: 180, y: 125), jitter: &jitter)

    let recognition = requireRecognition(points)
    guard case .line(let start, let end) = recognition.kind else {
      return XCTFail("Expected line, got \(recognition.kind)")
    }
    assertPoint(start, near: CGPoint(x: 20, y: 30), tolerance: 4)
    assertPoint(end, near: CGPoint(x: 180, y: 125), tolerance: 4)
    XCTAssertGreaterThan(recognition.confidence, 0.80)
  }

  func testRecognizesAxisAlignedLine() {
    var jitter = SeededJitter(seed: 5, amplitude: 1.0)
    let points = jitteredLine(from: CGPoint(x: 25, y: 80), to: CGPoint(x: 190, y: 80), jitter: &jitter)

    let recognition = requireRecognition(points)
    guard case .line(let start, let end) = recognition.kind else {
      return XCTFail("Expected line, got \(recognition.kind)")
    }
    assertPoint(start, near: CGPoint(x: 25, y: 80), tolerance: 4)
    assertPoint(end, near: CGPoint(x: 190, y: 80), tolerance: 4)
  }

  func testRecognizesRightPointingArrow() {
    var jitter = SeededJitter(seed: 6, amplitude: 1.2)
    let points = arrowPoints(
      tail: CGPoint(x: 20, y: 90),
      tip: CGPoint(x: 190, y: 90),
      left: CGPoint(x: 158, y: 70),
      right: CGPoint(x: 158, y: 110),
      jitter: &jitter
    )

    let recognition = requireRecognition(points)
    guard case .arrow(let start, let end) = recognition.kind else {
      return XCTFail("Expected arrow, got \(recognition.kind)")
    }
    assertPoint(start, near: CGPoint(x: 20, y: 90), tolerance: 4)
    assertPoint(end, near: CGPoint(x: 190, y: 90), tolerance: 6)
    XCTAssertGreaterThan(recognition.confidence, 0.75)
  }

  func testRecognizesUpPointingArrow() {
    var jitter = SeededJitter(seed: 7, amplitude: 1.2)
    let points = arrowPoints(
      tail: CGPoint(x: 90, y: 210),
      tip: CGPoint(x: 90, y: 35),
      left: CGPoint(x: 66, y: 70),
      right: CGPoint(x: 114, y: 70),
      jitter: &jitter
    )

    let recognition = requireRecognition(points)
    guard case .arrow(let start, let end) = recognition.kind else {
      return XCTFail("Expected arrow, got \(recognition.kind)")
    }
    assertPoint(start, near: CGPoint(x: 90, y: 210), tolerance: 4)
    assertPoint(end, near: CGPoint(x: 90, y: 35), tolerance: 6)
  }

  func testRejectsSpiral() {
    var jitter = SeededJitter(seed: 8, amplitude: 1.5)
    XCTAssertNil(ShapeRecognizer.recognize(spiralPoints(jitter: &jitter)))
  }

  func testRejectsSineWave() {
    var jitter = SeededJitter(seed: 9, amplitude: 1.0)
    XCTAssertNil(ShapeRecognizer.recognize(sineWavePoints(jitter: &jitter)))
  }

  func testRejectsZZigzag() {
    var jitter = SeededJitter(seed: 10, amplitude: 1.0)
    let points = jitteredPolyline([
      CGPoint(x: 25, y: 40),
      CGPoint(x: 170, y: 40),
      CGPoint(x: 35, y: 130),
      CGPoint(x: 180, y: 130)
    ], jitter: &jitter)
    XCTAssertNil(ShapeRecognizer.recognize(points))
  }

  func testRejectsFivePointStarOutline() {
    var jitter = SeededJitter(seed: 11, amplitude: 1.2)
    XCTAssertNil(ShapeRecognizer.recognize(starPoints(jitter: &jitter)))
  }

  func testRejectsTinySquare() {
    var jitter = SeededJitter(seed: 12, amplitude: 0.4)
    let points = jitteredPolyline([
      CGPoint(x: 10, y: 10),
      CGPoint(x: 25, y: 10),
      CGPoint(x: 25, y: 25),
      CGPoint(x: 10, y: 25),
      CGPoint(x: 10, y: 10)
    ], jitter: &jitter)
    XCTAssertNil(ShapeRecognizer.recognize(points))
  }

  func testRejectsRandomScribble() {
    var rng = SeededLCG(seed: 13)
    var points: [CGPoint] = []
    var current = CGPoint(x: 80, y: 80)
    for _ in 0..<120 {
      current.x += rng.nextDouble(in: -10...10)
      current.y += rng.nextDouble(in: -10...10)
      points.append(current)
    }
    XCTAssertNil(ShapeRecognizer.recognize(points))
  }

  func testRejectsClosedTriangle() {
    var jitter = SeededJitter(seed: 14, amplitude: 1.0)
    let points = jitteredPolyline([
      CGPoint(x: 90, y: 30),
      CGPoint(x: 170, y: 155),
      CGPoint(x: 20, y: 155),
      CGPoint(x: 90, y: 30)
    ], jitter: &jitter)
    XCTAssertNil(ShapeRecognizer.recognize(points))
  }

  private func requireRecognition(
    _ points: [CGPoint],
    file: StaticString = #filePath,
    line: UInt = #line
  ) -> ShapeRecognizer.Recognition {
    guard let recognition = ShapeRecognizer.recognize(points) else {
      XCTFail("Expected recognition", file: file, line: line)
      return ShapeRecognizer.Recognition(kind: .line(start: .zero, end: .zero), confidence: 0)
    }
    return recognition
  }

  private func assertRect(
    _ rect: CGRect,
    near expected: CGRect,
    tolerance: Double,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertEqual(rect.minX, expected.minX, accuracy: tolerance, file: file, line: line)
    XCTAssertEqual(rect.minY, expected.minY, accuracy: tolerance, file: file, line: line)
    XCTAssertEqual(rect.width, expected.width, accuracy: tolerance, file: file, line: line)
    XCTAssertEqual(rect.height, expected.height, accuracy: tolerance, file: file, line: line)
  }

  private func assertPoint(
    _ point: CGPoint,
    near expected: CGPoint,
    tolerance: Double,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertEqual(point.x, expected.x, accuracy: tolerance, file: file, line: line)
    XCTAssertEqual(point.y, expected.y, accuracy: tolerance, file: file, line: line)
  }
}

private struct SeededJitter {
  var rng: SeededLCG
  let amplitude: Double

  init(seed: UInt64, amplitude: Double) {
    rng = SeededLCG(seed: seed)
    self.amplitude = amplitude
  }

  mutating func offset() -> CGPoint {
    CGPoint(
      x: rng.nextDouble(in: -amplitude...amplitude),
      y: rng.nextDouble(in: -amplitude...amplitude)
    )
  }
}

private struct SeededLCG {
  private var state: UInt64

  init(seed: UInt64) {
    state = seed
  }

  mutating func nextDouble(in range: ClosedRange<Double>) -> Double {
    state = state &* 6364136223846793005 &+ 1442695040888963407
    let unit = Double(state >> 11) / Double(1 << 53)
    return range.lowerBound + (range.upperBound - range.lowerBound) * unit
  }
}

private func jitteredPolyline(_ vertices: [CGPoint], jitter: inout SeededJitter, spacing: Double = 1.5) -> [CGPoint] {
  guard vertices.count > 1 else { return vertices }
  var points: [CGPoint] = []
  for index in 1..<vertices.count {
    let start = vertices[index - 1]
    let end = vertices[index]
    let length = hypot(end.x - start.x, end.y - start.y)
    let count = max(2, Int(length / spacing))
    for step in 0..<count {
      if index > 1 && step == 0 { continue }
      let t = Double(step) / Double(count - 1)
      var point = CGPoint(
        x: start.x + (end.x - start.x) * t,
        y: start.y + (end.y - start.y) * t
      )
      let offset = jitter.offset()
      point.x += offset.x
      point.y += offset.y
      points.append(point)
    }
  }
  return points
}

private func jitteredLine(from start: CGPoint, to end: CGPoint, jitter: inout SeededJitter) -> [CGPoint] {
  jitteredPolyline([start, end], jitter: &jitter)
}

private func ellipsePoints(in rect: CGRect, jitter: inout SeededJitter) -> [CGPoint] {
  let count = 220
  return (0...count).map { index in
    let angle = Double(index) / Double(count) * Double.pi * 2
    var point = CGPoint(
      x: rect.midX + cos(angle) * rect.width / 2,
      y: rect.midY + sin(angle) * rect.height / 2
    )
    let offset = jitter.offset()
    point.x += offset.x
    point.y += offset.y
    return point
  }
}

private func arrowPoints(
  tail: CGPoint,
  tip: CGPoint,
  left: CGPoint,
  right: CGPoint,
  jitter: inout SeededJitter
) -> [CGPoint] {
  jitteredPolyline([tail, tip, left, tip, right], jitter: &jitter)
}

private func spiralPoints(jitter: inout SeededJitter) -> [CGPoint] {
  (0..<180).map { index in
    let t = Double(index) / 18
    let radius = 7 + Double(index) * 0.55
    var point = CGPoint(x: 110 + cos(t) * radius, y: 110 + sin(t) * radius)
    let offset = jitter.offset()
    point.x += offset.x
    point.y += offset.y
    return point
  }
}

private func sineWavePoints(jitter: inout SeededJitter) -> [CGPoint] {
  (0..<160).map { index in
    let x = 20 + Double(index) * 1.5
    var point = CGPoint(x: x, y: 95 + sin(Double(index) / 9) * 24)
    let offset = jitter.offset()
    point.x += offset.x
    point.y += offset.y
    return point
  }
}

private func starPoints(jitter: inout SeededJitter) -> [CGPoint] {
  let center = CGPoint(x: 110, y: 110)
  let vertices = (0..<10).map { index -> CGPoint in
    let radius = index.isMultiple(of: 2) ? 85.0 : 34.0
    let angle = -Double.pi / 2 + Double(index) * Double.pi / 5
    return CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
  }
  return jitteredPolyline(vertices + [vertices[0]], jitter: &jitter)
}
