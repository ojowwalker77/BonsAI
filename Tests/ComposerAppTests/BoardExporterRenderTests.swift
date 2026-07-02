import AppKit
import SwiftUI
import XCTest
@testable import ComposerApp

/// Proves the board PNG export renders through a real AppKit pass (`NSHostingView` in an offscreen
/// window) rather than SwiftUI's `ImageRenderer`. The old renderer produced garbage — a black
/// background with a yellow "cannot render" placeholder over every card, because each card carries
/// an `NSViewRepresentable` (the pointer catcher / AppKit text editor) that `ImageRenderer` refuses
/// to draw. These tests assert the produced bitmap has the right size, the real canvas color (not
/// black), no placeholder yellow, and actual drawn content where a text card sits.
@MainActor
final class BoardExporterRenderTests: XCTestCase {

  /// `ImageRenderer`'s "unrenderable view" placeholder is a saturated yellow. If any pixels match
  /// it, the render fell back to the broken path.
  private let placeholderYellow = NSColor(srgbRed: 1, green: 0.9, blue: 0, alpha: 1)

  /// The theme default as it was before the test forced a flavor, restored in tearDown.
  private var savedTheme: String?

  override func setUp() {
    super.setUp()
    // The real app always has an NSApplication; `xctest` does not. AppKit drawing (NSHostingView,
    // cacheDisplay) needs the shared app initialized or it faults, so bring it up here.
    _ = NSApplication.shared
    // Force a light flavor so the canvas base (cream 0xF5F4EF) is unambiguously NOT black — this
    // makes the "background isn't black" assertion meaningful (Bonsai Dark's base is pure black).
    savedTheme = UserDefaults.standard.string(forKey: ComposerPreferences.themeKey)
    UserDefaults.standard.set(ComposerTheme.bonsaiLight.rawValue, forKey: ComposerPreferences.themeKey)
  }

  override func tearDown() {
    if let savedTheme {
      UserDefaults.standard.set(savedTheme, forKey: ComposerPreferences.themeKey)
    } else {
      UserDefaults.standard.removeObject(forKey: ComposerPreferences.themeKey)
    }
    super.tearDown()
  }

  /// Two cards mirroring the Welcome board's kinds: a text card and a rectangle shape.
  private func seedBoard() -> (board: BoardViewModel, cards: [CardState]) {
    let text = CardState(
      kind: .text,
      text: "Export me: this text must actually draw, not show a placeholder.",
      x: 200, y: 200, w: 360, h: 120, z: 1
    )
    let rectangle = CardState(
      kind: .rectangle,
      text: "Shape",
      x: 620, y: 200, w: 220, h: 140, z: 2
    )
    // In-memory store: `swift test` is unsandboxed, so the shared store IS the user's real
    // Composer.store — seeding through it would schedule a save of junk cards into a real board.
    let board = BoardViewModel(store: DumpStore(inMemoryOnly: true))
    // insertCopies is the public seam that adds cards AND builds their CardInteraction (so the
    // live-render path resolves text via board.interaction(for:) exactly as on the real canvas).
    let ids = board.insertCopies([text, rectangle], offset: .zero)
    XCTAssertEqual(ids.count, 2, "both seed cards should be inserted")
    let inserted = board.cards.filter { ids.contains($0.id) }
    return (board, inserted)
  }

  func testRenderProducesNonNilImageAtDoubleResolution() {
    let (board, cards) = seedBoard()
    guard let bounds = BoardExporter.exportBounds(of: cards) else {
      return XCTFail("seeded board should have export bounds")
    }

    guard let image = BoardExporter.renderBoardImage(cards: cards, board: board) else {
      return XCTFail("renderBoardImage returned nil for a non-empty board")
    }
    guard let rep = bitmapRep(of: image) else {
      return XCTFail("rendered image has no bitmap representation")
    }

    let expectedW = Int((bounds.width * BoardExporter.renderScale).rounded())
    let expectedH = Int((bounds.height * BoardExporter.renderScale).rounded())
    XCTAssertEqual(rep.pixelsWide, expectedW, "bitmap should be 2× the bounds width in device pixels")
    XCTAssertEqual(rep.pixelsHigh, expectedH, "bitmap should be 2× the bounds height in device pixels")
  }

  func testCornerPixelIsCanvasColorNotBlack() {
    let (board, cards) = seedBoard()
    guard let image = BoardExporter.renderBoardImage(cards: cards, board: board),
          let rep = bitmapRep(of: image) else {
      return XCTFail("render failed")
    }

    // The margin around the content is pure canvas — the top-left corner is always background.
    guard let corner = rep.colorAt(x: 2, y: 2)?.usingColorSpace(.sRGB) else {
      return XCTFail("could not read corner pixel")
    }
    let expected = BoardExporter.resolvedCanvasColor()

    XCTAssertTrue(
      colorsClose(corner, expected, tolerance: 0.06),
      "corner should be the resolved windowCanvas color \(rgbString(expected)); got \(rgbString(corner))"
    )
    // And explicitly not black — the old bug's signature.
    XCTAssertFalse(
      colorsClose(corner, .black, tolerance: 0.06),
      "corner background must not be black (the old ImageRenderer bug); got \(rgbString(corner))"
    )
  }

  func testNoImageRendererPlaceholderYellowAnywhere() {
    let (board, cards) = seedBoard()
    guard let image = BoardExporter.renderBoardImage(cards: cards, board: board),
          let rep = bitmapRep(of: image) else {
      return XCTFail("render failed")
    }

    var placeholderHits = 0
    // Sample a broad grid across the whole bitmap.
    let stepsX = 60, stepsY = 40
    for i in 0..<stepsX {
      for j in 0..<stepsY {
        let x = rep.pixelsWide * i / stepsX
        let y = rep.pixelsHigh * j / stepsY
        if let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
           colorsClose(c, placeholderYellow, tolerance: 0.12) {
          placeholderHits += 1
        }
      }
    }
    XCTAssertEqual(placeholderHits, 0, "found \(placeholderHits) ImageRenderer placeholder-yellow pixels; the card views did not render")
  }

  func testTextCardRegionHasDrawnContent() {
    let (board, cards) = seedBoard()
    guard let bounds = BoardExporter.exportBounds(of: cards),
          let textCard = cards.first(where: { $0.elementKind == .text }),
          let image = BoardExporter.renderBoardImage(cards: cards, board: board),
          let rep = bitmapRep(of: image) else {
      return XCTFail("render failed")
    }

    // Map the text card's board frame into device-pixel space of the bitmap.
    let scale = BoardExporter.renderScale
    let localX = (textCard.x - Double(bounds.minX)) * Double(scale)
    let localY = (textCard.y - Double(bounds.minY)) * Double(scale)
    let localW = textCard.w * Double(scale)
    let localH = textCard.h * Double(scale)

    var distinctColors = Set<String>()
    let samples = 400
    var rng = SystemRandomNumberGenerator()
    for _ in 0..<samples {
      let px = Int(localX + Double.random(in: 4...(localW - 4), using: &rng))
      let py = Int(localY + Double.random(in: 4...(localH - 4), using: &rng))
      guard px >= 0, py >= 0, px < rep.pixelsWide, py < rep.pixelsHigh else { continue }
      if let c = rep.colorAt(x: px, y: py)?.usingColorSpace(.sRGB) {
        distinctColors.insert(rgbString(c))
      }
    }
    // A card that only painted its background would yield ~1 color. Real text (ink over card fill)
    // produces many distinct samples (anti-aliased glyph edges).
    XCTAssertGreaterThan(distinctColors.count, 3, "text-card region should contain drawn text, not a flat fill")
  }

  // MARK: Helpers

  private func bitmapRep(of image: NSImage) -> NSBitmapImageRep? {
    if let rep = image.representations.compactMap({ $0 as? NSBitmapImageRep }).first { return rep }
    guard let tiff = image.tiffRepresentation else { return nil }
    return NSBitmapImageRep(data: tiff)
  }

  private func colorsClose(_ a: NSColor, _ b: NSColor, tolerance: CGFloat) -> Bool {
    guard let a = a.usingColorSpace(.sRGB), let b = b.usingColorSpace(.sRGB) else { return false }
    return abs(a.redComponent - b.redComponent) <= tolerance
      && abs(a.greenComponent - b.greenComponent) <= tolerance
      && abs(a.blueComponent - b.blueComponent) <= tolerance
  }

  private func rgbString(_ color: NSColor) -> String {
    guard let c = color.usingColorSpace(.sRGB) else { return "??" }
    return String(format: "(%.2f, %.2f, %.2f)", c.redComponent, c.greenComponent, c.blueComponent)
  }
}
