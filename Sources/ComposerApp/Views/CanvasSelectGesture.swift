import AppKit
import SwiftUI

/// The pointer's board position while it hovers the canvas itself (nil over chrome, fields, or
/// outside the window). Published by the board's input view so pointer-transparent overlays (the
/// graph readout) can follow the pointer without becoming hit-testable and stealing presses.
@MainActor
final class CanvasPointerHover: ObservableObject {
  static let shared = CanvasPointerHover()
  @Published var boardPoint: CGPoint?
}

/// What the pointer is over, for cursor feedback.
enum CanvasHoverCursor: Equatable {
  case arrow
  case resize(SelectionHandle)
  case endpoint
  case port
}

/// The Select tool's pointer state machine — the ONE owner of presses on the board while Select is
/// active: selecting, moving, resizing, dragging connector endpoints, quick-connect, marquee,
/// double-click to edit, checklist toggles and graph point gestures.
///
/// Cards are render-only. Before this, every card carried its own AppKit catcher plus SwiftUI drag
/// gestures for each handle, so five owners raced for the same press: handles fought the card's
/// move, a drag's preview lived in four places, and arrows only caught up on mouse-up. Now a press
/// is resolved exactly once, against real geometry (`SelectionChrome`, `CanvasHitTester`), in
/// board space through one `CanvasViewport` — so scrolling or zooming mid-drag keeps the element
/// under the pointer — and every gesture commits as one undo step.
@MainActor
final class CanvasSelectGesture {
  struct Callbacks {
    /// The marquee rectangle (viewport space), or nil when it ends.
    var marqueeChanged: (CGRect?) -> Void = { _ in }
    /// A double-click on empty board (viewport point): start writing there.
    var doubleClickedEmpty: (CGPoint) -> Void = { _ in }
    /// A quick-connect drag's rubber band (viewport space) and the card it would bind to.
    var connectorDraftChanged: (DragSegment?, CanvasElementKind, UUID?) -> Void = { _, _, _ in }
    /// ⌥-click on a graph's plot: open the point composer seeded at that data point.
    var openPointComposer: (UUID, CardState.GraphPoint) -> Void = { _, _ in }
    /// Any press on the board (transient chrome such as the promotion chip retracts).
    var pressed: () -> Void = {}
  }

  /// Screen-space distance a press must travel before it becomes a drag. A click with a little
  /// jitter must stay a click: on a port it creates a linked shape, on a text corner it must not
  /// rescale the font.
  static let dragThreshold: CGFloat = 4
  static let handleDragThreshold: CGFloat = 3
  static let endpointDragThreshold: CGFloat = 2
  static let snapTolerance: CGFloat = 8

  let board: BoardViewModel
  var viewport: () -> CanvasViewport
  var callbacks = Callbacks()

  init(board: BoardViewModel, viewport: @escaping () -> CanvasViewport) {
    self.board = board
    self.viewport = viewport
  }

  // MARK: State

  private enum Target: Equatable {
    case chrome(SelectionChromeHit)
    /// An unlocked element; `wasSelected` decides what a plain click does on release.
    case element(UUID, wasSelected: Bool)
    /// Empty space inside the selection box: a drag moves the selection, a click deselects.
    case selectionBox
    /// A locked element: a click selects it (so it can be unlocked); a drag sweeps a marquee.
    case locked(UUID)
    /// A data point on a selected graph.
    case graphMarker(GraphMarker)
    case empty
  }

  private struct Pending {
    var start: CGPoint
    var startBoard: CGPoint
    var modifiers: EventModifiers
    var target: Target
  }

  private struct Move {
    var startBoard: CGPoint
  }

  private struct Resize {
    var handle: SelectionHandle
    var startBoard: CGPoint
    var base: CGRect
    var frames: [UUID: CGRect]
    var textScales: [UUID: CGFloat]
    var isMultiple: Bool
    /// The lone element's kind (nil for a multi-selection).
    var singleKind: CanvasElementKind?
    var minSize: CGSize
    var maxSize: CGSize?
  }

  private struct Endpoint {
    var connectorID: UUID
    var endpoint: ConnectorEndpoint
    var startBoard: CGPoint
    var origin: CGPoint
  }

  private struct QuickConnect {
    var sourceID: UUID
    var direction: ConnectorDirection
    var session: QuickConnectDragSession
    var startBoard: CGPoint
    var origin: CGPoint
  }

  private struct GraphMarker: Equatable {
    var graphID: UUID
    var seriesID: UUID
    var index: Int
    /// The point's data value and the pointer (viewport) at press: the drag applies the pointer's
    /// travel to the point, so grabbing a marker off-centre never makes it jump to the pointer.
    var origin: CardState.GraphPoint
    var startPointer: CGPoint
    /// The latest dragged value, committed once on release.
    var current: CardState.GraphPoint
  }

  private enum Phase {
    case idle
    case pending(Pending)
    case moving(Move)
    case resizing(Resize)
    case endpoint(Endpoint)
    case quickConnect(QuickConnect)
    case marquee(start: CGPoint, modifiers: EventModifiers)
    case graphMarker(GraphMarker)
    /// The press was fully handled (double-click, checkbox, ⌥-click, Esc): ignore it until release.
    case swallowed
  }

  private var phase: Phase = .idle
  private var lastPoint: CGPoint?
  private var lastModifiers: EventModifiers = []
  /// The board generation the press began on (see `BoardViewModel.boardGeneration`).
  private var generation = 0

  /// A gesture is past its threshold (or swallowed) — the board must not treat this press as idle.
  var isActive: Bool {
    switch phase {
    case .idle: false
    default: true
    }
  }

  /// A drag is changing geometry right now.
  var isManipulating: Bool {
    switch phase {
    case .moving, .resizing, .endpoint, .quickConnect, .graphMarker: true
    default: false
    }
  }

  // MARK: Input

  func press(at point: CGPoint, modifiers: EventModifiers, clickCount: Int) {
    cancel()
    phase = .idle
    generation = board.boardGeneration
    callbacks.pressed()
    lastPoint = point
    lastModifiers = modifiers
    let viewport = viewport()
    let boardPoint = viewport.boardPoint(point)
    let rendered = board.renderedCards
    let slop = ElementGeometry.Slop.pointer.board(at: viewport.scale)
    let hit = CanvasHitTester.topmost(at: boardPoint, in: rendered, slop: slop)

    func pending(_ target: Target) {
      phase = .pending(Pending(start: point, startBoard: boardPoint, modifiers: modifiers, target: target))
    }

    // Chrome and content act on every click of a sequence: two quick clicks on a port make two
    // linked shapes, two on a checkbox toggle it twice. Only then is a double-click an edit.
    let chrome = currentChrome(viewport: viewport, rendered: rendered)
    if let chromeHit = chrome.hit(point) {
      pending(.chrome(chromeHit))
      return
    }

    if let hit, !hit.locked,
       let target = handleContentPress(on: hit, at: boardPoint, pointer: point, modifiers: modifiers, viewport: viewport) {
      if let target { pending(target) } else { phase = .swallowed }
      return
    }

    if clickCount >= 2 {
      phase = .swallowed
      if let hit {
        if !hit.locked, hit.elementKind.supportsEditing { board.beginEditing(hit.id) }
      } else {
        callbacks.doubleClickedEmpty(point)
      }
      return
    }

    let toggling = modifiers.contains(.shift) || modifiers.contains(.command)
    if let hit {
      if hit.locked {
        pending(.locked(hit.id))
        return
      }
      let wasSelected = board.selectedCardIDs.contains(hit.id)
      if toggling {
        board.select(hit.id, toggling: true)
        // A shift-drag that just added the element still moves the selection; one that just
        // removed it has nothing to carry.
        pending(board.selectedCardIDs.contains(hit.id) ? .element(hit.id, wasSelected: true) : .empty)
        return
      }
      if !wasSelected { board.select(hit.id) }
      pending(.element(hit.id, wasSelected: wasSelected))
      return
    }

    if !toggling, let box = chrome.box, box.contains(point),
       board.selectedCardIDs.contains(where: { id in rendered.contains { $0.id == id && !$0.locked } }) {
      pending(.selectionBox)
      return
    }
    pending(.empty)
  }

  func drag(to point: CGPoint, modifiers: EventModifiers) {
    guard isCurrent() else { return }
    lastPoint = point
    lastModifiers = modifiers
    if case .pending(let pending) = phase {
      guard hypot(point.x - pending.start.x, point.y - pending.start.y) >= Self.threshold(for: pending.target)
      else { return }
      begin(pending)
    }
    update(to: point, modifiers: modifiers)
  }

  private static func threshold(for target: Target) -> CGFloat {
    switch target {
    case .chrome(.handle): handleDragThreshold
    case .chrome(.endpoint): endpointDragThreshold
    default: dragThreshold
    }
  }

  /// False once the board was replaced under this press (board switch, reload, undo): the press is
  /// abandoned so it can never move whatever the new board has at the old pointer position.
  private func isCurrent() -> Bool {
    guard board.boardGeneration != generation else { return true }
    switch phase {
    case .idle, .swallowed: break
    default:
      callbacks.marqueeChanged(nil)
      callbacks.connectorDraftChanged(nil, .arrow, nil)
      board.clearGesturePreview()
      board.clearSnapGuides()
      phase = .swallowed
    }
    return false
  }

  func release(at point: CGPoint, modifiers: EventModifiers) {
    defer {
      phase = .idle
      lastPoint = nil
    }
    guard isCurrent() else { return }
    let viewport = viewport()
    switch phase {
    case .idle, .swallowed:
      return

    case .pending(let pending):
      click(pending)

    case .moving:
      update(to: point, modifiers: modifiers)
      board.finishMovePreview(commit: true)

    case .resizing(let resize):
      update(to: point, modifiers: modifiers)
      commit(resize, at: point, modifiers: modifiers)

    case .endpoint(let endpoint):
      let destination = endpointDestination(endpoint, at: point, viewport: viewport)
      board.clearGesturePreview()
      board.setConnectorEndpoint(endpoint.endpoint, of: endpoint.connectorID, to: destination)

    case .quickConnect(let quick):
      callbacks.connectorDraftChanged(nil, quick.session.connectorKind, nil)
      let destination = quickConnectDestination(quick, at: point, viewport: viewport)
      if let target = board.bindCandidate(at: destination, excluding: [quick.sourceID]) {
        board.quickConnect(from: quick.sourceID, direction: quick.direction,
                           kind: quick.session.connectorKind, to: target)
      }

    case .marquee(let start, let pressModifiers):
      callbacks.marqueeChanged(nil)
      let rect = Self.rect(from: start, to: point)
      board.select(in: viewport.boardRect(rect),
                   extending: pressModifiers.contains(.shift),
                   toggling: pressModifiers.contains(.command))

    case .graphMarker(let marker):
      board.clearGesturePreview()
      if marker.current != marker.origin {
        board.setGraphPoint(marker.graphID, seriesID: marker.seriesID, index: marker.index, to: marker.current)
      }
    }
  }

  /// Shift/⌥ changed with the mouse still: re-apply the constraint immediately.
  func modifiersChanged(_ modifiers: EventModifiers) {
    lastModifiers = modifiers
    guard isCurrent(), isManipulating, let lastPoint else { return }
    update(to: lastPoint, modifiers: modifiers)
  }

  /// The board panned or zoomed under a live drag: re-resolve the pointer in board space so the
  /// grabbed element stays under it.
  func viewportChanged() {
    guard isCurrent(), isManipulating, let lastPoint else { return }
    update(to: lastPoint, modifiers: lastModifiers)
  }

  /// Esc mid-gesture: abandon it with nothing committed.
  func cancel() {
    switch phase {
    case .moving:
      board.finishMovePreview(commit: false)
    case .resizing, .endpoint, .graphMarker:
      board.clearGesturePreview()
    case .quickConnect(let quick):
      callbacks.connectorDraftChanged(nil, quick.session.connectorKind, nil)
    case .marquee:
      callbacks.marqueeChanged(nil)
    case .idle, .pending, .swallowed:
      break
    }
    if case .idle = phase { return }
    board.clearSnapGuides()
    phase = .swallowed
  }

  /// What the pointer is over while no button is down.
  func hover(at point: CGPoint) -> CanvasHoverCursor {
    let viewport = viewport()
    let rendered = board.renderedCards
    switch currentChrome(viewport: viewport, rendered: rendered).hit(point) {
    case .handle(let handle): return .resize(handle)
    case .endpoint: return .endpoint
    case .quickConnect: return .port
    case nil: return .arrow
    }
  }

  // MARK: Phases

  private func begin(_ pending: Pending) {
    let viewport = viewport()
    switch pending.target {
    case .chrome(.handle(let handle)):
      guard let resize = makeResize(handle: handle, startBoard: pending.startBoard, viewport: viewport) else {
        phase = .swallowed
        return
      }
      phase = .resizing(resize)

    case .chrome(.endpoint(let id, let endpoint)):
      guard let card = board.cards.first(where: { $0.id == id }),
            let ends = ConnectorGeometry.endpoints(of: card) else {
        phase = .swallowed
        return
      }
      phase = .endpoint(Endpoint(connectorID: id, endpoint: endpoint,
                                 startBoard: pending.startBoard, origin: ends[endpoint]))

    case .chrome(.quickConnect(let id, let direction)):
      guard let card = board.cards.first(where: { $0.id == id }) else {
        phase = .swallowed
        return
      }
      let session = QuickConnectDragSession(optionPressed: pending.modifiers.contains(.option))
      let origin = session.destination(from: card.frame, direction: direction,
                                       translation: .zero, zoom: viewport.scale)
      phase = .quickConnect(QuickConnect(sourceID: id, direction: direction, session: session,
                                         startBoard: pending.startBoard, origin: origin))

    case .element, .selectionBox:
      if pending.modifiers.contains(.option) { board.beginDragDuplicate() }
      phase = .moving(Move(startBoard: pending.startBoard))

    case .graphMarker(let marker):
      phase = .graphMarker(marker)

    case .locked, .empty:
      phase = .marquee(start: pending.start, modifiers: pending.modifiers)
    }
  }

  private func update(to point: CGPoint, modifiers: EventModifiers) {
    let viewport = viewport()
    switch phase {
    case .moving(let move):
      let current = viewport.boardPoint(point)
      var delta = CGSize(width: current.x - move.startBoard.x, height: current.y - move.startBoard.y)
      // Shift locks the drag to the dominant axis.
      if modifiers.contains(.shift) {
        if abs(delta.width) >= abs(delta.height) { delta.height = 0 } else { delta.width = 0 }
      }
      board.updateMovePreview(by: delta, tolerance: viewport.boardDistance(Self.snapTolerance))

    case .resizing(let resize):
      let preview = resizedFrames(resize, at: point, modifiers: modifiers, viewport: viewport)
      board.previewFrames(preview.frames, textScaleFactors: preview.textFactors)

    case .endpoint(let endpoint):
      let destination = endpointDestination(endpoint, at: point, viewport: viewport)
      guard let card = board.cards.first(where: { $0.id == endpoint.connectorID }),
            let moved = ConnectorGeometry.moving(endpoint.endpoint, of: card, to: destination,
                                                 among: board.cards) else { return }
      board.previewCards([moved])

    case .quickConnect(let quick):
      guard let card = board.cards.first(where: { $0.id == quick.sourceID }) else { return }
      let destination = quickConnectDestination(quick, at: point, viewport: viewport)
      let port = ConnectorGeometry.port(on: card.frame, direction: quick.direction)
      let target = board.bindCandidate(at: destination, excluding: [quick.sourceID])
      callbacks.connectorDraftChanged(
        DragSegment(start: viewport.viewportPoint(port), end: point),
        quick.session.connectorKind, target)

    case .marquee(let start, _):
      callbacks.marqueeChanged(Self.rect(from: start, to: point))

    case .graphMarker(var marker):
      guard let preview = graphMarkerPreview(&marker, at: point, viewport: viewport) else { return }
      phase = .graphMarker(marker)
      board.previewCards([preview])

    case .idle, .pending, .swallowed:
      break
    }
  }

  /// A press that never became a drag.
  private func click(_ pending: Pending) {
    let toggling = pending.modifiers.contains(.shift) || pending.modifiers.contains(.command)
    switch pending.target {
    case .element(let id, let wasSelected):
      // A plain click on a member of a multi-selection narrows to it — decided on release so a
      // drag that starts on it still carries the whole selection.
      if wasSelected, !toggling, board.selectedCardIDs.count > 1 { board.select(id) }
    case .locked(let id):
      board.select(id, toggling: toggling)
    case .selectionBox:
      board.deselectAll()
    case .empty:
      if !toggling { board.deselectAll() }
    case .chrome(.quickConnect(let id, let direction)):
      let kind = QuickConnectDragSession(optionPressed: pending.modifiers.contains(.option)).connectorKind
      board.quickConnect(from: id, direction: direction, kind: kind)
    case .chrome, .graphMarker:
      break
    }
  }

  // MARK: Chrome

  private func currentChrome(viewport: CanvasViewport, rendered: [CardState]) -> SelectionChrome {
    let selected = rendered.filter { board.selectedCardIDs.contains($0.id) }
    return SelectionChrome.resolve(selected: selected, editingID: board.editingCardID,
                                   viewport: viewport, interactive: true)
  }

  // MARK: Resize

  private func makeResize(handle: SelectionHandle, startBoard: CGPoint, viewport: CanvasViewport) -> Resize? {
    let selected = board.cards.filter { board.selectedCardIDs.contains($0.id) && !$0.locked }
    guard let base = CanvasHitTester.unionBounds(of: selected), base.width > 0 || base.height > 0 else {
      return nil
    }
    let isMultiple = selected.count > 1
    let single = isMultiple ? nil : selected.first

    // The box may shrink until the first element hits its own minimum (or a text element its
    // smallest font), and grow until a text element hits its largest font.
    var minSize = CGSize(width: 1, height: 1)
    var maxSize: CGSize?
    if let single {
      if single.elementKind == .text {
        let scale = single.textScale
        minSize = CGSize(width: base.width * 0.4 / scale, height: base.height * 0.4 / scale)
        maxSize = CGSize(width: base.width * 6 / scale, height: base.height * 6 / scale)
      } else if !ConnectorGeometry.isConnector(single) {
        minSize = single.minimumSize
      }
    } else {
      var minScale: CGFloat = 0
      var maxScale = CGFloat.greatestFiniteMagnitude
      for card in selected where !ConnectorGeometry.isConnector(card) {
        if card.elementKind == .text {
          minScale = max(minScale, 0.4 / card.textScale)
          maxScale = min(maxScale, 6 / card.textScale)
        } else if card.w > 0, card.h > 0 {
          minScale = max(minScale, card.minimumSize.width / card.w, card.minimumSize.height / card.h)
        }
      }
      minScale = min(minScale, 1)
      minSize = CGSize(width: base.width * minScale, height: base.height * minScale)
      if maxScale < .greatestFiniteMagnitude {
        maxSize = CGSize(width: base.width * max(maxScale, 1), height: base.height * max(maxScale, 1))
      }
    }

    return Resize(
      handle: handle,
      startBoard: startBoard,
      base: base,
      frames: Dictionary(uniqueKeysWithValues: selected.map { ($0.id, $0.frame) }),
      textScales: Dictionary(uniqueKeysWithValues: selected.filter { $0.elementKind == .text }
        .map { ($0.id, $0.textScale) }),
      isMultiple: isMultiple,
      singleKind: single?.elementKind,
      minSize: minSize,
      maxSize: maxSize)
  }

  private func resizedFrames(_ resize: Resize,
                             at point: CGPoint,
                             modifiers: EventModifiers,
                             viewport: CanvasViewport) -> (frames: [UUID: CGRect], textFactors: [UUID: CGFloat]) {
    let current = viewport.boardPoint(point)
    let delta = CGSize(width: current.x - resize.startBoard.x, height: current.y - resize.startBoard.y)

    // A lone text element's side handles change its wrap width; its font is untouched.
    if resize.singleKind == .text, !resize.handle.isCorner, let entry = resize.frames.first {
      return ([entry.key: textWidthFrame(entry.key, base: entry.value, handle: resize.handle, delta: delta)], [:])
    }

    let keepAspect: Bool
    if resize.isMultiple || resize.singleKind == .text {
      keepAspect = true
    } else if resize.singleKind == .image {
      keepAspect = !modifiers.contains(.shift)
    } else {
      keepAspect = modifiers.contains(.shift)
    }
    let bounds = SelectionResize.bounds(
      resize.base, handle: resize.handle, delta: delta,
      keepAspect: keepAspect, fromCenter: modifiers.contains(.option),
      minSize: resize.minSize, maxSize: resize.maxSize)
    var frames: [UUID: CGRect] = [:]
    for (id, frame) in resize.frames {
      frames[id] = SelectionResize.mapped(frame, from: resize.base, to: bounds)
    }
    var factors: [UUID: CGFloat] = [:]
    if !resize.textScales.isEmpty, resize.base.width > 0 {
      let factor = bounds.width / resize.base.width
      for id in resize.textScales.keys { factors[id] = factor }
    }
    return (frames, factors)
  }

  private func commit(_ resize: Resize, at point: CGPoint, modifiers: EventModifiers) {
    let preview = resizedFrames(resize, at: point, modifiers: modifiers, viewport: viewport())
    var frames = preview.frames
    var fontScales: [UUID: Double] = [:]
    for (id, factor) in preview.textFactors {
      guard let card = board.cards.first(where: { $0.id == id }),
            let oldScale = resize.textScales[id],
            let mapped = frames[id] else { continue }
      let newScale = min(max(oldScale * factor, 0.4), 6)
      fontScales[id] = Double(newScale)
      // Hug the text at its new size, pinned to the corner opposite the dragged handle.
      let fitted = BoardViewModel.fittedTextSize(board.plainText(for: card), fontScale: newScale)
      let x = resize.handle.horizontal < 0 ? mapped.maxX - fitted.width : mapped.minX
      let y = resize.handle.vertical < 0 ? mapped.maxY - fitted.height : mapped.minY
      frames[id] = CGRect(x: x, y: y, width: fitted.width, height: fitted.height)
    }
    board.clearGesturePreview()
    board.commitResize(frames: frames, fontScales: fontScales)
  }

  /// Reflow a text element at a new width with the opposite side anchored; height follows the text.
  private func textWidthFrame(_ id: UUID, base: CGRect, handle: SelectionHandle, delta: CGSize) -> CGRect {
    let proposed = handle.horizontal > 0 ? base.width + delta.width : base.width - delta.width
    let width = max(proposed, CardState.textMinSize.width)
    let x = handle.horizontal < 0 ? base.maxX - width : base.minX
    guard let card = board.cards.first(where: { $0.id == id }) else { return base }
    let text = board.plainText(for: card)
    let height = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? max(base.height, CardState.textMinSize.height)
      : BoardViewModel.fittedTextHeight(text, width: width, fontScale: card.textScale)
    return CGRect(x: x, y: base.minY, width: width, height: height)
  }

  // MARK: Connectors

  private func endpointDestination(_ endpoint: Endpoint, at point: CGPoint, viewport: CanvasViewport) -> CGPoint {
    let current = viewport.boardPoint(point)
    return CGPoint(x: endpoint.origin.x + current.x - endpoint.startBoard.x,
                   y: endpoint.origin.y + current.y - endpoint.startBoard.y)
  }

  private func quickConnectDestination(_ quick: QuickConnect, at point: CGPoint, viewport: CanvasViewport) -> CGPoint {
    let current = viewport.boardPoint(point)
    return CGPoint(x: quick.origin.x + current.x - quick.startBoard.x,
                   y: quick.origin.y + current.y - quick.startBoard.y)
  }

  // MARK: Content presses (checklists, graphs)

  /// Presses that act on an element's content instead of selecting it. Returns nil when the press
  /// is an ordinary select/move, `.some(nil)` when it was fully handled on press, or a target to
  /// arm (a graph marker drag).
  private func handleContentPress(on card: CardState,
                                  at boardPoint: CGPoint,
                                  pointer: CGPoint,
                                  modifiers: EventModifiers,
                                  viewport: CanvasViewport) -> Target?? {
    let scale = viewport.safeScale
    let local = CGPoint(x: (boardPoint.x - card.x) * scale, y: (boardPoint.y - card.y) * scale)

    if modifiers.isEmpty, card.elementKind == .checklist || card.elementKind == .text,
       let measured = board.checkboxFrames[card.id] {
      // Checkbox targets have a screen-space minimum, so compare in screen units.
      let frames = measured.mapValues { rect in
        CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale)
      }
      if let index = ChecklistInteraction.itemIndex(at: local, renderedFrames: frames) {
        if card.elementKind == .checklist {
          board.toggleChecklistItem(card.id, index: index)
          return .some(nil)
        }
        let lines = board.plainText(for: card).components(separatedBy: "\n")
        if lines.indices.contains(index), lines[index].hasPrefix("- [") {
          board.toggleTextChecklistLine(card.id, lineIndex: index)
          return .some(nil)
        }
      }
    }

    if card.elementKind == .graph, let spec = card.graph,
       let plot = graphGeometry(for: card, spec: spec, local: local, scale: scale) {
      let (geometry, plotPoint) = plot
      if modifiers.contains(.option) {
        if let marker = markerHit(spec: spec, geometry: geometry, at: plotPoint) {
          board.removeGraphPoint(card.id, seriesID: marker.seriesID, index: marker.index)
        } else if geometry.contains(plotPoint) {
          callbacks.openPointComposer(card.id, geometry.rounded(geometry.clampedData(plotPoint)))
        } else {
          return nil
        }
        return .some(nil)
      }
      if board.selectedCardIDs.contains(card.id),
         let marker = markerHit(spec: spec, geometry: geometry, at: plotPoint),
         let value = spec.series.first(where: { $0.id == marker.seriesID })?.points?[marker.index] {
        return .graphMarker(GraphMarker(graphID: card.id, seriesID: marker.seriesID, index: marker.index,
                                        origin: value, startPointer: pointer, current: value))
      }
    }
    return nil
  }

  /// The graph's plot geometry at the card's current screen size (GraphCardView renders inside a
  /// 2pt inset), plus the point in that plot space.
  private func graphGeometry(for card: CardState,
                             spec: CardState.GraphSpec,
                             local: CGPoint,
                             scale: CGFloat) -> (GraphGeometry, CGPoint)? {
    let size = CGSize(width: card.w * scale - 4, height: card.h * scale - 4)
    guard size.width > 1, size.height > 1 else { return nil }
    return (GraphGeometry(spec: spec, size: size), CGPoint(x: local.x - 2, y: local.y - 2))
  }

  private func markerHit(spec: CardState.GraphSpec,
                         geometry: GraphGeometry,
                         at point: CGPoint) -> (seriesID: UUID, index: Int)? {
    for series in spec.series {
      for (index, value) in (series.points ?? []).enumerated() {
        let marker = geometry.viewPoint(value)
        if hypot(marker.x - point.x, marker.y - point.y) <= 14 { return (series.id, index) }
      }
    }
    return nil
  }

  /// The graph as it looks with the dragged point moved by the pointer's travel since the press.
  /// Previewed only; the release commits it once.
  private func graphMarkerPreview(_ marker: inout GraphMarker, at point: CGPoint,
                                  viewport: CanvasViewport) -> CardState? {
    guard var card = board.cards.first(where: { $0.id == marker.graphID }), var spec = card.graph,
          let seriesIndex = spec.series.firstIndex(where: { $0.id == marker.seriesID }),
          var points = spec.series[seriesIndex].points, points.indices.contains(marker.index) else { return nil }
    let scale = viewport.safeScale
    let size = CGSize(width: card.w * scale - 4, height: card.h * scale - 4)
    guard size.width > 1, size.height > 1 else { return nil }
    let geometry = GraphGeometry(spec: spec, size: size)
    let start = geometry.viewPoint(marker.origin)
    let moved = CGPoint(x: start.x + point.x - marker.startPointer.x,
                        y: start.y + point.y - marker.startPointer.y)
    // Only the coordinates move; the point keeps its own label and tint.
    var value = geometry.rounded(geometry.clampedData(moved))
    value.label = marker.origin.label
    value.tint = marker.origin.tint
    marker.current = value
    points[marker.index] = value
    spec.series[seriesIndex].points = points
    card.graph = spec
    return card
  }

  static func rect(from start: CGPoint, to end: CGPoint) -> CGRect {
    CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
           width: abs(end.x - start.x), height: abs(end.y - start.y))
  }
}

extension GraphGeometry {
  /// Round to the axes' tick-step precision (a hundredth of the 1/2/5 × 10ⁿ step over ~5 ticks),
  /// so a placed point reads as a clean value rather than a long float.
  static func roundToStep(_ value: Double, span: Double) -> Double {
    guard span > 0 else { return value }
    let step = pow(10, floor(log10(span / 5)))
    let quantum = step / 100
    guard quantum > 0 else { return value }
    return (value / quantum).rounded() * quantum
  }

  func rounded(_ point: CardState.GraphPoint) -> CardState.GraphPoint {
    CardState.GraphPoint(x: Self.roundToStep(point.x, span: xMax - xMin),
                         y: Self.roundToStep(point.y, span: yMax - yMin),
                         label: point.label, tint: point.tint)
  }
}

extension EventModifiers {
  init(_ flags: NSEvent.ModifierFlags) {
    var modifiers: EventModifiers = []
    if flags.contains(.shift) { modifiers.insert(.shift) }
    if flags.contains(.command) { modifiers.insert(.command) }
    if flags.contains(.option) { modifiers.insert(.option) }
    if flags.contains(.control) { modifiers.insert(.control) }
    self = modifiers
  }
}
