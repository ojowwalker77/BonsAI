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

  func testStoredAttachmentFilenameLoadsThroughAssetStore() throws {
    let filename = try writeStoredTestImage()
    defer { try? FileManager.default.removeItem(at: AssetStore.storeDirectory.appendingPathComponent(filename)) }

    guard let image = BoardExporter.loadImage(storedPath: filename) else {
      return XCTFail("export should resolve the stored attachment filename through AssetStore")
    }
    XCTAssertEqual(image.size.width, 32, accuracy: 0.5)
    XCTAssertEqual(image.size.height, 32, accuracy: 0.5)
  }

  func testWholeBoardRenderIncludesStoredImageCardAtDistantEdge() throws {
    let filename = try writeStoredTestImage()
    defer { try? FileManager.default.removeItem(at: AssetStore.storeDirectory.appendingPathComponent(filename)) }

    let text = CardState(kind: .text, text: "Top-left", x: -240, y: -120, w: 180, h: 80, z: 1)
    let picture = CardState(
      kind: .image,
      x: 980,
      y: 720,
      w: 160,
      h: 120,
      z: 2,
      imagePath: filename
    )
    let board = BoardViewModel(store: DumpStore(inMemoryOnly: true))
    let ids = board.insertCopies([text, picture], offset: .zero)
    let cards = board.cards.filter { ids.contains($0.id) }

    guard let bounds = BoardExporter.exportBounds(of: cards) else {
      return XCTFail("distant cards should produce export bounds")
    }
    XCTAssertLessThanOrEqual(bounds.minX, CGFloat(text.x) - BoardExporter.margin)
    XCTAssertGreaterThanOrEqual(bounds.maxX, CGFloat(picture.x + picture.w) + BoardExporter.margin)
    XCTAssertGreaterThanOrEqual(bounds.maxY, CGFloat(picture.y + picture.h) + BoardExporter.margin)

    guard let image = BoardExporter.renderBoardImage(cards: cards, board: board),
          let rep = bitmapRep(of: image) else {
      return XCTFail("whole-board render failed")
    }

    // Find pixels from the solid-red fixture anywhere in the whole-board bitmap. Before the fix
    // export showed the neutral dashed placeholder because it treated the stored filename as an
    // absolute path, so no red pixels existed. Scanning also avoids coupling the assertion to
    // AppKit's bottom-left bitmap origin versus SwiftUI's top-left board coordinates.
    var foundImagePixel = false
    outer: for x in stride(from: 0, to: rep.pixelsWide, by: 12) {
      for y in stride(from: 0, to: rep.pixelsHigh, by: 12) {
        guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
        if color.redComponent > 0.75, color.greenComponent < 0.20, color.blueComponent < 0.20 {
          foundImagePixel = true
          break outer
        }
      }
    }
    XCTAssertTrue(foundImagePixel, "stored image pixels should appear in the whole-board export")
  }

  // MARK: Helpers

  private func writeStoredTestImage() throws -> String {
    try FileManager.default.createDirectory(
      at: AssetStore.storeDirectory,
      withIntermediateDirectories: true
    )
    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(
            data: nil,
            width: 32,
            height: 32,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          ) else {
      throw TestImageError.bitmapAllocationFailed
    }
    context.setFillColor(red: 0.95, green: 0.02, blue: 0.02, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
    guard let cgImage = context.makeImage() else {
      throw TestImageError.bitmapAllocationFailed
    }
    let rep = NSBitmapImageRep(cgImage: cgImage)
    guard let png = rep.representation(using: .png, properties: [:]) else {
      throw TestImageError.pngEncodingFailed
    }
    let filename = "board-export-test-\(UUID().uuidString).png"
    try png.write(to: AssetStore.storeDirectory.appendingPathComponent(filename))
    return filename
  }

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

  private enum TestImageError: Error {
    case bitmapAllocationFailed
    case pngEncodingFailed
  }
}
