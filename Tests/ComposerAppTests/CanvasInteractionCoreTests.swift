import SwiftUI
import XCTest
@testable import ComposerApp

/// Phase 1 of the canvas rebuild: one pointer owner, real-shape hit testing, one selection box,
/// live in-flight geometry, and one undo step per gesture.
final class CanvasGeometryCoreTests: XCTestCase {
  // MARK: Viewport

  func testViewportRoundTripsPointsAndRects() {
    let viewport = CanvasViewport(scale: 2, pan: CGSize(width: 30, height: -10))
    let board = CGPoint(x: 12, y: 40)
    XCTAssertEqual(viewport.boardPoint(viewport.viewportPoint(board)), board)
    let rect = CGRect(x: 5, y: 6, width: 70, height: 80)
    XCTAssertEqual(viewport.boardRect(viewport.viewportRect(rect)), rect)
    XCTAssertEqual(viewport.boardDistance(8), 4)
  }

  func testZoomKeepsTheAnchoredBoardPointUnderThePointer() {
    let viewport = CanvasViewport(scale: 1, pan: CGSize(width: 100, height: 50))
    let anchor = CGPoint(x: 400, y: 300)
    let pinned = viewport.boardPoint(anchor)
    let zoomed = viewport.zoomed(to: 2.5, anchoredAt: anchor)
    XCTAssertEqual(zoomed.scale, 2.5)
    XCTAssertEqual(zoomed.boardPoint(anchor).x, pinned.x, accuracy: 1e-9)
    XCTAssertEqual(zoomed.boardPoint(anchor).y, pinned.y, accuracy: 1e-9)
    XCTAssertEqual(viewport.zoomed(to: 100, anchoredAt: anchor).scale, CanvasViewport.maxScale)
    XCTAssertEqual(viewport.zoomed(to: 0, anchoredAt: anchor).scale, CanvasViewport.minScale)
  }

  // MARK: Element hit testing

  private let slop = ElementGeometry.Slop(fill: 0, stroke: 4)

  func testEllipseAndDiamondCornersAreNotPartOfTheShape() {
    for kind in [CanvasElementKind.ellipse, .diamond] {
      let card = CardState(kind: kind, x: 0, y: 0, w: 200, h: 100)
      XCTAssertTrue(ElementGeometry.hits(card, at: CGPoint(x: 100, y: 50), slop: slop), "\(kind) centre")
      XCTAssertFalse(ElementGeometry.hits(card, at: CGPoint(x: 8, y: 8), slop: slop), "\(kind) corner")
    }
  }

  func testArrowIsHitOnItsStrokeNotItsPaddedFrame() {
    let arrow = CardState(kind: .arrow, x: 0, y: 0, w: 200, h: 200, points: [
      CanvasPoint(x: 0.1, y: 0.1), CanvasPoint(x: 0.9, y: 0.9),
    ])
    XCTAssertTrue(ElementGeometry.hits(arrow, at: CGPoint(x: 100, y: 102), slop: slop))
    XCTAssertFalse(ElementGeometry.hits(arrow, at: CGPoint(x: 170, y: 30), slop: slop),
                   "the empty corner of a diagonal arrow's frame must not grab clicks")
    XCTAssertEqual(ElementGeometry.bounds(of: arrow), CGRect(x: 20, y: 20, width: 160, height: 160))
  }

  func testFreehandIsHitNearItsStrokeOnly() {
    let stroke = CardState(kind: .freehand, x: 0, y: 0, w: 100, h: 100, points: [
      CanvasPoint(x: 0, y: 0), CanvasPoint(x: 1, y: 0),
    ])
    XCTAssertTrue(ElementGeometry.hits(stroke, at: CGPoint(x: 50, y: 3), slop: slop))
    XCTAssertFalse(ElementGeometry.hits(stroke, at: CGPoint(x: 50, y: 60), slop: slop))
  }

  func testTopmostHitFollowsPaintOrder() {
    let below = CardState(kind: .rectangle, x: 0, y: 0, w: 100, h: 100, z: 5)
    let above = CardState(kind: .rectangle, x: 50, y: 50, w: 100, h: 100, z: 9)
    let tieLater = CardState(kind: .rectangle, x: 50, y: 50, w: 100, h: 100, z: 9)
    let point = CGPoint(x: 75, y: 75)
    XCTAssertEqual(CanvasHitTester.topmost(at: point, in: [above, below], slop: slop)?.id, above.id)
    XCTAssertEqual(CanvasHitTester.topmost(at: point, in: [below, above, tieLater], slop: slop)?.id, tieLater.id)
  }

  func testMarqueeSelectsOnlyElementsEntirelyInside() {
    let inside = CardState(kind: .rectangle, x: 10, y: 10, w: 50, h: 50)
    let straddling = CardState(kind: .rectangle, x: 80, y: 10, w: 100, h: 50)
    let hits = CanvasHitTester.contained(in: CGRect(x: 0, y: 0, width: 120, height: 100),
                                         cards: [inside, straddling])
    XCTAssertEqual(hits.map(\.id), [inside.id])
  }

  // MARK: Resize math

  func testFreeCornerResizeAnchorsTheOppositeCorner() {
    let base = CGRect(x: 0, y: 0, width: 100, height: 50)
    let result = SelectionResize.bounds(base, handle: .topLeft, delta: CGSize(width: 20, height: 10),
                                        keepAspect: false, fromCenter: false, minSize: .zero)
    XCTAssertEqual(result, CGRect(x: 20, y: 10, width: 80, height: 40))
  }

  func testAspectLockedResizeFollowsTheDominantAxis() {
    let base = CGRect(x: 0, y: 0, width: 100, height: 50)
    let result = SelectionResize.bounds(base, handle: .bottomRight, delta: CGSize(width: 100, height: 5),
                                        keepAspect: true, fromCenter: false, minSize: .zero)
    XCTAssertEqual(result, CGRect(x: 0, y: 0, width: 200, height: 100))
  }

  func testFromCenterResizeMirrorsTheDrag() {
    let base = CGRect(x: 0, y: 0, width: 100, height: 100)
    let result = SelectionResize.bounds(base, handle: .right, delta: CGSize(width: 10, height: 0),
                                        keepAspect: false, fromCenter: true, minSize: .zero)
    XCTAssertEqual(result, CGRect(x: -10, y: 0, width: 120, height: 100))
  }

  func testResizeStopsAtTheMinimumAndNeverFlips() {
    let base = CGRect(x: 0, y: 0, width: 100, height: 100)
    let result = SelectionResize.bounds(base, handle: .left, delta: CGSize(width: 500, height: 0),
                                        keepAspect: false, fromCenter: false,
                                        minSize: CGSize(width: 30, height: 30))
    XCTAssertEqual(result, CGRect(x: 70, y: 0, width: 30, height: 100))
  }

  func testMappedFrameScalesWithItsBox() {
    let mapped = SelectionResize.mapped(CGRect(x: 50, y: 50, width: 50, height: 50),
                                        from: CGRect(x: 0, y: 0, width: 100, height: 100),
                                        to: CGRect(x: 0, y: 0, width: 200, height: 200))
    XCTAssertEqual(mapped, CGRect(x: 100, y: 100, width: 100, height: 100))
  }

  // MARK: Selection chrome

  private let identity = CanvasViewport()

  func testSingleShapeOffersEveryHandlePortsAndDelete() {
    let shape = CardState(kind: .rectangle, x: 100, y: 100, w: 200, h: 100)
    let chrome = SelectionChrome.resolve(selected: [shape], editingID: nil, viewport: identity, interactive: true)
    XCTAssertEqual(Set(chrome.handles), Set(SelectionHandle.allCases))
    XCTAssertEqual(chrome.ports.count, 4)
    XCTAssertNotNil(chrome.deleteCenter)
    let box = try! XCTUnwrap(chrome.box)
    XCTAssertEqual(chrome.hit(SelectionHandle.bottomRight.point(on: box)), .handle(.bottomRight))
    XCTAssertEqual(chrome.hit(CGPoint(x: box.minX + 30, y: box.maxY)), .handle(.bottom))
    XCTAssertEqual(chrome.hit(CGPoint(x: box.midX, y: box.maxY + 9)), .quickConnect(shape.id, .down),
                   "the visible port wins over the invisible edge band it overlaps")
  }

  func testConnectorIsManipulatedByItsEndpointsAlone() {
    let line = CardState(kind: .line, x: 0, y: 0, w: 100, h: 100, points: [
      CanvasPoint(x: 0, y: 0), CanvasPoint(x: 1, y: 1),
    ])
    let chrome = SelectionChrome.resolve(selected: [line], editingID: nil, viewport: identity, interactive: true)
    XCTAssertNil(chrome.box)
    XCTAssertEqual(chrome.endpoints.map(\.endpoint), [.start, .end])
    XCTAssertEqual(chrome.hit(CGPoint(x: 99, y: 101)), .endpoint(line.id, .end))
  }

  func testMultipleSelectionScalesFromCornersOnly() {
    let a = CardState(kind: .rectangle, x: 0, y: 0, w: 100, h: 100)
    let b = CardState(kind: .ellipse, x: 300, y: 0, w: 100, h: 100)
    let chrome = SelectionChrome.resolve(selected: [a, b], editingID: nil, viewport: identity, interactive: true)
    XCTAssertTrue(chrome.isMultiple)
    XCTAssertEqual(Set(chrome.handles), Set(SelectionHandle.corners))
    XCTAssertEqual(chrome.elementOutlines.count, 2)
    XCTAssertTrue(chrome.ports.isEmpty)
  }

  func testLockedEditingAndNonSelectToolsOfferNoHandles() {
    let locked = CardState(kind: .rectangle, x: 0, y: 0, w: 100, h: 100, isLocked: true)
    XCTAssertTrue(SelectionChrome.resolve(selected: [locked], editingID: nil, viewport: identity,
                                          interactive: true).handles.isEmpty)
    let text = CardState(text: "hi", x: 0, y: 0, w: 100, h: 40)
    XCTAssertTrue(SelectionChrome.resolve(selected: [text], editingID: text.id, viewport: identity,
                                          interactive: true).isEmpty, "a text caret is not a boxed object")
    let shape = CardState(kind: .rectangle, x: 0, y: 0, w: 100, h: 100)
    XCTAssertTrue(SelectionChrome.resolve(selected: [shape], editingID: nil, viewport: identity,
                                          interactive: false).handles.isEmpty)
  }

  func testMixedLockedMultiSelectionCanBeDeletedButNotScaled() {
    let locked = CardState(kind: .rectangle, x: 0, y: 0, w: 100, h: 100, isLocked: true)
    let free = CardState(kind: .ellipse, x: 300, y: 0, w: 100, h: 100)
    let mixed = SelectionChrome.resolve(selected: [locked, free], editingID: nil, viewport: identity,
                                        interactive: true)
    XCTAssertNotNil(mixed.box)
    XCTAssertTrue(mixed.handles.isEmpty, "scaling would leave the locked member behind")
    XCTAssertNotNil(mixed.deleteCenter)

    let alsoLocked = CardState(kind: .ellipse, x: 300, y: 0, w: 100, h: 100, isLocked: true)
    let frozen = SelectionChrome.resolve(selected: [locked, alsoLocked], editingID: nil, viewport: identity,
                                         interactive: true)
    XCTAssertNotNil(frozen.box)
    XCTAssertNil(frozen.deleteCenter, "nothing in an all-locked selection can be deleted")
  }

  // MARK: Keys

  func testExcalidrawLayerShortcuts() {
    XCTAssertEqual(FloatingPanel.zOrderMove(flags: [.command], key: "]"), .forward)
    XCTAssertEqual(FloatingPanel.zOrderMove(flags: [.command], key: "["), .backward)
    XCTAssertEqual(FloatingPanel.zOrderMove(flags: [.command, .shift], key: "}"), .toFront)
    XCTAssertEqual(FloatingPanel.zOrderMove(flags: [.command, .shift], key: "{"), .toBack)
    XCTAssertNil(FloatingPanel.zOrderMove(flags: [.command, .option], key: "["), "⌥⌘[ switches boards")
    XCTAssertEqual(FloatingPanel.nudge(keyCode: 123, shift: false), CGSize(width: -1, height: 0))
    XCTAssertEqual(FloatingPanel.nudge(keyCode: 125, shift: true), CGSize(width: 0, height: 5))
  }
}

/// The Select tool's pointer controller, driven end to end against an in-memory board.
@MainActor
final class CanvasSelectGestureTests: XCTestCase {
  private var board: BoardViewModel!
  private var viewport = CanvasViewport()
  private var gesture: CanvasSelectGesture!
  private var marquee: CGRect?
  private var doubleClickedEmpty: CGPoint?

  override func setUp() async throws {
    board = BoardViewModel(store: DumpStore(inMemoryOnly: true, loadInitialContent: false))
    viewport = CanvasViewport()
    gesture = CanvasSelectGesture(board: board, viewport: { [unowned self] in self.viewport })
    gesture.callbacks.marqueeChanged = { [unowned self] in self.marquee = $0 }
    gesture.callbacks.doubleClickedEmpty = { [unowned self] in self.doubleClickedEmpty = $0 }
  }

  private func frame(_ id: UUID) -> CGRect { board.cards.first { $0.id == id }!.frame }
  private func center(_ id: UUID) -> CGPoint { CGPoint(x: frame(id).midX, y: frame(id).midY) }

  private func drag(_ from: CGPoint, _ to: CGPoint, modifiers: EventModifiers = [], release: Bool = true) {
    gesture.press(at: from, modifiers: modifiers, clickCount: 1)
    gesture.drag(to: CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2), modifiers: modifiers)
    gesture.drag(to: to, modifiers: modifiers)
    if release { gesture.release(at: to, modifiers: modifiers) }
  }

  private func click(_ point: CGPoint, modifiers: EventModifiers = []) {
    gesture.press(at: point, modifiers: modifiers, clickCount: 1)
    gesture.release(at: point, modifiers: modifiers)
  }

  // MARK: Move

  func testPressAndDragMovesAnElementAsOneUndoStep() {
    let id = board.addElement(.rectangle, at: CGPoint(x: 600, y: 400))
    board.deselectAll()
    let before = frame(id)

    drag(center(id), CGPoint(x: center(id).x + 120, y: center(id).y + 30))

    XCTAssertEqual(frame(id).minX, before.minX + 120, accuracy: 0.001)
    XCTAssertEqual(frame(id).minY, before.minY + 30, accuracy: 0.001)
    XCTAssertEqual(board.selectedCardIDs, [id], "one press both selects and moves")
    board.undo()
    XCTAssertEqual(frame(id), before)
  }

  func testDraggedElementPreviewsWithoutCommittingAndArrowsFollowLive() throws {
    let source = board.addElement(.rectangle, at: CGPoint(x: 300, y: 300))
    let target = board.addElement(.ellipse, at: CGPoint(x: 900, y: 300))
    let arrowID = try XCTUnwrap(board.connectCards(from: source, to: target))
    let committedArrow = try XCTUnwrap(board.cards.first { $0.id == arrowID })
    board.deselectAll()

    drag(center(target), CGPoint(x: center(target).x, y: center(target).y + 200), release: false)

    XCTAssertEqual(board.cards.first { $0.id == arrowID }, committedArrow, "nothing commits mid-drag")
    let liveArrow = try XCTUnwrap(board.renderedCard(arrowID))
    XCTAssertNotEqual(liveArrow.frame, committedArrow.frame, "the bound arrow reroutes while dragging")
    XCTAssertEqual(board.renderedCard(target)?.frame.minY ?? 0, frame(target).minY + 200, accuracy: 0.001)

    gesture.release(at: CGPoint(x: center(target).x, y: center(target).y + 200), modifiers: [])
    XCTAssertTrue(board.gesturePreview.isEmpty)
    XCTAssertEqual(board.cards.first { $0.id == arrowID }?.frame, liveArrow.frame,
                   "what the drag showed is exactly what committed")
  }

  func testShiftDragLocksToTheDominantAxis() {
    let id = board.addElement(.rectangle, at: CGPoint(x: 600, y: 400))
    board.deselectAll()
    let before = frame(id)
    drag(center(id), CGPoint(x: center(id).x + 150, y: center(id).y + 20), modifiers: [.shift])
    XCTAssertEqual(frame(id).minY, before.minY, accuracy: 0.001)
  }

  func testScrollingMidDragKeepsTheElementUnderThePointer() {
    let id = board.addElement(.rectangle, at: CGPoint(x: 600, y: 400))
    board.deselectAll()
    let before = frame(id)
    let pointer = CGPoint(x: center(id).x + 50, y: center(id).y)
    drag(center(id), pointer, release: false)

    viewport = viewport.panned(by: CGSize(width: -100, height: 0))   // the board scrolls left
    gesture.viewportChanged()
    gesture.release(at: pointer, modifiers: [])

    XCTAssertEqual(frame(id).minX, before.minX + 150, accuracy: 0.001,
                   "the element tracks the board point under the pointer")
  }

  func testOptionDragDuplicatesAsOneUndoStep() {
    let id = board.addElement(.rectangle, at: CGPoint(x: 600, y: 400))
    board.deselectAll()
    let count = board.cards.count
    drag(center(id), CGPoint(x: center(id).x + 300, y: center(id).y), modifiers: [.option])
    XCTAssertEqual(board.cards.count, count + 1)
    XCTAssertFalse(board.selectedCardIDs.contains(id), "the copy is what moved")
    board.undo()
    XCTAssertEqual(board.cards.count, count)
  }

  func testEscapeMidDragCommitsNothing() {
    let id = board.addElement(.rectangle, at: CGPoint(x: 600, y: 400))
    board.deselectAll()
    let before = board.cards
    drag(center(id), CGPoint(x: center(id).x + 200, y: center(id).y), release: false)
    gesture.cancel()
    gesture.release(at: CGPoint(x: center(id).x + 200, y: center(id).y), modifiers: [])
    XCTAssertEqual(board.cards, before)
    XCTAssertTrue(board.gesturePreview.isEmpty)
  }

  // MARK: Selection

  func testClickingAShapesEmptyCornerSelectsNothing() {
    let id = board.addElement(.ellipse, at: CGPoint(x: 600, y: 400))
    board.deselectAll()
    click(CGPoint(x: frame(id).minX + 6, y: frame(id).minY + 6))
    XCTAssertTrue(board.selectedCardIDs.isEmpty)
  }

  func testClickOnAMemberOfAMultiSelectionNarrowsToIt() {
    let a = board.addElement(.rectangle, at: CGPoint(x: 400, y: 400))
    let b = board.addElement(.rectangle, at: CGPoint(x: 900, y: 400))
    board.selectAll()
    click(center(a))
    XCTAssertEqual(board.selectedCardIDs, [a])
    click(center(b), modifiers: [.shift])
    XCTAssertEqual(board.selectedCardIDs, [a, b])
    click(center(a), modifiers: [.shift])
    XCTAssertEqual(board.selectedCardIDs, [b])
  }

  func testMarqueeSelectsByContainment() {
    let small = board.addElement(.rectangle, at: CGPoint(x: 400, y: 400))
    _ = board.addElement(.rectangle, at: CGPoint(x: 700, y: 400))
    board.deselectAll()
    let smallFrame = frame(small)
    drag(CGPoint(x: smallFrame.minX - 20, y: smallFrame.minY - 20),
         CGPoint(x: smallFrame.maxX + 120, y: smallFrame.maxY + 20))
    XCTAssertNil(marquee, "the marquee clears on release")
    XCTAssertEqual(board.selectedCardIDs, [small], "the partly covered neighbour stays out")
  }

  func testLockedElementClickSelectsButDragSweepsAMarquee() {
    let background = board.addElement(.rectangle, at: CGPoint(x: 600, y: 400))
    board.lockSelection(true)
    board.deselectAll()
    let before = frame(background)

    drag(center(background), CGPoint(x: center(background).x + 80, y: center(background).y + 40),
         release: false)
    XCTAssertNotNil(marquee)
    gesture.release(at: CGPoint(x: center(background).x + 80, y: center(background).y + 40), modifiers: [])
    XCTAssertEqual(frame(background), before)

    click(center(background))
    XCTAssertEqual(board.selectedCardIDs, [background], "clicking a locked element still selects it to unlock")
  }

  func testDoubleClickEditsAnElementOrStartsWritingOnEmptyBoard() {
    let id = board.addElement(.rectangle, at: CGPoint(x: 600, y: 400))
    gesture.press(at: center(id), modifiers: [], clickCount: 2)
    gesture.release(at: center(id), modifiers: [])
    XCTAssertEqual(board.editingCardID, id)

    gesture.press(at: CGPoint(x: 50, y: 900), modifiers: [], clickCount: 2)
    gesture.release(at: CGPoint(x: 50, y: 900), modifiers: [])
    XCTAssertEqual(doubleClickedEmpty, CGPoint(x: 50, y: 900))
  }

  func testQuickClicksOnAPortGrowAChainInsteadOfEditing() throws {
    _ = board.addElement(.rectangle, at: CGPoint(x: 300, y: 400))
    let count = board.cards.count
    func rightPort() throws -> CGPoint {
      let selected = board.renderedCards.filter { board.selectedCardIDs.contains($0.id) }
      let chrome = SelectionChrome.resolve(selected: selected, editingID: nil, viewport: viewport,
                                           interactive: true)
      return try XCTUnwrap(chrome.ports.first { $0.direction == .right }).point
    }

    let first = try rightPort()
    gesture.press(at: first, modifiers: [], clickCount: 1)
    gesture.release(at: first, modifiers: [])
    let second = try rightPort()   // the selection advanced to the new peer
    gesture.press(at: second, modifiers: [], clickCount: 2)
    gesture.release(at: second, modifiers: [])

    XCTAssertEqual(board.cards.count, count + 4, "two peers and two arrows")
    XCTAssertNil(board.editingCardID, "the second click of a double-click still acts on the port")
  }

  // MARK: Board replaced mid-gesture

  func testBoardReloadMidDragAbandonsTheGesture() {
    let id = board.addElement(.rectangle, at: CGPoint(x: 600, y: 400))
    board.deselectAll()
    let to = CGPoint(x: center(id).x + 200, y: center(id).y)
    drag(center(id), to, modifiers: [.option], release: false)   // an open ⌥-duplicate transaction
    XCTAssertTrue(board.hasOpenTransaction)

    board.loadFromStore()   // a board switch or reload under the live press
    let reloaded = board.cards
    XCTAssertFalse(board.hasOpenTransaction, "the outgoing board's gesture is retired")

    gesture.drag(to: CGPoint(x: to.x + 50, y: to.y), modifiers: [.option])
    gesture.release(at: CGPoint(x: to.x + 50, y: to.y), modifiers: [.option])
    XCTAssertEqual(board.cards, reloaded, "the stale press changes nothing on the new board")
    XCTAssertTrue(board.gesturePreview.isEmpty)
    XCTAssertNil(marquee)
  }

  // MARK: Graphs

  func testDraggingAGraphMarkerPreviewsThenCommitsOnce() throws {
    let id = board.addElement(.graph, at: CGPoint(x: 600, y: 400))
    let series = CardState.GraphSeries(points: [CardState.GraphPoint(x: 2, y: 2),
                                                CardState.GraphPoint(x: 5, y: 5, label: "peak")])
    board.setGraphSpec(id, CardState.GraphSpec(series: [series]))
    board.select(id)
    let card = try XCTUnwrap(board.cards.first { $0.id == id })
    let spec = try XCTUnwrap(card.graph)
    let geometry = GraphGeometry(spec: spec, size: CGSize(width: card.frame.width - 4,
                                                          height: card.frame.height - 4))
    let marker = geometry.viewPoint(try XCTUnwrap(spec.series.first?.points?[1]))
    let pointer = CGPoint(x: card.frame.minX + 2 + marker.x, y: card.frame.minY + 2 + marker.y)
    let target = CGPoint(x: pointer.x + 40, y: pointer.y)
    let committed = board.cards

    drag(pointer, target, release: false)

    XCTAssertEqual(board.cards, committed, "a marker drag previews only")
    let live = try XCTUnwrap(board.renderedCard(id)?.graph?.series.first?.points?[1])
    XCTAssertGreaterThan(live.x, 5)
    XCTAssertEqual(live.y, 5, accuracy: 0.05)
    XCTAssertEqual(live.label, "peak", "the point keeps its label")

    gesture.release(at: target, modifiers: [])
    XCTAssertTrue(board.gesturePreview.isEmpty)
    XCTAssertEqual(board.cards.first { $0.id == id }?.graph?.series.first?.points?[1], live)
    XCTAssertEqual(frame(id), card.frame, "the graph itself never moved")
    board.undo()
    XCTAssertEqual(board.cards.first { $0.id == id }?.graph, spec, "one undo step")
  }

  // MARK: Resize

  func testCornerHandleResizesAsOneUndoStep() throws {
    let id = board.addElement(.rectangle, at: CGPoint(x: 600, y: 400))
    let before = frame(id)
    let chrome = SelectionChrome.resolve(selected: board.renderedCards.filter { $0.id == id },
                                         editingID: nil, viewport: viewport, interactive: true)
    let handle = SelectionHandle.bottomRight.point(on: try XCTUnwrap(chrome.box))

    drag(handle, CGPoint(x: handle.x + 60, y: handle.y + 40))

    XCTAssertEqual(frame(id).origin, before.origin, "the opposite corner stays put")
    XCTAssertEqual(frame(id).width, before.width + 60, accuracy: 0.001)
    XCTAssertEqual(frame(id).height, before.height + 40, accuracy: 0.001)
    board.undo()
    XCTAssertEqual(frame(id), before)
  }

  func testMultiSelectionResizeScalesEveryMemberUniformly() throws {
    let a = board.addElement(.rectangle, at: CGPoint(x: 400, y: 400))
    let b = board.addElement(.rectangle, at: CGPoint(x: 800, y: 400))
    board.select(a)
    board.select(b, toggling: true)
    let beforeA = frame(a), beforeB = frame(b)
    let chrome = SelectionChrome.resolve(selected: board.renderedCards.filter { $0.id == a || $0.id == b },
                                         editingID: nil,
                                         viewport: viewport, interactive: true)
    let box = try XCTUnwrap(chrome.box)
    let handle = SelectionHandle.bottomRight.point(on: box)
    let union = beforeA.union(beforeB)

    drag(handle, CGPoint(x: handle.x + union.width, y: handle.y))   // double the width

    XCTAssertEqual(frame(a).width, beforeA.width * 2, accuracy: 0.01)
    XCTAssertEqual(frame(a).height, beforeA.height * 2, accuracy: 0.01, "uniform: height follows")
    XCTAssertEqual(frame(b).minX - union.minX, (beforeB.minX - union.minX) * 2, accuracy: 0.01)
    board.undo()
    XCTAssertEqual(frame(a), beforeA)
    XCTAssertEqual(frame(b), beforeB)
  }

  func testDraggingAConnectorEndpointRebindsAsOneUndoStep() throws {
    let source = board.addElement(.rectangle, at: CGPoint(x: 300, y: 300))
    let other = board.addElement(.rectangle, at: CGPoint(x: 300, y: 900))
    let target = board.addElement(.ellipse, at: CGPoint(x: 900, y: 300))
    let arrowID = try XCTUnwrap(board.connectCards(from: source, to: target))
    board.select(arrowID)
    let before = board.cards
    let chrome = SelectionChrome.resolve(selected: board.renderedCards.filter { $0.id == arrowID },
                                         editingID: nil, viewport: viewport, interactive: true)
    let end = try XCTUnwrap(chrome.endpoints.first { $0.endpoint == .end })

    drag(end.point, center(other))

    XCTAssertEqual(board.cards.first { $0.id == arrowID }?.endBindingID, other)
    board.undo()
    XCTAssertEqual(board.cards, before)
  }

  // MARK: Layer order

  func testLayerCommandsReorderWithoutTouchingTheRest() {
    let bottom = board.addElement(.rectangle, at: CGPoint(x: 400, y: 400))
    let middle = board.addElement(.rectangle, at: CGPoint(x: 450, y: 420))
    let top = board.addElement(.rectangle, at: CGPoint(x: 500, y: 440))
    let mine: Set<UUID> = [bottom, middle, top]
    func order() -> [UUID] { board.cards.sorted { $0.z < $1.z }.map(\.id).filter(mine.contains) }

    board.select(bottom)
    board.reorderSelection(.forward)
    XCTAssertEqual(order(), [middle, bottom, top])
    board.reorderSelection(.toFront)
    XCTAssertEqual(order(), [middle, top, bottom])
    board.reorderSelection(.toBack)
    XCTAssertEqual(order(), [bottom, middle, top])
    board.select(top)
    board.reorderSelection(.backward)
    XCTAssertEqual(order(), [bottom, top, middle])
    board.undo()
    XCTAssertEqual(order(), [bottom, middle, top])
  }

  // MARK: Transactions

  func testTransactionThatChangesNothingRecordsNothing() {
    let id = board.addElement(.rectangle, at: CGPoint(x: 600, y: 400))
    board.beginTransaction()
    board.commitTransaction()
    board.undo()
    XCTAssertFalse(board.cards.contains { $0.id == id }, "undo skipped straight past the empty gesture")
  }
}
