import AppKit
import SwiftUI

/// Display-only markdown for board text. BonsAI styles the syntax IN PLACE — headings, emphasis,
/// code, quotes, lists, checkboxes — while the plain text keeps every marker, so agents and
/// Compile read ordinary markdown and nothing new is persisted. The same span scanner feeds the
/// live editor (NSAttributedString) and the static card render (SwiftUI AttributedString).
enum MarkdownStyle {
  /// Formatting actions the selection bar offers; applied as literal markdown syntax.
  enum Action {
    case heading   // cycles the line: none → # → ## → ### → none
    case bold      // **selection**
    case italic    // *selection*
    case code      // `selection`
    case quote     // toggles "> " on the selected lines
  }

  enum Kind: Equatable {
    case heading(Int)     // the line's text, sized by level
    case marker           // syntax characters (#, **, *, `, >) — dimmed
    case bold
    case italic
    case code             // inner code span — monospaced on a soft chip
    case quote            // quote line text
    case listMarker       // "- " / "1. " bullets
    case checkboxTodo     // "[ ]"
    case checkboxDone     // "[x]"
    case doneText         // text after a checked box — dimmed + struck
  }

  struct Span {
    let range: NSRange
    let kind: Kind
  }

  // MARK: Scanner

  private static let checkboxLine = try? NSRegularExpression(pattern: #"^(\s*)(- )(\[( |x|X)\])( )"#)
  private static let listLine = try? NSRegularExpression(pattern: #"^(\s*)((?:[-*+]|\d+\.) )"#)
  private static let headingLine = try? NSRegularExpression(pattern: #"^(#{1,3}) "#)
  private static let quoteLine = try? NSRegularExpression(pattern: #"^(> ?)"#)
  private static let boldInline = try? NSRegularExpression(pattern: #"\*\*([^*\n]+)\*\*"#)
  private static let italicInline = try? NSRegularExpression(pattern: #"(?<![\w*])\*([^*\n]+)\*(?!\*)"#)
  private static let codeInline = try? NSRegularExpression(pattern: #"`([^`\n]+)`"#)

  /// All markdown spans in the text, in document order. Ranges are UTF-16 offsets into `text`
  /// itself — for board cards the serialized plain text and the visible editor text agree on
  /// markdown regions (chips only ever replace `@token` runs, which the scanner ignores).
  static func spans(in text: String) -> [Span] {
    var spans: [Span] = []
    let ns = text as NSString
    ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length),
                           options: [.byLines, .substringNotRequired]) { _, lineRange, _, _ in
      scanLine(ns, lineRange: lineRange, into: &spans)
    }
    return spans
  }

  private static func scanLine(_ ns: NSString, lineRange: NSRange, into spans: inout [Span]) {
    let line = ns.substring(with: lineRange)
    let full = NSRange(location: 0, length: (line as NSString).length)
    func doc(_ r: NSRange) -> NSRange { NSRange(location: lineRange.location + r.location, length: r.length) }

    var inlineStart = 0

    if let match = checkboxLine?.firstMatch(in: line, range: full) {
      spans.append(Span(range: doc(match.range(at: 2)), kind: .listMarker))
      let boxRange = match.range(at: 3)
      let checked = line[Range(match.range(at: 4), in: line)!].lowercased() == "x"
      spans.append(Span(range: doc(boxRange), kind: checked ? .checkboxDone : .checkboxTodo))
      inlineStart = match.range.length
      if checked, full.length > inlineStart {
        spans.append(Span(range: doc(NSRange(location: inlineStart, length: full.length - inlineStart)),
                          kind: .doneText))
      }
    } else if let match = listLine?.firstMatch(in: line, range: full) {
      spans.append(Span(range: doc(match.range(at: 2)), kind: .listMarker))
      inlineStart = match.range.length
    } else if let match = headingLine?.firstMatch(in: line, range: full) {
      let level = match.range(at: 1).length
      spans.append(Span(range: doc(full), kind: .heading(level)))
      spans.append(Span(range: doc(NSRange(location: 0, length: match.range.length)), kind: .marker))
      return   // headings skip inline emphasis — mixed sizes inside a heading read broken
    } else if let match = quoteLine?.firstMatch(in: line, range: full) {
      spans.append(Span(range: doc(match.range(at: 1)), kind: .marker))
      if full.length > match.range.length {
        spans.append(Span(range: doc(NSRange(location: match.range.length, length: full.length - match.range.length)),
                          kind: .quote))
      }
    }

    let inlineRange = NSRange(location: inlineStart, length: full.length - inlineStart)
    guard inlineRange.length > 0 else { return }
    for (regex, kind) in [(boldInline, Kind.bold), (italicInline, .italic), (codeInline, .code)] {
      regex?.enumerateMatches(in: line, range: inlineRange) { match, _, _ in
        guard let match else { return }
        let inner = match.range(at: 1)
        spans.append(Span(range: doc(inner), kind: kind))
        let head = NSRange(location: match.range.location, length: inner.location - match.range.location)
        let tail = NSRange(location: inner.location + inner.length,
                           length: match.range.location + match.range.length - inner.location - inner.length)
        spans.append(Span(range: doc(head), kind: .marker))
        spans.append(Span(range: doc(tail), kind: .marker))
      }
    }
  }

  // MARK: Editor styling (NSAttributedString, display-only)

  /// Overlay markdown styles onto the live editor storage. Chip runs are skipped so brand chips
  /// never restyle. Runs inside the caller's begin/endEditing batch, after the body reset.
  static func apply(to storage: NSTextStorage, baseFont: NSFont) {
    for span in spans(in: storage.string) {
      guard span.range.location + span.range.length <= storage.length else { continue }
      let attrs = editorAttributes(for: span.kind, baseFont: baseFont)
      guard !attrs.isEmpty else { continue }
      storage.enumerateAttribute(.mentionToken, in: span.range) { value, sub, _ in
        guard value == nil else { return }
        storage.addAttributes(attrs, range: sub)
      }
    }
  }

  private static func editorAttributes(for kind: Kind, baseFont: NSFont) -> [NSAttributedString.Key: Any] {
    let size = baseFont.pointSize
    switch kind {
    case .heading(let level):
      let scale: CGFloat = level == 1 ? 1.5 : (level == 2 ? 1.28 : 1.14)
      return [.font: NSFont.systemFont(ofSize: (size * scale).rounded(), weight: level == 1 ? .bold : .semibold)]
    case .marker:
      return [.foregroundColor: Theme.flavor.overlay0]
    case .bold:
      return [.font: NSFont.systemFont(ofSize: size, weight: .bold)]
    case .italic:
      return [.font: NSFontManager.shared.convert(NSFont.systemFont(ofSize: size), toHaveTrait: .italicFontMask)]
    case .code:
      return [.font: NSFont.monospacedSystemFont(ofSize: max(size - 1, 10), weight: .regular),
              .backgroundColor: Theme.flavor.surface0.withAlphaComponent(0.55)]
    case .quote:
      return [.foregroundColor: Theme.flavor.subtext0,
              .font: NSFontManager.shared.convert(NSFont.systemFont(ofSize: size), toHaveTrait: .italicFontMask)]
    case .listMarker:
      return [.foregroundColor: Theme.flavor.overlay1]
    case .checkboxTodo:
      return [.foregroundColor: Theme.flavor.overlay1]
    case .checkboxDone:
      return [.foregroundColor: Theme.flavor.accent]
    case .doneText:
      return [.foregroundColor: Theme.flavor.overlay1,
              .strikethroughStyle: NSUnderlineStyle.single.rawValue]
    }
  }

  // MARK: Static styling (SwiftUI AttributedString, zoomed)

  /// The static-card render: styled AND with the syntax hidden — `**bold**` shows as bold,
  /// headings lose their hashes, `- ` becomes a real bullet, checkboxes become box glyphs.
  /// Markers are editing chrome; a card at rest shows the result.
  static func rendered(slice: String, sliceRange: NSRange, spans: [Span],
                       baseSize: CGFloat, zoom: CGFloat, ink: [InkRun] = []) -> AttributedString {
    var attributed = AttributedString(slice)
    style(&attributed, sliceRange: sliceRange, spans: spans, baseSize: baseSize, zoom: zoom)
    // Ink colors are applied in SERIALIZED-offset space (matching `spans`/`sliceRange`), BEFORE the
    // marker deletion below — so the color rides along with the surviving characters as markers are
    // removed. Ink wins over markdown's marker/quote colors on the inked characters.
    applyInk(&attributed, sliceRange: sliceRange, ink: ink)

    // Hide/replace syntax, walking edits from the END so earlier offsets stay valid.
    struct Edit { let start: Int; let end: Int; let replacement: String }
    let plain = String(attributed.characters)
    var edits: [Edit] = []
    for span in spans {
      let start = max(span.range.location, sliceRange.location)
      let end = min(span.range.location + span.range.length, sliceRange.location + sliceRange.length)
      guard end > start else { continue }
      let charStart = utf16ToCharacterOffset(start - sliceRange.location, in: plain)
      let charEnd = utf16ToCharacterOffset(end - sliceRange.location, in: plain)
      guard charEnd > charStart, charEnd <= plain.count else { continue }
      switch span.kind {
      case .marker:
        edits.append(Edit(start: charStart, end: charEnd, replacement: ""))
      case .listMarker:
        // Unordered bullets become a real bullet; ordered numbers stay; a checkbox line's
        // bullet vanishes (the box glyph carries the row).
        let text = String(plain[plain.index(plain.startIndex, offsetBy: charStart)..<plain.index(plain.startIndex, offsetBy: charEnd)])
        if text.first == "-" || text.first == "*" || text.first == "+" {
          let isCheckboxRow = spans.contains {
            ($0.kind == .checkboxTodo || $0.kind == .checkboxDone)
              && $0.range.location >= span.range.location
              && $0.range.location <= span.range.location + span.range.length + 4
          }
          edits.append(Edit(start: charStart, end: charEnd, replacement: isCheckboxRow ? "" : "•  "))
        }
      case .checkboxTodo:
        edits.append(Edit(start: charStart, end: charEnd, replacement: "☐"))
      case .checkboxDone:
        edits.append(Edit(start: charStart, end: charEnd, replacement: "☑"))
      default:
        break
      }
    }
    for edit in edits.sorted(by: { $0.start > $1.start }) {
      guard let lower = attributed.characters.index(attributed.startIndex, offsetBy: edit.start, limitedBy: attributed.endIndex),
            let upper = attributed.characters.index(attributed.startIndex, offsetBy: edit.end, limitedBy: attributed.endIndex),
            lower <= upper else { continue }
      if edit.replacement.isEmpty {
        attributed.removeSubrange(lower..<upper)
      } else {
        var replacement = AttributedString(edit.replacement)
        replacement.foregroundColor = attributed[lower..<upper].foregroundColor
        replacement.font = attributed[lower..<upper].font
        attributed.replaceSubrange(lower..<upper, with: replacement)
      }
    }
    return attributed
  }

  /// Apply markdown spans intersecting `sliceRange` to an AttributedString holding that slice.
  /// `sliceStart` is the slice's offset in the full plain text; fonts scale by `zoom`.
  static func style(_ attributed: inout AttributedString, sliceRange: NSRange,
                    spans: [Span], baseSize: CGFloat, zoom: CGFloat) {
    let plain = String(attributed.characters)
    for span in spans {
      let start = max(span.range.location, sliceRange.location)
      let end = min(span.range.location + span.range.length, sliceRange.location + sliceRange.length)
      guard end > start else { continue }
      let charStart = utf16ToCharacterOffset(start - sliceRange.location, in: plain)
      let charEnd = utf16ToCharacterOffset(end - sliceRange.location, in: plain)
      guard charEnd > charStart, charEnd <= plain.count else { continue }
      let lower = attributed.index(attributed.startIndex, offsetByCharacters: charStart)
      let upper = attributed.index(attributed.startIndex, offsetByCharacters: charEnd)
      guard lower < upper else { continue }
      let range = lower..<upper
      let size = baseSize * zoom
      switch span.kind {
      case .heading(let level):
        let scale: CGFloat = level == 1 ? 1.5 : (level == 2 ? 1.28 : 1.14)
        attributed[range].font = .system(size: (size * scale).rounded(), weight: level == 1 ? .bold : .semibold)
      case .marker:
        attributed[range].foregroundColor = Color(nsColor: Theme.flavor.overlay0)
      case .bold:
        attributed[range].font = .system(size: size, weight: .bold)
      case .italic:
        attributed[range].font = .system(size: size).italic()
      case .code:
        attributed[range].font = .system(size: max(size - 1, 9), design: .monospaced)
        attributed[range].backgroundColor = Color(nsColor: Theme.flavor.surface0.withAlphaComponent(0.55))
      case .quote:
        attributed[range].foregroundColor = Color(nsColor: Theme.flavor.subtext0)
        attributed[range].font = .system(size: size).italic()
      case .listMarker, .checkboxTodo:
        attributed[range].foregroundColor = Color(nsColor: Theme.flavor.overlay1)
      case .checkboxDone:
        attributed[range].foregroundColor = Color(nsColor: Theme.flavor.accent)
      case .doneText:
        attributed[range].foregroundColor = Color(nsColor: Theme.flavor.overlay1)
        attributed[range].strikethroughStyle = .single
      }
    }
  }

  /// Color the ink runs intersecting `sliceRange` onto `attributed` (which holds that slice in its
  /// pre-deletion serialized form). Offsets are serialized UTF-16, exactly like `sliceRange`. Slots
  /// re-resolve against the active flavor here, so ink follows a theme switch. Runs are applied in
  /// serialized space so the marker deletion in `rendered` carries the color forward.
  static func applyInk(_ attributed: inout AttributedString, sliceRange: NSRange, ink: [InkRun]) {
    guard !ink.isEmpty else { return }
    let plain = String(attributed.characters)
    for run in ink {
      guard let color = Theme.tintColor(run.slot) else { continue }
      let start = max(run.loc, sliceRange.location)
      let end = min(run.loc + run.len, sliceRange.location + sliceRange.length)
      guard end > start else { continue }
      let charStart = utf16ToCharacterOffset(start - sliceRange.location, in: plain)
      let charEnd = utf16ToCharacterOffset(end - sliceRange.location, in: plain)
      guard charEnd > charStart, charEnd <= plain.count else { continue }
      let lower = attributed.index(attributed.startIndex, offsetByCharacters: charStart)
      let upper = attributed.index(attributed.startIndex, offsetByCharacters: charEnd)
      guard lower < upper else { continue }
      attributed[lower..<upper].foregroundColor = Color(nsColor: color)
    }
  }

  /// AttributedString indexes by Characters; our ranges are UTF-16. For the plain slices we style
  /// (no attachments), a UTF-16 offset maps to a character offset by counting through the string.
  private static func utf16ToCharacterOffset(_ utf16: Int, in plain: String) -> Int {
    guard let idx = plain.utf16.index(plain.utf16.startIndex, offsetBy: utf16, limitedBy: plain.utf16.endIndex),
          let charIdx = idx.samePosition(in: plain) else { return plain.count }
    return plain.distance(from: plain.startIndex, to: charIdx)
  }

  // MARK: Writing flow helpers

  /// The list prefix of `line` (bullet, ordered, or checkbox), and the prefix the NEXT line
  /// should start with (numbers increment; checkboxes reset to unchecked).
  static func listContinuation(of line: String) -> (prefixLength: Int, next: String)? {
    let ns = line as NSString
    let full = NSRange(location: 0, length: ns.length)
    if let match = checkboxLine?.firstMatch(in: line, range: full) {
      let indent = ns.substring(with: match.range(at: 1))
      return (match.range.length, "\(indent)- [ ] ")
    }
    if let match = listLine?.firstMatch(in: line, range: full) {
      let indent = ns.substring(with: match.range(at: 1))
      let marker = ns.substring(with: match.range(at: 2))
      if let number = Int(marker.trimmingCharacters(in: CharacterSet(charactersIn: ". "))) {
        return (match.range.length, "\(indent)\(number + 1). ")
      }
      return (match.range.length, "\(indent)\(marker)")
    }
    return nil
  }

  /// The `[ ]`/`[x]` box range within the line, if this is a checkbox line (line-local range).
  static func checkboxBox(in line: String) -> (box: NSRange, checked: Bool)? {
    let ns = line as NSString
    guard let match = checkboxLine?.firstMatch(in: line, range: NSRange(location: 0, length: ns.length))
    else { return nil }
    let checked = ns.substring(with: match.range(at: 4)).lowercased() == "x"
    return (match.range(at: 3), checked)
  }
}
