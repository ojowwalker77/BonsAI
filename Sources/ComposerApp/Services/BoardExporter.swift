import AppKit
import SwiftUI

/// Exports the current board to an image file. The SwiftUI render (reusing the live `BoardCardView`
/// layer at zoom 1) lives in `ComposerCanvas`, which owns the private card views; this service owns
/// the parts that don't touch those views: content-bounds math, the save panel, and PNG encoding.
enum BoardExporter {
  /// Uniform margin painted around the content on every side (board points).
  static let margin: CGFloat = 64

  /// The tight bounding box of every card on the board (board coordinates), or nil when empty.
  static func contentBounds(of cards: [CardState]) -> CGRect? {
    guard !cards.isEmpty else { return nil }
    let minX = cards.map(\.x).min() ?? 0
    let minY = cards.map(\.y).min() ?? 0
    let maxX = cards.map { $0.x + $0.w }.max() ?? 0
    let maxY = cards.map { $0.y + $0.h }.max() ?? 0
    return CGRect(x: minX, y: minY, width: max(maxX - minX, 1), height: max(maxY - minY, 1))
  }

  /// The content bounds expanded by the export margin on all sides.
  static func exportBounds(of cards: [CardState]) -> CGRect? {
    contentBounds(of: cards)?.insetBy(dx: -margin, dy: -margin)
  }

  /// Decode a card image at full resolution for the export render. Synchronous on purpose: the
  /// offscreen render can't wait on the canvas's async thumbnail cache.
  static func loadImage(atPath path: String) -> NSImage? {
    NSImage(contentsOfFile: path)
  }

  /// Pixel scale of the exported PNG (2× for retina-crisp text).
  static let renderScale: CGFloat = 2

  /// Render the whole board to an `NSImage` and return it, or nil on failure (already reported).
  ///
  /// This is a REAL AppKit render pass, not `ImageRenderer`: it hosts the same SwiftUI card layer
  /// inside an `NSHostingView` in an offscreen `NSWindow`, so `NSViewRepresentable`-backed subviews
  /// (the pointer catcher on every card, the AppKit text editor) draw properly instead of showing
  /// `ImageRenderer`'s yellow "cannot render" placeholder. The window's appearance is set to the
  /// active theme's `NSAppearance` so palette colors resolve to the current flavor, and its
  /// background is painted with the resolved canvas color so nothing composites down to black.
  @MainActor
  static func renderBoardImage(cards: [CardState], board: BoardViewModel) -> NSImage? {
    guard let bounds = exportBounds(of: cards) else { return nil }

    // Pre-decode every image card so the provider is a synchronous lookup during the render.
    var images: [String: NSImage] = [:]
    for card in cards where card.elementKind == .image {
      if let path = card.imagePath, images[path] == nil, let image = loadImage(atPath: path) {
        images[path] = image
      }
    }

    // The card layer at scale 1, offset so the content-bounds origin maps to (0,0), on the canvas.
    let content = BoardCardLayer(
      cards: cards,
      board: board,
      selectedCardIDs: [],
      editingCardID: nil,
      primarySelectedCardID: nil,
      scale: 1,
      selectable: false,
      failedShellCommands: board.failedShellCommands,
      onEscape: {}
    )
    .frame(width: bounds.width, height: bounds.height, alignment: .topLeading)
    .offset(x: -bounds.minX, y: -bounds.minY)
    .frame(width: bounds.width, height: bounds.height, alignment: .topLeading)
    .background(Theme.Palette.windowCanvas)
    .environment(\.exportImageProvider, { images[$0] })

    return snapshot(content, size: bounds.size)
  }

  /// Host `content` offscreen at `size` points and snapshot it to an `NSImage` at `renderScale`
  /// device pixels. Generic so the render path is exercisable from tests with any SwiftUI content.
  @MainActor
  static func snapshot<Content: View>(_ content: Content, size: CGSize) -> NSImage? {
    let pointRect = CGRect(origin: .zero, size: size)
    let canvasColor = resolvedCanvasColor()

    // A real host: a borderless offscreen window gives the hosting view an appearance, a backing
    // store, and a live layout pass — everything `ImageRenderer` lacks.
    let hosting = NSHostingView(rootView: content)
    hosting.frame = pointRect
    let window = NSWindow(
      contentRect: pointRect,
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )
    // A programmatically created NSWindow defaults to `isReleasedWhenClosed = true`; combined with
    // ARC that double-frees the window on teardown (an over-release crash in `objc_release`). Own
    // the lifetime explicitly and just order it out instead of `close()`.
    window.isReleasedWhenClosed = false
    window.appearance = ComposerPreferences.theme.nsAppearance
    // Belt-and-braces: paint the window/host background with the canvas color so translucent or
    // unpainted regions never composite down to black.
    window.isOpaque = true
    window.backgroundColor = canvasColor
    window.contentView = hosting
    hosting.wantsLayer = true
    hosting.layer?.backgroundColor = canvasColor.cgColor

    // Force a full layout + display pass so representables and text lay out before we read pixels.
    hosting.layoutSubtreeIfNeeded()
    window.displayIfNeeded()

    defer {
      window.orderOut(nil)
      window.contentView = nil
    }

    guard let rep = hosting.bitmapImageRepForCachingDisplay(in: pointRect) else {
      UserFacingError.report("BonsAI could not allocate a bitmap to render the board for export.")
      return nil
    }
    // Upscale the cache rep to `renderScale` device pixels for crisp text (points stay the same;
    // pixel dimensions are multiplied). AppKit renders text into the larger backing at full clarity.
    rep.size = size
    if let scaled = NSBitmapImageRep(
      bitmapDataPlanes: nil,
      pixelsWide: Int((size.width * renderScale).rounded()),
      pixelsHigh: Int((size.height * renderScale).rounded()),
      bitsPerSample: 8,
      samplesPerPixel: 4,
      hasAlpha: true,
      isPlanar: false,
      colorSpaceName: .calibratedRGB,
      bytesPerRow: 0,
      bitsPerPixel: 0
    ) {
      scaled.size = size
      hosting.cacheDisplay(in: pointRect, to: scaled)
      let image = NSImage(size: size)
      image.addRepresentation(scaled)
      return image
    }

    // Fallback: 1× snapshot if the scaled rep couldn't be created.
    hosting.cacheDisplay(in: pointRect, to: rep)
    let image = NSImage(size: size)
    image.addRepresentation(rep)
    return image
  }

  /// The active flavor's canvas base as an `NSColor` in a concrete RGB space (so `cgColor` and the
  /// window background are well-defined and tests can compare exact channel values).
  @MainActor
  static func resolvedCanvasColor() -> NSColor {
    let base = Theme.flavor.base
    return base.usingColorSpace(.sRGB) ?? base
  }

  /// Present a Save panel as a sheet on the key window and, on confirm, write `image` as a PNG.
  /// Mirrors `CanvasAgent.chooseDirectory`: the busy notification suppresses the panel/overlay's
  /// click-away dismissal while the sheet is up.
  @MainActor
  static func presentSavePanel(image: NSImage, suggestedName: String) {
    NotificationCenter.default.post(name: .composerBusyChanged, object: nil, userInfo: ["busy": true])
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.png]
    panel.canCreateDirectories = true
    panel.nameFieldStringValue = sanitizedFileName(suggestedName) + ".png"
    panel.title = "Export Board"
    panel.message = "Export this board as a PNG image."

    let apply: (NSApplication.ModalResponse) -> Void = { response in
      if response == .OK, let url = panel.url { write(image: image, to: url) }
      NotificationCenter.default.post(name: .composerBusyChanged, object: nil, userInfo: ["busy": false])
    }
    if let window = NSApp.keyWindow {
      panel.beginSheetModal(for: window, completionHandler: apply)
    } else {
      apply(panel.runModal())
    }
  }

  /// Encode `image` to PNG and write it to `url` (same TIFF → bitmap → PNG path as pasted-image save).
  private static func write(image: NSImage, to url: URL) {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
      UserFacingError.report("BonsAI could not convert the board into PNG data. The board was not exported.")
      return
    }
    do {
      try png.write(to: url)
    } catch {
      UserFacingError.report(error, while: "Exporting the board as PNG")
    }
  }

  /// Strip path-hostile characters so a board title is a safe file name; never empty.
  private static func sanitizedFileName(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    let cleaned = trimmed
      .replacingOccurrences(of: "/", with: "-")
      .replacingOccurrences(of: ":", with: "-")
      .replacingOccurrences(of: "\n", with: " ")
    return cleaned.isEmpty ? "Board" : String(cleaned.prefix(80))
  }
}
