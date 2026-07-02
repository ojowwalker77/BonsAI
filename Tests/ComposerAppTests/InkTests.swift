import AppKit
import SwiftUI
import XCTest
@testable import ComposerApp

/// Per-range text ink: the serialized-offset span model that lets a text card color a selected
/// word instead of the whole card. These pin the extractor/restorer round-trip and the offset
/// mapping through markdown marker deletion — the two places offsets could drift.
@MainActor
final class InkTests: XCTestCase {
  private var body: [NSAttributedString.Key: Any] {
    [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: Theme.nsBodyText]
  }

  /// A single inked span extracts to one run in serialized-offset space.
  func testExtractSingleRun() {
    let s = NSMutableAttributedString(string: "hello world", attributes: body)
    s.addAttribute(.inkSlot, value: 2, range: NSRange(location: 0, length: 5))   // "hello"
    let (text, ink) = s.composerPlainTextAndInk
    XCTAssertEqual(text, "hello world")
    XCTAssertEqual(ink, [InkRun(loc: 0, len: 5, slot: 2)])
  }

  /// Adjacent characters carrying the same slot merge into one run; a different slot breaks it.
  func testAdjacentSameSlotMerges() {
    let s = NSMutableAttributedString(string: "abcdef", attributes: body)
    s.addAttribute(.inkSlot, value: 1, range: NSRange(location: 0, length: 2))
    s.addAttribute(.inkSlot, value: 1, range: NSRange(location: 2, length: 2))   // same slot, adjacent
    s.addAttribute(.inkSlot, value: 3, range: NSRange(location: 4, length: 2))   // different slot
    let (_, ink) = s.composerPlainTextAndInk
    XCTAssertEqual(ink, [InkRun(loc: 0, len: 4, slot: 1), InkRun(loc: 4, len: 2, slot: 3)])
  }

  /// No ink → no runs (so `snapshot()` writes nil, not an empty array).
  func testNoInkEmits() {
    let s = NSMutableAttributedString(string: "plain", attributes: body)
    XCTAssertTrue(s.composerPlainTextAndInk.ink.isEmpty)
  }

  /// A chip run collapses to its serialized token; ink offsets are measured over the SERIALIZED
  /// text, so a run after a chip is located past the token's full length, not the chip's label.
  func testInkOffsetsAreSerialized() {
    let font = NSFont.systemFont(ofSize: 13)
    let doc = NSMutableAttributedString(attributedString: ChipFactory.make(token: "@github", font: font))
    doc.append(NSAttributedString(string: " done", attributes: body))
    // Ink the "done" word — after "@github " (8 serialized UTF-16 units).
    let visibleDone = (doc.string as NSString).range(of: "done")
    doc.addAttribute(.inkSlot, value: 0, range: visibleDone)
    let (text, ink) = doc.composerPlainTextAndInk
    XCTAssertEqual(text, "@github done")
    XCTAssertEqual(ink, [InkRun(loc: 8, len: 4, slot: 0)])
  }

  /// Restorer round-trip: re-applying persisted runs to plain text re-attaches `.inkSlot` on the
  /// right characters, and re-extraction reproduces the runs (offsets survive the round-trip).
  func testRestorerReattachesInk() {
    let plain = "color me here"
    let runs = [InkRun(loc: 6, len: 2, slot: 1)]   // "me"
    let restored = ChipFactory.attributedDocument(
      fromPlainText: plain, font: NSFont.systemFont(ofSize: 13),
      paragraph: NSParagraphStyle(), ink: runs)
    XCTAssertEqual(restored.string, plain)
    let slot = restored.attribute(.inkSlot, at: 6, effectiveRange: nil) as? Int
    XCTAssertEqual(slot, 1)
    XCTAssertEqual(restored.composerPlainTextAndInk.ink, runs)
  }

  /// The static-render offset mapping: an ink run over the INNER text of a bold span still lands on
  /// the surviving characters after markdown deletes the `**` markers.
  func testRenderedInkSurvivesMarkerDeletion() {
    let plain = "**hi** world"
    let spans = MarkdownStyle.spans(in: plain)
    // "hi" is serialized offsets 2..<4 (inside the markers).
    let ink = [InkRun(loc: 2, len: 2, slot: 0)]
    let rendered = MarkdownStyle.rendered(
      slice: plain, sliceRange: NSRange(location: 0, length: (plain as NSString).length),
      spans: spans, baseSize: 13, zoom: 1, ink: ink)
    XCTAssertEqual(String(rendered.characters), "hi world")   // markers gone
    // The first two characters ("hi") carry the resolved tint color; the space/"world" don't.
    let expected = Theme.tintColor(0).map { Color(nsColor: $0) }
    let start = rendered.startIndex
    let afterHi = rendered.index(start, offsetByCharacters: 2)
    XCTAssertEqual(rendered[start..<afterHi].foregroundColor, expected)
  }
}
