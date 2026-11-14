import AppKit

// MARK: - Attributes

extension NSAttributedString.Key {
  /// Marks a run of text ink colored with a theme tint slot (Int).
  static let inkSlot = NSAttributedString.Key("composer.inkSlot")
  /// Tags an inline image-attachment run with the on-disk PNG path for serialization.
  static let imageAttachmentPath = NSAttributedString.Key("composer.imageAttachmentPath")
}

// MARK: - Serialization (attributed → plain)

extension NSAttributedString {
  /// Self-contained plain text: inline image attachments collapse to "[image: <file>]";
  /// everything else is literal text.
  var composerPlainText: String { composerPlainTextAndInk.text }

  /// `composerPlainText` plus the ink runs: colored spans (`.inkSlot`) mapped into the
  /// serialized string's UTF-16 offsets, adjacent same-slot runs merged.
  var composerPlainTextAndInk: (text: String, ink: [InkRun]) {
    var out = ""
    var outLength = 0
    var runs: [InkRun] = []
    let ns = string as NSString
    var index = 0

    func appendPlain(_ piece: String, slot: Int?) {
      let pieceLength = (piece as NSString).length
      if let slot {
        if !runs.isEmpty, runs[runs.count - 1].slot == slot,
           runs[runs.count - 1].loc + runs[runs.count - 1].len == outLength {
          runs[runs.count - 1].len += pieceLength
        } else {
          runs.append(InkRun(loc: outLength, len: pieceLength, slot: slot))
        }
      }
      out += piece
      outLength += pieceLength
    }

    while index < length {
      var range = NSRange()
      let remaining = NSRange(location: index, length: length - index)
      if let path = attribute(.imageAttachmentPath, at: index, longestEffectiveRange: &range, in: remaining) as? String {
        let token = "[image: \((path as NSString).lastPathComponent)]"
        out += token
        outLength += (token as NSString).length
        index = range.location + range.length
      } else {
        // Advance by a whole composed-character sequence, not a single UTF-16 unit: emoji and
        // other non-BMP scalars are surrogate pairs (and ZWJ/skin-tone/flag emoji span several),
        // so a length-1 slice severs them and they corrupt to U+FFFD (the tofu glyph).
        let charRange = ns.rangeOfComposedCharacterSequence(at: index)
        let slot = attribute(.inkSlot, at: index, effectiveRange: nil) as? Int
        appendPlain(ns.substring(with: charRange), slot: slot)
        index = charRange.location + charRange.length
      }
    }
    return (out, runs)
  }
}

// MARK: - Deserialization (plain → attributed)

enum InkText {
  /// Inverse of `composerPlainTextAndInk` for the editor: rebuild an attributed string from
  /// serialized plain text, re-applying each ink run's tint. Image placeholders stay literal (the
  /// bitmap isn't recoverable from the serialized text).
  @MainActor
  static func attributedDocument(fromPlainText plain: String, font: NSFont,
                                 paragraph: NSParagraphStyle,
                                 ink: [InkRun] = []) -> NSAttributedString {
    let body: [NSAttributedString.Key: Any] = [
      .font: font, .foregroundColor: Theme.nsBodyText, .paragraphStyle: paragraph]
    let result = NSMutableAttributedString()
    let ns = plain as NSString
    var cursor = 0
    let end = ns.length
    // Offsets are serialized space, which is exactly what `plain` is.
    for run in ink.sorted(by: { $0.loc < $1.loc }) {
      let start = max(run.loc, cursor)
      let stop = min(run.loc + run.len, end)
      guard stop > start else { continue }
      if start > cursor {
        result.append(NSAttributedString(
          string: ns.substring(with: NSRange(location: cursor, length: start - cursor)),
          attributes: body))
      }
      var attrs = body
      attrs[.inkSlot] = run.slot
      if let color = Theme.tintColor(run.slot) { attrs[.foregroundColor] = color }
      result.append(NSAttributedString(
        string: ns.substring(with: NSRange(location: start, length: stop - start)),
        attributes: attrs))
      cursor = stop
    }
    if cursor < end {
      result.append(NSAttributedString(
        string: ns.substring(with: NSRange(location: cursor, length: end - cursor)),
        attributes: body))
    }
    return result
  }
}
