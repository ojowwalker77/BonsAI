import Foundation
import CoreGraphics

/// Freehand shape recognition for board-space pointer trails.
///
/// Tuned recall-first for real hand sketches (1.4.5 feedback: the original gates demanded
/// near-perfect strokes): wobbly sides, rounded corners, and loops that don't quite close all
/// snap. Letters, zigzags, spirals, stars, and scribbles must still return `nil` — the negative
/// fixtures in ShapeRecognizerTests are the contract.
enum ShapeRecognizer {
  enum Kind: Equatable {
    case rectangle(CGRect)
    case ellipse(CGRect)
    case diamond(CGRect)
    case line(start: CGPoint, end: CGPoint)
    case arrow(start: CGPoint, end: CGPoint)
  }

  /// A recognized clean shape with a confidence in `0...1`.
  struct Recognition: Equatable {
    let kind: Kind
    let confidence: Double
  }

  /// Recognizes a raw ordered pointer trail captured in board coordinates.
  ///
  /// Points should be dense enough to preserve the stroke path. The function resamples to
  /// uniform arc-length spacing, then applies separate open- and closed-stroke classifiers.
  static func recognize(_ points: [CGPoint]) -> Recognition? {
    guard points.count >= 8,
          let rawBounds = bounds(of: points),
          max(rawBounds.width, rawBounds.height) >= 24 else { return nil }

    let cleaned = removeDuplicateNeighbors(points)
    let rawLength = pathLength(cleaned)
    guard rawLength > 0 else { return nil }

    let sampleCount = max(32, min(180, Int(rawLength / 4.0)))
    let points = smooth(resample(cleaned, count: sampleCount))
    guard points.count >= 8,
          let bounds = bounds(of: points),
          max(bounds.width, bounds.height) >= 24 else { return nil }

    let diagonal = hypot(bounds.width, bounds.height)
    guard diagonal > 0 else { return nil }

    let length = pathLength(points)
    let endpointGap = distance(points[0], points[points.count - 1])
    let closed = endpointGap <= diagonal * 0.26 && length >= diagonal * 1.6

    if closed {
      return recognizeClosed(points, bounds: bounds, diagonal: diagonal)
    }

    if let line = recognizeLine(points) {
      return line
    }

    return recognizeArrow(points)
  }

  private static func recognizeClosed(_ points: [CGPoint], bounds: CGRect, diagonal: Double) -> Recognition? {
    guard bounds.width >= 12, bounds.height >= 12 else { return nil }

    let loop = closedLoop(points)
    let corners = dominantCorners(in: loop)
    if corners.count == 4 {
      let cornerPoints = corners.map { loop[$0] }
      if let recognition = recognizeRectangle(cornerPoints, points: loop, diagonal: diagonal) {
        return recognition
      }
      if let recognition = recognizeDiamond(cornerPoints, points: loop, diagonal: diagonal) {
        return recognition
      }
    }

    // Sloppy circles often sprout a phantom corner or two — let the ellipse's own deviation
    // gates decide instead of the corner count alone.
    if corners.count <= 3, let ellipse = recognizeEllipse(loop, bounds: bounds) {
      return ellipse
    }

    // A boxy stroke whose corner detection missed (rounded corners read as 3 or 5 candidates)
    // can still snap when the path hugs its bounding box tightly — the fit gate alone rejects
    // round figures (a circle scores ~0.5 against its bounding square).
    if corners.count != 4, let rectangle = recognizeRectangleByFit(loop, frame: bounds) {
      return rectangle
    }

    return nil
  }

  /// Corner-free rectangle fallback: accept on edge-fit alone, with a stricter bar than the
  /// cornered path since there's no corner-geometry cross-check backing it up.
  private static func recognizeRectangleByFit(_ points: [CGPoint], frame: CGRect) -> Recognition? {
    guard frame.width >= 16, frame.height >= 16 else { return nil }
    let fit = rectangleFitScore(points, frame: frame)
    guard fit >= 0.72 else { return nil }
    return Recognition(kind: .rectangle(frame), confidence: clamp(fit * 0.9))
  }

  private static func recognizeRectangle(_ corners: [CGPoint], points: [CGPoint], diagonal: Double) -> Recognition? {
    guard let frame = bounds(of: corners),
          frame.width >= 16,
          frame.height >= 16 else { return nil }

    let expected = [
      CGPoint(x: frame.minX, y: frame.minY),
      CGPoint(x: frame.maxX, y: frame.minY),
      CGPoint(x: frame.maxX, y: frame.maxY),
      CGPoint(x: frame.minX, y: frame.maxY)
    ]
    guard bestCornerMatchDistance(corners, expected: expected) <= diagonal * 0.24 else { return nil }

    let axisScore = axisAlignedSegmentScore(corners)
    let fitScore = rectangleFitScore(points, frame: frame)
    guard axisScore >= 0.66, fitScore >= 0.6 else { return nil }

    return Recognition(kind: .rectangle(frame), confidence: clamp(0.45 * axisScore + 0.55 * fitScore))
  }

  private static func recognizeDiamond(_ corners: [CGPoint], points: [CGPoint], diagonal: Double) -> Recognition? {
    guard let frame = bounds(of: corners),
          frame.width >= 16,
          frame.height >= 16 else { return nil }

    let expected = [
      CGPoint(x: frame.midX, y: frame.minY),
      CGPoint(x: frame.maxX, y: frame.midY),
      CGPoint(x: frame.midX, y: frame.maxY),
      CGPoint(x: frame.minX, y: frame.midY)
    ]
    guard bestCornerMatchDistance(corners, expected: expected) <= diagonal * 0.24 else { return nil }

    let diagonalScore = diagonalSegmentScore(corners)
    let fitScore = diamondFitScore(points, frame: frame)
    guard diagonalScore >= 0.64, fitScore >= 0.6 else { return nil }

    return Recognition(kind: .diamond(frame), confidence: clamp(0.45 * diagonalScore + 0.55 * fitScore))
  }

  private static func recognizeEllipse(_ points: [CGPoint], bounds: CGRect) -> Recognition? {
    guard bounds.width >= 16, bounds.height >= 16 else { return nil }

    let rx = bounds.width / 2
    let ry = bounds.height / 2
    guard rx > 0, ry > 0 else { return nil }

    var deviations: [Double] = []
    var quadrants: Set<Int> = []
    for point in points {
      let nx = (point.x - bounds.midX) / rx
      let ny = (point.y - bounds.midY) / ry
      let radius = sqrt(nx * nx + ny * ny)
      deviations.append(abs(radius - 1))
      let quadrant = (nx >= 0 ? 1 : 0) + (ny >= 0 ? 2 : 0)
      quadrants.insert(quadrant)
    }

    let mean = deviations.reduce(0, +) / Double(deviations.count)
    let maxDeviation = deviations.max() ?? 1
    guard quadrants.count == 4,
          mean <= 0.16,
          maxDeviation <= 0.42 else { return nil }

    let score = 1 - max(mean / 0.16, maxDeviation / 0.42) * 0.35
    return Recognition(kind: .ellipse(bounds), confidence: clamp(score))
  }

  private static func recognizeLine(_ points: [CGPoint]) -> Recognition? {
    let start = points[0]
    let end = points[points.count - 1]
    let chord = distance(start, end)
    guard chord >= 20 else { return nil }

    let length = pathLength(points)
    let errors = chordErrors(points, start: start, end: end)
    let maxTolerance = max(5, chord * 0.085)
    let rmsTolerance = max(3, chord * 0.045)
    guard length / chord <= 1.16,
          errors.max <= maxTolerance,
          errors.rms <= rmsTolerance else { return nil }

    let straightness = 1 - min(0.35, (length / chord - 1) * 3.0)
    let fit = 1 - min(0.35, errors.rms / rmsTolerance * 0.35)
    return Recognition(kind: .line(start: start, end: end), confidence: clamp(0.5 * straightness + 0.5 * fit))
  }

  private static func recognizeArrow(_ points: [CGPoint]) -> Recognition? {
    let start = points[0]
    guard let tipIndex = firstFarthestPointIndex(from: start, in: points),
          tipIndex > points.count / 2,
          tipIndex < points.count - 4 else { return nil }

    let tip = points[tipIndex]
    let shaftLength = distance(start, tip)
    guard shaftLength >= 24 else { return nil }

    let shaft = Array(points[0...tipIndex])
    let shaftPathLength = pathLength(shaft)
    let shaftErrors = chordErrors(shaft, start: start, end: tip)
    guard shaftPathLength / shaftLength <= 1.16,
          shaftErrors.max <= max(5, shaftLength * 0.09),
          shaftErrors.rms <= max(3, shaftLength * 0.05) else { return nil }

    let afterTip = Array(points[(tipIndex + 1)...])
    let headLength = pathLength([tip] + afterTip)
    guard headLength >= max(10, shaftLength * 0.1),
          headLength <= shaftLength * 0.9 else { return nil }

    let direction = normalized(CGVector(dx: tip.x - start.x, dy: tip.y - start.y))
    var leftArm: Double = 0
    var rightArm: Double = 0
    var forwardOvershoot: Double = 0
    var longestArm: Double = 0

    for point in afterTip {
      let vector = CGVector(dx: point.x - tip.x, dy: point.y - tip.y)
      let along = dot(vector, direction)
      let side = cross(direction, vector)
      let armLength = hypot(vector.dx, vector.dy)
      forwardOvershoot = max(forwardOvershoot, along)

      guard armLength <= shaftLength * 0.48 + 2 else { return nil }
      if along < -max(4, armLength * 0.25), armLength >= max(7, shaftLength * 0.07) {
        longestArm = max(longestArm, armLength)
        if side < 0 {
          leftArm = max(leftArm, armLength)
        } else if side > 0 {
          rightArm = max(rightArm, armLength)
        }
      }
    }

    guard forwardOvershoot <= max(4, shaftLength * 0.06),
          leftArm >= max(6, shaftLength * 0.06),
          rightArm >= max(6, shaftLength * 0.06),
          longestArm <= shaftLength * 0.48 + 2 else { return nil }

    let balance = min(leftArm, rightArm) / max(leftArm, rightArm)
    guard balance >= 0.32 else { return nil }

    let straightness = 1 - min(0.35, shaftErrors.rms / max(2.5, shaftLength * 0.03) * 0.35)
    return Recognition(kind: .arrow(start: start, end: tip), confidence: clamp(0.62 + 0.23 * balance + 0.15 * straightness))
  }

  private static func dominantCorners(in points: [CGPoint]) -> [Int] {
    guard points.count >= 16 else { return [] }

    let count = points.count
    let window = max(3, count / 28)
    var candidates: [(index: Int, score: Double)] = []

    for index in 0..<count {
      let previous = points[(index - window + count) % count]
      let current = points[index]
      let next = points[(index + window) % count]
      let a = CGVector(dx: previous.x - current.x, dy: previous.y - current.y)
      let b = CGVector(dx: next.x - current.x, dy: next.y - current.y)
      let angle = angleBetween(a, b)
      let score = Double.pi - angle
      // ~40° of turn reads as a corner — hand-drawn corners round off well below the ~50° the
      // original gate demanded. Smooth curves stay far under this (a circle turns ~12°/window).
      guard score > 0.7 else { continue }

      let before = cornerScore(points: points, index: (index - 1 + count) % count, window: window)
      let after = cornerScore(points: points, index: (index + 1) % count, window: window)
      if score >= before && score >= after {
        candidates.append((index, score))
      }
    }

    candidates.sort { $0.score > $1.score }
    let minimumSeparation = max(4, count / 9)
    var selected: [(index: Int, score: Double)] = []
    for candidate in candidates {
      guard selected.allSatisfy({ circularDistance(candidate.index, $0.index, count: count) >= minimumSeparation }) else {
        continue
      }
      selected.append(candidate)
      if selected.count == 6 { break }
    }

    guard selected.count <= 5 else { return selected.map(\.index).sorted() }
    return selected.map(\.index).sorted()
  }

  private static func cornerScore(points: [CGPoint], index: Int, window: Int) -> Double {
    let count = points.count
    let previous = points[(index - window + count) % count]
    let current = points[index]
    let next = points[(index + window) % count]
    let a = CGVector(dx: previous.x - current.x, dy: previous.y - current.y)
    let b = CGVector(dx: next.x - current.x, dy: next.y - current.y)
    return Double.pi - angleBetween(a, b)
  }

  private static func axisAlignedSegmentScore(_ corners: [CGPoint]) -> Double {
    var scores: [Double] = []
    for index in 0..<corners.count {
      let a = corners[index]
      let b = corners[(index + 1) % corners.count]
      let dx = abs(b.x - a.x)
      let dy = abs(b.y - a.y)
      let length = max(1, hypot(dx, dy))
      scores.append(max(dx, dy) / length)
    }
    return scores.reduce(0, +) / Double(scores.count)
  }

  private static func diagonalSegmentScore(_ corners: [CGPoint]) -> Double {
    var scores: [Double] = []
    for index in 0..<corners.count {
      let a = corners[index]
      let b = corners[(index + 1) % corners.count]
      let dx = abs(b.x - a.x)
      let dy = abs(b.y - a.y)
      let ratio = min(dx, dy) / max(dx, dy, 1)
      scores.append(1 - abs(ratio - 1) * 0.75)
    }
    return scores.reduce(0, +) / Double(scores.count)
  }

  private static func rectangleFitScore(_ points: [CGPoint], frame: CGRect) -> Double {
    let tolerance = max(5, min(frame.width, frame.height) * 0.16)
    let errors = points.map { point -> Double in
      min(abs(point.x - frame.minX), abs(point.x - frame.maxX), abs(point.y - frame.minY), abs(point.y - frame.maxY))
    }
    return 1 - min(1, rms(errors) / tolerance)
  }

  private static func diamondFitScore(_ points: [CGPoint], frame: CGRect) -> Double {
    let tolerance = max(5, min(frame.width, frame.height) * 0.16)
    let vertices = [
      CGPoint(x: frame.midX, y: frame.minY),
      CGPoint(x: frame.maxX, y: frame.midY),
      CGPoint(x: frame.midX, y: frame.maxY),
      CGPoint(x: frame.minX, y: frame.midY)
    ]
    let errors = points.map { point -> Double in
      var best = Double.greatestFiniteMagnitude
      for index in 0..<vertices.count {
        best = min(best, distanceToSegment(point, vertices[index], vertices[(index + 1) % vertices.count]))
      }
      return best
    }
    return 1 - min(1, rms(errors) / tolerance)
  }

  private static func bestCornerMatchDistance(_ corners: [CGPoint], expected: [CGPoint]) -> Double {
    guard corners.count == expected.count else { return .greatestFiniteMagnitude }

    var best = Double.greatestFiniteMagnitude
    for offset in 0..<corners.count {
      var sum = 0.0
      for index in 0..<corners.count {
        sum += distance(corners[(index + offset) % corners.count], expected[index])
      }
      best = min(best, sum / Double(corners.count))

      sum = 0
      for index in 0..<corners.count {
        let reversed = (offset - index + corners.count) % corners.count
        sum += distance(corners[reversed], expected[index])
      }
      best = min(best, sum / Double(corners.count))
    }
    return best
  }

  private static func chordErrors(_ points: [CGPoint], start: CGPoint, end: CGPoint) -> (max: Double, rms: Double) {
    let errors = points.map { distanceToSegment($0, start, end) }
    return (errors.max() ?? 0, rms(errors))
  }

  private static func resample(_ points: [CGPoint], count: Int) -> [CGPoint] {
    guard points.count > 1, count > 1 else { return points }

    let total = pathLength(points)
    guard total > 0 else { return points }

    let spacing = total / Double(count - 1)
    var result = [points[0]]
    var target = spacing
    var accumulated = 0.0
    var segmentStart = points[0]
    var index = 1

    while index < points.count, result.count < count - 1 {
      let segmentEnd = points[index]
      let segmentLength = distance(segmentStart, segmentEnd)
      if segmentLength == 0 {
        segmentStart = segmentEnd
        index += 1
        continue
      }

      if accumulated + segmentLength >= target {
        let ratio = (target - accumulated) / segmentLength
        let point = CGPoint(
          x: segmentStart.x + (segmentEnd.x - segmentStart.x) * ratio,
          y: segmentStart.y + (segmentEnd.y - segmentStart.y) * ratio
        )
        result.append(point)
        target += spacing
      } else {
        accumulated += segmentLength
        segmentStart = segmentEnd
        index += 1
      }
    }

    result.append(points[points.count - 1])
    return result
  }

  /// Light moving-average over the resampled trail (endpoints pinned). Hand tremor inflates path
  /// length (which broke the line's length/chord gate) and sprays phantom corners around closed
  /// loops (which broke the ellipse's corner-count gate); two 1-2-1 passes tame both, while a real
  /// 90° corner keeps its full turn across the multi-sample corner window.
  private static func smooth(_ points: [CGPoint], passes: Int = 2) -> [CGPoint] {
    guard points.count >= 5 else { return points }
    var result = points
    for _ in 0..<passes {
      var next = result
      for index in 1..<(result.count - 1) {
        next[index] = CGPoint(
          x: (result[index - 1].x + result[index].x * 2 + result[index + 1].x) / 4,
          y: (result[index - 1].y + result[index].y * 2 + result[index + 1].y) / 4
        )
      }
      result = next
    }
    return result
  }

  private static func removeDuplicateNeighbors(_ points: [CGPoint]) -> [CGPoint] {
    var result: [CGPoint] = []
    for point in points {
      if let last = result.last, distance(last, point) < 0.1 {
        continue
      }
      result.append(point)
    }
    return result
  }

  private static func bounds(of points: [CGPoint]) -> CGRect? {
    guard let first = points.first else { return nil }
    var minX = first.x
    var maxX = first.x
    var minY = first.y
    var maxY = first.y

    for point in points.dropFirst() {
      minX = min(minX, point.x)
      maxX = max(maxX, point.x)
      minY = min(minY, point.y)
      maxY = max(maxY, point.y)
    }

    return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
  }

  private static func pathLength(_ points: [CGPoint]) -> Double {
    guard points.count > 1 else { return 0 }
    var length = 0.0
    for index in 1..<points.count {
      length += distance(points[index - 1], points[index])
    }
    return length
  }

  private static func firstFarthestPointIndex(from point: CGPoint, in points: [CGPoint]) -> Int? {
    guard !points.isEmpty else { return nil }
    var bestIndex = 0
    var bestDistance = 0.0
    for (index, candidate) in points.enumerated() {
      let value = distance(point, candidate)
      if value > bestDistance {
        bestDistance = value
        bestIndex = index
      }
    }

    for (index, candidate) in points.enumerated() {
      if bestDistance - distance(point, candidate) <= 3 {
        return index
      }
    }
    return bestIndex
  }

  private static func closedLoop(_ points: [CGPoint]) -> [CGPoint] {
    guard points.count > 2 else { return points }
    var result = points
    let threshold = max(3, pathLength(points) / Double(points.count) * 2)
    while result.count > 2, distance(result[0], result[result.count - 1]) <= threshold {
      result.removeLast()
    }
    return result
  }

  private static func distance(_ a: CGPoint, _ b: CGPoint) -> Double {
    hypot(a.x - b.x, a.y - b.y)
  }

  private static func distanceToSegment(_ point: CGPoint, _ a: CGPoint, _ b: CGPoint) -> Double {
    let ab = CGVector(dx: b.x - a.x, dy: b.y - a.y)
    let ap = CGVector(dx: point.x - a.x, dy: point.y - a.y)
    let lengthSquared = ab.dx * ab.dx + ab.dy * ab.dy
    guard lengthSquared > 0 else { return distance(point, a) }

    let t = max(0, min(1, dot(ap, ab) / lengthSquared))
    let projection = CGPoint(x: a.x + ab.dx * t, y: a.y + ab.dy * t)
    return distance(point, projection)
  }

  private static func angleBetween(_ a: CGVector, _ b: CGVector) -> Double {
    let length = hypot(a.dx, a.dy) * hypot(b.dx, b.dy)
    guard length > 0 else { return 0 }
    let value = max(-1, min(1, dot(a, b) / length))
    return acos(value)
  }

  private static func normalized(_ vector: CGVector) -> CGVector {
    let length = hypot(vector.dx, vector.dy)
    guard length > 0 else { return .zero }
    return CGVector(dx: vector.dx / length, dy: vector.dy / length)
  }

  private static func dot(_ a: CGVector, _ b: CGVector) -> Double {
    a.dx * b.dx + a.dy * b.dy
  }

  private static func cross(_ a: CGVector, _ b: CGVector) -> Double {
    a.dx * b.dy - a.dy * b.dx
  }

  private static func circularDistance(_ a: Int, _ b: Int, count: Int) -> Int {
    let direct = abs(a - b)
    return min(direct, count - direct)
  }

  private static func rms(_ values: [Double]) -> Double {
    guard !values.isEmpty else { return 0 }
    return sqrt(values.reduce(0) { $0 + $1 * $1 } / Double(values.count))
  }

  private static func clamp(_ value: Double) -> Double {
    max(0, min(1, value))
  }
}
