import AppKit
import ImageIO
import ScreenCaptureKit

/// "Snap to board": a system-wide region screenshot with a markup step. Dims every screen, lets the
/// user drag a region, then **freezes** that region and shows an annotation toolbar — move / arrow /
/// box / highlighter / text, colors, undo — before ⌘⏎ sends the (optionally annotated) image to the
/// board. Esc cancels. Capture uses ScreenCaptureKit (the modern, permissioned path); the returned
/// `CGImage` is the composited result, handed to `ImageUnderstanding` so it lands as agent-ready text.
@MainActor
final class ScreenCaptureService {
  static let shared = ScreenCaptureService()
  private init() {}

  /// A finished selection: the chosen rectangle in global screen coordinates plus the screen it
  /// lives on (needed to map onto the right `SCDisplay` and convert to display-local points).
  private struct Selection {
    let rect: NSRect
    let screen: NSScreen
  }

  private var overlays: [NSWindow] = []
  private var keyMonitor: Any?
  private var finalContinuation: CheckedContinuation<CGImage?, Never>?
  private weak var activeView: CaptureOverlayView?
  private var inProgress = false
  private var crosshairPushed = false
  /// Started the moment the overlay appears so the slow `SCShareableContent` enumeration overlaps
  /// with the user dragging out their selection — by the time they release, it's usually ready.
  private var contentTask: Task<SCShareableContent?, Never>?

  /// Run the full flow: select → annotate → send. Returns the composited `CGImage`, or nil on cancel
  /// / if Screen Recording permission is unavailable (a clear message is surfaced in that case).
  func capture() async -> CGImage? {
    guard !inProgress else { return nil }
    inProgress = true
    defer { inProgress = false }
    return await withCheckedContinuation { continuation in
      finalContinuation = continuation
      presentOverlays()
    }
  }

  // MARK: Overlay lifecycle

  private func presentOverlays() {
    // Warm the two slow things up front, in parallel with the user's drag: ScreenCaptureKit's
    // content enumeration and the on-device understanding model. Both are ready by mouse-up.
    contentTask = Task { try? await SCShareableContent.current }
    ImageUnderstanding.prewarm()

    // Activate first so the overlay can take key immediately — without this the first click only
    // activates the app and a *second* click is needed to actually start selecting.
    NSApp.activate(ignoringOtherApps: true)

    for screen in NSScreen.screens {
      // Use the global-coordinate initializer (no `screen:` — that one treats the rect as relative
      // to the screen's origin, which double-offsets every non-main display) and pin the frame to the
      // screen's global frame so each overlay covers exactly its own monitor.
      let window = CaptureOverlayWindow(
        contentRect: screen.frame,
        styleMask: .borderless,
        backing: .buffered,
        defer: false)
      window.setFrame(screen.frame, display: false)
      window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
      window.backgroundColor = .clear
      window.isOpaque = false
      window.hasShadow = false
      window.ignoresMouseEvents = false
      // Excluded from the capture itself, so we can shoot without ordering it out first or waiting a
      // frame for the dim to clear — no artificial delay needed.
      window.sharingType = .none
      window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

      let view = CaptureOverlayView(frame: NSRect(origin: .zero, size: screen.frame.size))
      view.onSelect = { [weak self, weak window, weak view] rectInWindow in
        guard let self, let window, let view, let screen = window.screen else { return }
        self.regionSelected(Selection(rect: window.convertToScreen(rectInWindow), screen: screen), view: view)
      }
      view.onCommit = { [weak self] image in self?.finish(image) }
      view.onCancel = { [weak self] in self?.finish(nil) }
      window.contentView = view
      window.makeKeyAndOrderFront(nil)
      window.makeFirstResponder(view)
      overlays.append(window)
    }

    NSCursor.crosshair.push()
    crosshairPushed = true

    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      self?.handleKey(event) == true ? nil : event
    }
  }

  /// Returns true if the key was handled (and should be swallowed).
  private func handleKey(_ event: NSEvent) -> Bool {
    // While a text label is being typed, let every key reach the field (Esc cancels just the label).
    if activeView?.isEditingText == true { return false }
    if event.keyCode == 53 { finish(nil); return true }   // Escape — cancel everything
    let command = event.modifierFlags.contains(.command)
    if command, event.keyCode == 36 { activeView?.commit(); return true }   // ⌘⏎ — send
    if command, event.keyCode == 6 { activeView?.undo(); return true }      // ⌘Z — undo last mark
    return false
  }

  /// The user finished dragging a region: capture it, then hand the frozen bitmap to that view for
  /// markup. Once one view owns the selection, the others stop intercepting clicks.
  private func regionSelected(_ selection: Selection, view: CaptureOverlayView) {
    activeView = view
    for window in overlays where window.contentView !== view {
      window.ignoresMouseEvents = true
    }
    Task {
      guard let image = await captureImage(of: selection) else {
        finish(nil)
        return
      }
      if crosshairPushed { NSCursor.pop(); crosshairPushed = false }   // selecting → markup uses the arrow
      view.beginAnnotation(image: image)
    }
  }

  /// Tear down the overlay and resume the continuation exactly once with the final image (or nil).
  private func finish(_ image: CGImage?) {
    guard let continuation = finalContinuation else { return }
    finalContinuation = nil
    activeView?.endTextEditing(commit: false)
    if let keyMonitor {
      NSEvent.removeMonitor(keyMonitor)
      self.keyMonitor = nil
    }
    overlays.forEach { $0.orderOut(nil) }
    overlays.removeAll()
    activeView = nil
    if crosshairPushed { NSCursor.pop(); crosshairPushed = false }
    continuation.resume(returning: image)
  }

  // MARK: ScreenCaptureKit capture

  private func captureImage(of selection: Selection) async -> CGImage? {
    do {
      // Reuse the enumeration kicked off when the overlay appeared; only fetch fresh if it's missing.
      let content: SCShareableContent?
      if let contentTask {
        content = await contentTask.value
      } else {
        content = try? await SCShareableContent.current
      }
      guard let content,
            let displayID = selection.screen.displayID,
            let display = content.displays.first(where: { $0.displayID == displayID }) else {
        return nil
      }

      // Global (bottom-left) selection → display-local (top-left) points, clamped to the display.
      let frame = selection.screen.frame
      var local = CGRect(
        x: selection.rect.minX - frame.minX,
        y: frame.maxY - selection.rect.maxY,
        width: selection.rect.width,
        height: selection.rect.height)
      local = local.intersection(CGRect(x: 0, y: 0, width: frame.width, height: frame.height))
      guard local.width >= 1, local.height >= 1 else { return nil }

      let scale = selection.screen.backingScaleFactor
      let filter = SCContentFilter(display: display, excludingWindows: [])
      let config = SCStreamConfiguration()
      config.sourceRect = local
      config.width = Int(local.width * scale)
      config.height = Int(local.height * scale)
      config.showsCursor = false

      return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    } catch {
      UserFacingError.report(
        UserFacingError.message(for: error, while: "Capturing the screen") +
        " If this keeps failing, grant Screen Recording to BonsAI in System Settings ▸ Privacy & Security.")
      return nil
    }
  }
}

// MARK: - Overlay window

/// Borderless overlays can't become key by default, which would block the Esc/mouse path; this
/// override lets the overlay take key so its view receives events.
private final class CaptureOverlayWindow: NSWindow {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { true }
}

// MARK: - Annotation model

private enum AnnotationTool {
  case move, arrow, box, highlight, text
}

private struct Annotation {
  var tool: AnnotationTool
  var start: NSPoint
  var end: NSPoint
  var color: NSColor
  var text: String?

  /// `mapping` converts a stored (view-space) point into the target space; `lineWidth`/`fontScale`
  /// scale strokes and text for that space (1× on screen, ×backingScale when baked into the image).
  func draw(mapping: (NSPoint) -> NSPoint, lineWidth: CGFloat, fontScale: CGFloat) {
    let s = mapping(start)
    let e = mapping(end)
    switch tool {
    case .move:
      break   // not a drawable annotation
    case .arrow:
      Annotation.drawArrow(from: s, to: e, color: color, lineWidth: lineWidth)
    case .box:
      color.setStroke()
      let path = NSBezierPath(rect: Annotation.rect(s, e))
      path.lineWidth = lineWidth
      path.stroke()
    case .highlight:
      color.withAlphaComponent(0.30).setFill()
      NSBezierPath(rect: Annotation.rect(s, e)).fill()
    case .text:
      guard let text, !text.isEmpty else { return }
      (text as NSString).draw(at: s, withAttributes: Annotation.textAttributes(color: color, fontScale: fontScale))
    }
  }

  /// Hit test in view space (for the move tool). A little padding makes thin marks easy to grab.
  func contains(_ point: NSPoint) -> Bool {
    switch tool {
    case .move:
      return false
    case .arrow:
      return Annotation.distanceToSegment(point, start, end) < 9
    case .box, .highlight:
      return Annotation.rect(start, end).insetBy(dx: -7, dy: -7).contains(point)
    case .text:
      let size = (text as NSString? ?? "").size(withAttributes: Annotation.textAttributes(color: color, fontScale: 1))
      return NSRect(origin: start, size: size).insetBy(dx: -7, dy: -7).contains(point)
    }
  }

  mutating func translate(by delta: NSSize) {
    start = NSPoint(x: start.x + delta.width, y: start.y + delta.height)
    end = NSPoint(x: end.x + delta.width, y: end.y + delta.height)
  }

  static func rect(_ a: NSPoint, _ b: NSPoint) -> NSRect {
    NSRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
  }

  static func textAttributes(color: NSColor, fontScale: CGFloat) -> [NSAttributedString.Key: Any] {
    [.font: NSFont.systemFont(ofSize: 17 * fontScale, weight: .semibold), .foregroundColor: color]
  }

  private static func distanceToSegment(_ p: NSPoint, _ a: NSPoint, _ b: NSPoint) -> CGFloat {
    let dx = b.x - a.x, dy = b.y - a.y
    let lengthSq = dx * dx + dy * dy
    guard lengthSq > 0 else { return hypot(p.x - a.x, p.y - a.y) }
    var t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSq
    t = Swift.min(Swift.max(t, 0), 1)
    return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
  }

  private static func drawArrow(from start: NSPoint, to end: NSPoint, color: NSColor, lineWidth: CGFloat) {
    color.setStroke()
    color.setFill()
    let shaft = NSBezierPath()
    shaft.move(to: start)
    shaft.line(to: end)
    shaft.lineWidth = lineWidth
    shaft.lineCapStyle = .round
    shaft.stroke()

    let angle = atan2(end.y - start.y, end.x - start.x)
    let head = max(10, lineWidth * 3.2)
    let spread = CGFloat.pi / 7
    let p1 = NSPoint(x: end.x - head * cos(angle - spread), y: end.y - head * sin(angle - spread))
    let p2 = NSPoint(x: end.x - head * cos(angle + spread), y: end.y - head * sin(angle + spread))
    let headPath = NSBezierPath()
    headPath.move(to: end)
    headPath.line(to: p1)
    headPath.line(to: p2)
    headPath.close()
    headPath.fill()
  }
}

// MARK: - Overlay view (select → annotate)

private final class CaptureOverlayView: NSView, NSTextFieldDelegate {
  /// Reports the selected rectangle (window coordinates) when the user finishes the first drag.
  var onSelect: ((NSRect) -> Void)?
  /// Sends the composited image to the board.
  var onCommit: ((CGImage) -> Void)?
  /// Cancels the whole capture.
  var onCancel: (() -> Void)?

  private enum Phase { case selecting, annotating }
  private var phase: Phase = .selecting
  private var isCapturing = false

  // Selecting
  private var startPoint: NSPoint?
  private var selectionRect: NSRect? { didSet { needsDisplay = true } }

  // Annotating
  private var capturedImage: CGImage?
  private var frozenImage: NSImage?
  private var lockedRect: NSRect = .zero
  private var annotations: [Annotation] = []
  private var draft: Annotation?
  private var tool: AnnotationTool = .move
  private var color: NSColor = .systemRed
  private var toolbar: AnnotationToolbar?

  // Move tool
  private var movingIndex: Int?
  private var lastDragPoint: NSPoint = .zero

  // Text tool
  private var editor: NSTextField?
  private var editorOrigin: NSPoint = .zero
  private var editorColor: NSColor = .systemRed
  var isEditingText: Bool { editor != nil }

  override var isFlipped: Bool { false }
  override var acceptsFirstResponder: Bool { true }
  // Act on the very first click even though the app/window was just brought forward by the hotkey —
  // otherwise the first click is swallowed to activate and the user has to click twice.
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  override func resetCursorRects() {
    if phase == .selecting { addCursorRect(bounds, cursor: .crosshair) }
  }

  // MARK: Phase transition

  func beginAnnotation(image: CGImage) {
    capturedImage = image
    frozenImage = NSImage(cgImage: image, size: lockedRect.size)
    phase = .annotating
    let bar = AnnotationToolbar()
    bar.onTool = { [weak self] in self?.selectTool($0) }
    bar.onColor = { [weak self] in self?.color = $0 }
    bar.onUndo = { [weak self] in self?.undo() }
    bar.onSend = { [weak self] in self?.commit() }
    bar.onCancel = { [weak self] in self?.onCancel?() }
    addSubview(bar)
    bar.layoutSubtreeIfNeeded()
    bar.frame = toolbarFrame(for: bar.fittingSize)
    toolbar = bar
    window?.invalidateCursorRects(for: self)
    needsDisplay = true
  }

  private func selectTool(_ newTool: AnnotationTool) {
    endTextEditing(commit: true)
    tool = newTool
  }

  /// Double-click: edit the text label under the cursor, or drop a new one there — the board's
  /// "just start writing" gesture, available no matter which tool is active.
  private func handleDoubleClick(at point: NSPoint) {
    if let index = annotations.lastIndex(where: { $0.tool == .text && $0.contains(point) }) {
      let existing = annotations.remove(at: index)
      needsDisplay = true
      beginTextEditing(at: existing.start, initial: existing.text ?? "", color: existing.color)
    } else {
      beginTextEditing(at: point)
    }
    revertToMoveTool()
  }

  /// Return to the default move tool and reflect it in the toolbar — the board's pattern of "place
  /// or draw one thing, then you're back to selecting".
  private func revertToMoveTool() {
    tool = .move
    toolbar?.highlight(toolIndex: 0)
  }

  private func toolbarFrame(for size: NSSize) -> NSRect {
    let gap: CGFloat = 12
    let x = (lockedRect.midX - size.width / 2).clamped(to: 8...(bounds.width - size.width - 8))
    // Prefer just below the selection; flip above if there's no room near the bottom edge.
    var y = lockedRect.minY - gap - size.height
    if y < 8 { y = min(lockedRect.maxY + gap, bounds.height - size.height - 8) }
    return NSRect(x: x, y: y, width: size.width, height: size.height)
  }

  // MARK: Commit / undo

  func commit() {
    endTextEditing(commit: true)
    guard phase == .annotating, let composited = composite() else { return }
    onCommit?(composited)
  }

  func undo() {
    guard phase == .annotating, !annotations.isEmpty else { return }
    annotations.removeLast()
    needsDisplay = true
  }

  private func composite() -> CGImage? {
    guard let capturedImage else { return nil }
    let pixelSize = NSSize(width: capturedImage.width, height: capturedImage.height)
    guard pixelSize.width > 0, pixelSize.height > 0, lockedRect.width > 0, lockedRect.height > 0 else { return capturedImage }
    let image = NSImage(size: pixelSize)
    image.lockFocus()
    NSImage(cgImage: capturedImage, size: pixelSize).draw(in: NSRect(origin: .zero, size: pixelSize))
    let sx = pixelSize.width / lockedRect.width
    let sy = pixelSize.height / lockedRect.height
    let origin = lockedRect.origin
    let map: (NSPoint) -> NSPoint = { NSPoint(x: ($0.x - origin.x) * sx, y: ($0.y - origin.y) * sy) }
    for annotation in annotations {
      annotation.draw(mapping: map, lineWidth: 3 * max(sx, sy), fontScale: sy)
    }
    image.unlockFocus()
    var rect = NSRect(origin: .zero, size: pixelSize)
    return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
  }

  // MARK: Mouse

  override func mouseDown(with event: NSEvent) {
    let raw = event.locationInWindow
    let point = clampedToSelection(raw)
    switch phase {
    case .selecting:
      guard !isCapturing else { return }
      startPoint = raw
      selectionRect = .zero
    case .annotating:
      if event.clickCount == 2 {
        draft = nil
        handleDoubleClick(at: point)
        return
      }
      switch tool {
      case .move:
        movingIndex = annotations.lastIndex { $0.contains(point) }
        lastDragPoint = point
      case .text:
        beginTextEditing(at: point)
      case .arrow, .box, .highlight:
        draft = Annotation(tool: tool, start: point, end: point, color: color, text: nil)
      }
    }
  }

  override func mouseDragged(with event: NSEvent) {
    switch phase {
    case .selecting:
      guard let start = startPoint else { return }
      selectionRect = Annotation.rect(start, event.locationInWindow)
    case .annotating:
      let point = clampedToSelection(event.locationInWindow)
      if tool == .move {
        guard let index = movingIndex else { return }
        annotations[index].translate(by: NSSize(width: point.x - lastDragPoint.x, height: point.y - lastDragPoint.y))
        lastDragPoint = point
        needsDisplay = true
      } else {
        draft?.end = point
        needsDisplay = true
      }
    }
  }

  override func mouseUp(with event: NSEvent) {
    switch phase {
    case .selecting:
      let rect = selectionRect
      startPoint = nil
      selectionRect = nil
      guard let rect, rect.width > 6, rect.height > 6 else { onCancel?(); return }
      // Freeze the geometry and wait for the captured bitmap; ignore further drags meanwhile.
      lockedRect = rect
      isCapturing = true
      onSelect?(rect)
    case .annotating:
      if tool == .move {
        movingIndex = nil
      } else if var annotation = draft {
        annotation.end = clampedToSelection(event.locationInWindow)
        if abs(annotation.end.x - annotation.start.x) > 3 || abs(annotation.end.y - annotation.start.y) > 3 {
          annotations.append(annotation)
          revertToMoveTool()   // draw one shape, then back to the default tool — like the board
        }
        draft = nil
        needsDisplay = true
      }
    }
  }

  private func clampedToSelection(_ point: NSPoint) -> NSPoint {
    guard phase == .annotating else { return point }
    return NSPoint(
      x: point.x.clamped(to: lockedRect.minX...lockedRect.maxX),
      y: point.y.clamped(to: lockedRect.minY...lockedRect.maxY))
  }

  // MARK: Text editing

  private func beginTextEditing(at point: NSPoint, initial: String = "", color: NSColor? = nil) {
    endTextEditing(commit: true)
    let useColor = color ?? self.color
    let field = NSTextField(frame: NSRect(x: point.x, y: point.y - 6, width: 240, height: 26))
    field.isBordered = false
    field.drawsBackground = true
    field.backgroundColor = NSColor.black.withAlphaComponent(0.4)
    field.textColor = useColor
    field.font = .systemFont(ofSize: 17, weight: .semibold)
    field.focusRingType = .none
    field.placeholderString = "Type…"
    field.stringValue = initial
    field.delegate = self
    field.cell?.wraps = false
    field.cell?.isScrollable = true
    addSubview(field)
    window?.makeFirstResponder(field)
    field.currentEditor()?.selectedRange = NSRange(location: (initial as NSString).length, length: 0)
    editor = field
    editorOrigin = point
    editorColor = useColor
  }

  /// Finish the active text label. `commit` bakes a non-empty string into an annotation; otherwise it
  /// is discarded. The text's baseline sits a touch above the click so it reads where you placed it.
  func endTextEditing(commit: Bool) {
    guard let field = editor else { return }
    let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    editor = nil
    field.delegate = nil
    field.removeFromSuperview()
    if commit, !text.isEmpty {
      annotations.append(Annotation(tool: .text, start: editorOrigin, end: editorOrigin, color: editorColor, text: text))
      needsDisplay = true
    }
  }

  func controlTextDidEndEditing(_ obj: Notification) {
    // Fired on Return or focus loss. Esc reverts the field to empty first, so it's discarded.
    endTextEditing(commit: true)
  }

  // MARK: Draw

  override func draw(_ dirtyRect: NSRect) {
    NSColor.black.withAlphaComponent(0.28).setFill()
    bounds.fill()

    switch phase {
    case .selecting:
      guard let rect = selectionRect, rect.width > 0, rect.height > 0 else { return }
      NSColor.clear.setFill()
      rect.fill(using: .copy)
      strokeSelection(rect)
    case .annotating:
      frozenImage?.draw(in: lockedRect)
      for annotation in annotations { annotation.draw(mapping: { $0 }, lineWidth: 3, fontScale: 1) }
      draft?.draw(mapping: { $0 }, lineWidth: 3, fontScale: 1)
      strokeSelection(lockedRect)
    }
  }

  private func strokeSelection(_ rect: NSRect) {
    NSColor.white.withAlphaComponent(0.95).setStroke()
    let border = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5))
    border.lineWidth = 1
    border.stroke()
  }
}

// MARK: - Annotation toolbar

private final class AnnotationToolbar: NSView {
  var onTool: ((AnnotationTool) -> Void)?
  var onColor: ((NSColor) -> Void)?
  var onUndo: (() -> Void)?
  var onSend: (() -> Void)?
  var onCancel: (() -> Void)?

  private let toolOrder: [AnnotationTool] = [.move, .arrow, .box, .highlight, .text]
  private let colors: [NSColor] = [.systemRed, .systemYellow, .systemGreen, .systemBlue]
  private var toolButtons: [NSButton] = []
  private var colorButtons: [NSButton] = []

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.backgroundColor = NSColor.black.withAlphaComponent(0.82).cgColor
    layer?.cornerRadius = 11
    layer?.borderWidth = 1
    layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor

    let symbols: [AnnotationTool: String] = [
      .move: "arrow.up.and.down.and.arrow.left.and.right",
      .arrow: "arrow.up.right",
      .box: "rectangle",
      .highlight: "highlighter",
      .text: "textformat",
    ]
    let tools = NSStackView(views: toolOrder.enumerated().map { index, tool in
      toolButton(symbols[tool] ?? "questionmark", tag: index)
    })
    tools.spacing = 4
    let swatches = NSStackView(views: colors.enumerated().map { index, color in colorButton(color, index: index) })
    swatches.spacing = 5
    let actions = NSStackView(views: [
      symbolButton("arrow.uturn.backward", #selector(undoTapped), tint: .white),
      sendButton(),
      symbolButton("xmark", #selector(cancelTapped), tint: NSColor.white.withAlphaComponent(0.7)),
    ])

    let row = NSStackView(views: [tools, separator(), swatches, separator(), actions])
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = 8
    row.edgeInsets = NSEdgeInsets(top: 7, left: 11, bottom: 7, right: 11)
    row.translatesAutoresizingMaskIntoConstraints = false
    addSubview(row)
    NSLayoutConstraint.activate([
      row.leadingAnchor.constraint(equalTo: leadingAnchor),
      row.trailingAnchor.constraint(equalTo: trailingAnchor),
      row.topAnchor.constraint(equalTo: topAnchor),
      row.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])

    select(toolIndex: 0)   // move (the default, like the board's Select tool)
    select(colorIndex: 0)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  // Absorb clicks that land on the bar's background (between buttons) so they don't fall through to
  // the overlay view and start drawing an annotation underneath the toolbar.
  override func mouseDown(with event: NSEvent) {}
  override func mouseDragged(with event: NSEvent) {}
  override func mouseUp(with event: NSEvent) {}

  override var fittingSize: NSSize {
    let size = super.fittingSize
    return NSSize(width: max(size.width, 360), height: max(size.height, 38))
  }

  // MARK: Builders

  private func toolButton(_ symbol: String, tag: Int) -> NSButton {
    let button = symbolButton(symbol, #selector(toolTapped(_:)), tint: NSColor.white.withAlphaComponent(0.7))
    button.tag = tag
    toolButtons.append(button)
    return button
  }

  private func colorButton(_ color: NSColor, index: Int) -> NSButton {
    let button = NSButton()
    button.title = ""
    button.isBordered = false
    button.bezelStyle = .regularSquare
    button.image = swatchImage(color, selected: false)
    button.tag = index
    button.target = self
    button.action = #selector(colorTapped(_:))
    button.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      button.widthAnchor.constraint(equalToConstant: 20),
      button.heightAnchor.constraint(equalToConstant: 20),
    ])
    colorButtons.append(button)
    return button
  }

  private func sendButton() -> NSButton {
    let button = NSButton()
    button.title = "Send ⏎"
    button.bezelStyle = .rounded
    button.controlSize = .small
    button.target = self
    button.action = #selector(sendTapped)
    button.contentTintColor = .white
    return button
  }

  private func symbolButton(_ symbol: String, _ action: Selector, tint: NSColor) -> NSButton {
    let button = NSButton()
    button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    button.imageScaling = .scaleProportionallyDown
    button.isBordered = false
    button.bezelStyle = .regularSquare
    button.contentTintColor = tint
    button.target = self
    button.action = action
    button.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      button.widthAnchor.constraint(equalToConstant: 26),
      button.heightAnchor.constraint(equalToConstant: 24),
    ])
    return button
  }

  private func separator() -> NSView {
    let line = NSView()
    line.wantsLayer = true
    line.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.15).cgColor
    line.translatesAutoresizingMaskIntoConstraints = false
    line.widthAnchor.constraint(equalToConstant: 1).isActive = true
    line.heightAnchor.constraint(equalToConstant: 18).isActive = true
    return line
  }

  private func swatchImage(_ color: NSColor, selected: Bool) -> NSImage {
    let side: CGFloat = 18
    let image = NSImage(size: NSSize(width: side, height: side))
    image.lockFocus()
    color.setFill()
    NSBezierPath(ovalIn: NSRect(x: 2, y: 2, width: side - 4, height: side - 4)).fill()
    if selected {
      NSColor.white.setStroke()
      let ring = NSBezierPath(ovalIn: NSRect(x: 1, y: 1, width: side - 2, height: side - 2))
      ring.lineWidth = 1.5
      ring.stroke()
    }
    image.unlockFocus()
    return image
  }

  // MARK: Selection state

  /// Restyle the tool buttons without firing `onTool` — used when the view auto-reverts to the move
  /// tool after a draw, so it can reflect that without a feedback loop.
  func highlight(toolIndex index: Int) {
    for (i, button) in toolButtons.enumerated() {
      button.contentTintColor = i == index ? Theme.Palette.nsAccent : NSColor.white.withAlphaComponent(0.7)
    }
  }

  private func select(toolIndex: Int) {
    highlight(toolIndex: toolIndex)
    onTool?(toolOrder[toolIndex])
  }

  private func select(colorIndex: Int) {
    for (index, button) in colorButtons.enumerated() {
      button.image = swatchImage(colors[index], selected: index == colorIndex)
    }
    onColor?(colors[colorIndex])
  }

  // MARK: Actions

  @objc private func toolTapped(_ sender: NSButton) { select(toolIndex: sender.tag) }
  @objc private func colorTapped(_ sender: NSButton) { select(colorIndex: sender.tag) }
  @objc private func undoTapped() { onUndo?() }
  @objc private func sendTapped() { onSend?() }
  @objc private func cancelTapped() { onCancel?() }
}

// MARK: - Helpers

private extension NSScreen {
  /// The CoreGraphics display id, needed to pair an `NSScreen` with its `SCDisplay`.
  var displayID: CGDirectDisplayID? {
    (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
  }
}

private extension CGFloat {
  func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
    Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
  }
}

/// Hands the just-captured pixels from the capture flow to the board without a disk round-trip: the
/// card still references a saved attachment, but OCR reads this in-memory `CGImage` instead of
/// re-decoding the file. Keyed by the stored filename so the board takes exactly the shot it's adding.
@MainActor
final class CapturedShotStore {
  static let shared = CapturedShotStore()
  private init() {}
  private var images: [String: CGImage] = [:]

  func stash(_ image: CGImage, for path: String) { images[path] = image }
  func take(_ path: String) -> CGImage? { images.removeValue(forKey: path) }
}

/// Encode a captured `CGImage` into the attachment store. Free function (no actor) so it can run off
/// the main thread — encoding a retina region on the main actor would jank the summon.
func saveCapturedImage(_ cgImage: CGImage) -> String? {
  AssetStore.ingest(cgImage: cgImage)
}
