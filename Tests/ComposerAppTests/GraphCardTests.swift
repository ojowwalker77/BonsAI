import XCTest
@testable import ComposerApp

/// The line/arrow → graph-card conversion: the perpendicular-partner match that lets an L-sketch's
/// second arrow become the other axis, the in-place kind rewrite (one undo step), and the
/// GraphSpec JSON tolerance that keeps old boards decoding.
@MainActor
final class GraphCardTests: XCTestCase {
  /// In-memory store: `swift test` is unsandboxed, so the shared store IS the user's real board.
  private func makeBoard() -> BoardViewModel {
    BoardViewModel(store: DumpStore(inMemoryOnly: true))
  }

  /// A horizontal arrow (100,220)→(300,220) and a vertical one (100,60)→(100,220) sharing the
  /// corner at (100,220) — the canonical L-sketch of a pair of axes.
  private func seedLSketch(_ board: BoardViewModel) -> (horizontal: UUID, vertical: UUID) {
    let horizontal = CardState(
      kind: .arrow, x: 100, y: 200, w: 200, h: 40, z: 1,
      points: [CanvasPoint(x: 0, y: 0.5), CanvasPoint(x: 1, y: 0.5)])
    let vertical = CardState(
      kind: .arrow, x: 80, y: 60, w: 40, h: 160, z: 2,
      points: [CanvasPoint(x: 0.5, y: 1), CanvasPoint(x: 0.5, y: 0)])
    let ids = board.insertCopies([horizontal, vertical], offset: .zero)
    XCTAssertEqual(ids.count, 2)
    return (ids[0], ids[1])
  }

  private func seedGraphAndEquation(_ board: BoardViewModel,
                                    latex: String = "2x",
                                    equationOrigin: CGPoint = CGPoint(x: 220, y: 20),
                                    tint: Int? = 3) -> (graph: UUID, equation: UUID) {
    let graph = CardState(
      kind: .graph, x: 20, y: 20, w: 160, h: 120, z: 1,
      graph: CardState.GraphSpec())
    let equation = CardState(
      kind: .equation, x: Double(equationOrigin.x), y: Double(equationOrigin.y),
      w: 80, h: 40, z: 2, latex: latex, tint: tint)
    let ids = board.insertCopies([graph, equation], offset: .zero)
    XCTAssertEqual(ids.count, 2)
    return (ids[0], ids[1])
  }

  // MARK: Perpendicular partner

  func testPartnerFindsTheOtherAxisOfAnLSketch() {
    let board = makeBoard()
    let (horizontal, vertical) = seedLSketch(board)
    XCTAssertEqual(board.perpendicularPartner(of: horizontal)?.id, vertical)
    XCTAssertEqual(board.perpendicularPartner(of: vertical)?.id, horizontal)
  }

  func testPartnerIgnoresParallelNeighbors() {
    let board = makeBoard()
    let a = CardState(
      kind: .arrow, x: 100, y: 200, w: 200, h: 40, z: 1,
      points: [CanvasPoint(x: 0, y: 0.5), CanvasPoint(x: 1, y: 0.5)])
    let b = CardState(
      kind: .arrow, x: 100, y: 210, w: 200, h: 40, z: 2,
      points: [CanvasPoint(x: 0, y: 0.5), CanvasPoint(x: 1, y: 0.5)])
    let ids = board.insertCopies([a, b], offset: .zero)
    XCTAssertNil(board.perpendicularPartner(of: ids[0]), "parallel arrows are not an axis pair")
  }

  func testPartnerIgnoresADetachedCorner() {
    let board = makeBoard()
    let horizontal = CardState(
      kind: .arrow, x: 100, y: 200, w: 200, h: 40, z: 1,
      points: [CanvasPoint(x: 0, y: 0.5), CanvasPoint(x: 1, y: 0.5)])
    // Perpendicular, but its nearest endpoint is 60pt from the horizontal's — beyond the 24pt slop.
    let vertical = CardState(
      kind: .arrow, x: 80, y: 40, w: 40, h: 120, z: 2,
      points: [CanvasPoint(x: 0.5, y: 1), CanvasPoint(x: 0.5, y: 0)])
    let ids = board.insertCopies([horizontal, vertical], offset: .zero)
    XCTAssertNil(board.perpendicularPartner(of: ids[0]), "a far corner is two arrows, not axes")
  }

  // MARK: Conversion

  func testConvertRewritesTheArrowAndAbsorbsThePartner() {
    let board = makeBoard()
    let (horizontal, vertical) = seedLSketch(board)
    let spec = CardState.GraphSpec(xLabel: "t", xUnit: "s", yLabel: "v", showGrid: false)

    board.convertElementToGraph(horizontal, spec: spec)

    XCTAssertNil(board.cards.first { $0.id == vertical }, "the partner axis is absorbed")
    guard let graph = board.cards.first(where: { $0.id == horizontal }) else {
      return XCTFail("the converted card keeps its id")
    }
    XCTAssertEqual(graph.elementKind, .graph)
    XCTAssertEqual(graph.graph, spec)
    XCTAssertNil(graph.points)
    XCTAssertNil(graph.startBindingID)
    XCTAssertNil(graph.endBindingID)
    // Union of both frames is (80,60,220,180); it grows right/down to the 320×240 floor.
    XCTAssertEqual(graph.frame.origin, CGPoint(x: 80, y: 60))
    XCTAssertEqual(graph.frame.size, CardState.graphSize)
  }

  func testConvertKeepsAFrameAlreadyLargerThanTheFloor() {
    let board = makeBoard()
    let lone = CardState(
      kind: .arrow, x: 50, y: 50, w: 500, h: 400, z: 1,
      points: [CanvasPoint(x: 0, y: 0.5), CanvasPoint(x: 1, y: 0.5)])
    let ids = board.insertCopies([lone], offset: .zero)
    board.convertElementToGraph(ids[0], spec: CardState.GraphSpec())
    let graph = board.cards.first { $0.id == ids[0] }
    XCTAssertEqual(graph?.frame.size, CGSize(width: 500, height: 400))
  }

  func testConvertIsOneUndoStep() {
    let board = makeBoard()
    let (horizontal, vertical) = seedLSketch(board)
    board.convertElementToGraph(horizontal, spec: CardState.GraphSpec())

    board.undo()

    XCTAssertEqual(board.cards.first { $0.id == horizontal }?.elementKind, .arrow,
                   "one undo restores the converted arrow")
    XCTAssertNotNil(board.cards.first { $0.id == vertical },
                    "the same undo restores the absorbed partner")
  }

  func testConvertIgnoresNonLineCards() {
    let board = makeBoard()
    let text = CardState(kind: .text, text: "note", x: 10, y: 10)
    let ids = board.insertCopies([text], offset: .zero)
    board.convertElementToGraph(ids[0], spec: CardState.GraphSpec())
    XCTAssertEqual(board.cards.first { $0.id == ids[0] }?.elementKind, .text)
  }

  // MARK: GraphSpec serialization

  /// Old boards (and partial agent JSON) carry no graph keys at all — every field defaults.
  func testGraphSpecDecodesFromEmptyObject() throws {
    let spec = try JSONDecoder().decode(CardState.GraphSpec.self, from: Data("{}".utf8))
    XCTAssertEqual(spec, CardState.GraphSpec())
    XCTAssertEqual(spec.xMax, 10)
    XCTAssertTrue(spec.showGrid)
  }

  func testCardStateGraphRoundTrips() throws {
    let card = CardState(
      kind: .graph, x: 80, y: 60, w: 320, h: 240,
      graph: CardState.GraphSpec(xLabel: "t", xUnit: "s", yLabel: "v", yUnit: "m/s",
                                 xMin: -5, xMax: 5, yMin: 0, yMax: 100, showGrid: false))
    let data = try JSONEncoder().encode([card])
    let decoded = try JSONDecoder().decode([CardState].self, from: data)
    XCTAssertEqual(decoded.first?.elementKind, .graph)
    XCTAssertEqual(decoded.first?.graph, card.graph)
  }

  /// The gesture that shipped broken: a SINGLE dragged card commits through `setFrame`, not
  /// `finishMovePreview`, so the drop needs its own absorb call on that path — one undo restores
  /// the equation at its pre-drag position with the series gone.
  func testSingleCardMovePathAbsorbsEquationDroppedOnGraph() {
    let board = makeBoard()
    let seeded = seedGraphAndEquation(board, latex: "2x", equationOrigin: CGPoint(x: 400, y: 400))
    guard let equation = board.cards.first(where: { $0.id == seeded.equation }) else {
      return XCTFail("equation card missing")
    }

    // Mirror BoardCardView.commitMove's single-card branch: setFrame, then the drop hook.
    board.setFrame(seeded.equation, CGRect(x: 60, y: 60, width: equation.w, height: equation.h))
    board.absorbEquationDropIfNeeded(seeded.equation)

    XCTAssertNil(board.cards.first { $0.id == seeded.equation }, "the dropped equation is absorbed")
    XCTAssertEqual(board.cards.first { $0.id == seeded.graph }?.graph?.series.count, 1)

    board.undo()

    let restored = board.cards.first { $0.id == seeded.equation }
    XCTAssertEqual(restored?.frame.origin, CGPoint(x: 400, y: 400), "one undo restores the pre-drag position")
    XCTAssertEqual(board.cards.first { $0.id == seeded.graph }?.graph?.series, [])
  }

  func testAbsorbEquationIntoGraphAppendsSeriesDeletesEquationAndUndoesTogether() {
    let board = makeBoard()
    let seeded = seedGraphAndEquation(board, latex: "\\frac{x}{2}", tint: 4)

    XCTAssertTrue(board.absorbEquationIntoGraph(seeded.equation, into: seeded.graph))

    let graph = board.cards.first { $0.id == seeded.graph }
    XCTAssertEqual(graph?.graph?.series.count, 1)
    XCTAssertEqual(graph?.graph?.series.first?.expression, "\\frac{x}{2}")
    XCTAssertEqual(graph?.graph?.series.first?.label, "\\frac{x}{2}")
    XCTAssertEqual(graph?.graph?.series.first?.tint, 4)
    XCTAssertNil(board.cards.first { $0.id == seeded.equation })

    board.undo()

    XCTAssertNotNil(board.cards.first { $0.id == seeded.equation })
    XCTAssertEqual(board.cards.first { $0.id == seeded.graph }?.graph?.series, [])
  }

  func testAbsorbEquationIntoGraphRejectsUnparseableLatexWithoutMutation() {
    let board = makeBoard()
    let seeded = seedGraphAndEquation(board, latex: "\\boldsymbol{x}")
    let before = board.cards

    XCTAssertFalse(board.absorbEquationIntoGraph(seeded.equation, into: seeded.graph))

    XCTAssertEqual(board.cards, before)
  }

  func testFinishMovePreviewAbsorbsEquationDroppedCenteredOnGraph() {
    let board = makeBoard()
    let seeded = seedGraphAndEquation(board, latex: "x^2+1", equationOrigin: CGPoint(x: 240, y: 30), tint: 2)
    board.select(seeded.equation)

    board.updateMovePreview(by: CGSize(width: -170, height: 30))
    board.finishMovePreview(commit: true)

    XCTAssertNil(board.cards.first { $0.id == seeded.equation })
    XCTAssertEqual(board.cards.first { $0.id == seeded.graph }?.graph?.series.first?.expression, "x^2+1")

    board.undo()

    let equation = board.cards.first { $0.id == seeded.equation }
    XCTAssertEqual(equation?.frame.origin, CGPoint(x: 240, y: 30))
    XCTAssertEqual(board.cards.first { $0.id == seeded.graph }?.graph?.series, [])
  }

  func testFinishMovePreviewDoesNotAbsorbEquationDroppedElsewhere() {
    let board = makeBoard()
    let seeded = seedGraphAndEquation(board, latex: "x^2+1", equationOrigin: CGPoint(x: 240, y: 30))
    board.select(seeded.equation)

    board.updateMovePreview(by: CGSize(width: 30, height: 30))
    board.finishMovePreview(commit: true)

    XCTAssertNotNil(board.cards.first { $0.id == seeded.equation })
    XCTAssertEqual(board.cards.first { $0.id == seeded.graph }?.graph?.series, [])
  }

  func testAddGraphPointCreatesPointsSeries() {
    let board = makeBoard()
    let seeded = seedGraphAndEquation(board)

    board.addGraphPoint(seeded.graph, at: CardState.GraphPoint(x: 1, y: 2, label: "a"))

    let series = board.cards.first { $0.id == seeded.graph }?.graph?.series.first
    XCTAssertNil(series?.expression)
    XCTAssertEqual(series?.points, [CardState.GraphPoint(x: 1, y: 2, label: "a")])
  }

  func testRemoveGraphSeriesRoundTripsThroughUndo() {
    let board = makeBoard()
    let seeded = seedGraphAndEquation(board)
    board.addGraphPoint(seeded.graph, at: CardState.GraphPoint(x: 1, y: 2))
    guard let seriesID = board.cards.first(where: { $0.id == seeded.graph })?.graph?.series.first?.id else {
      return XCTFail("addGraphPoint creates a series")
    }

    board.removeGraphSeries(seeded.graph, seriesID: seriesID)

    XCTAssertEqual(board.cards.first { $0.id == seeded.graph }?.graph?.series, [])

    board.undo()

    XCTAssertEqual(board.cards.first { $0.id == seeded.graph }?.graph?.series.first?.id, seriesID)
  }
}
