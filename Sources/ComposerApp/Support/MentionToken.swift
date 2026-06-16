import AppKit

// MARK: - Mention catalog

/// How a mention is grouped in Settings. `app` entries are external connectors
/// (Context7, GitHub) surfaced in the Apps list; the rest are local helpers.
enum MentionKind {
  case app      // external connector with its own brand icon
  case skill    // bundled agent skill
  case clipboard
}

/// One entry in the `@` autocomplete. `id` is the raw token that gets serialized
/// back into the self-contained text (e.g. "@context7").
struct MentionItem: Identifiable, Hashable {
  let id: String        // raw token + serialized form, e.g. "@context7"
  let title: String     // lowercase match key, e.g. "context7"
  let label: String     // pretty chip label, e.g. "Context7"
  let subtitle: String  // "Live library docs"
  let symbol: String    // SF Symbol
  let kind: MentionKind
}

enum MentionCatalog {
  static let all: [MentionItem] = [
    .init(id: "@context7", title: "context7", label: "Context7", subtitle: "Live library docs", symbol: "books.vertical", kind: .app),
    .init(id: "@github", title: "github", label: "GitHub", subtitle: "Issue or PR URL", symbol: "chevron.left.forwardslash.chevron.right", kind: .app),
    .init(id: "@build-macos-apps", title: "build-macos-apps", label: "build-macos-apps", subtitle: "Native macOS skill", symbol: "macwindow", kind: .skill),
    .init(id: "@build-ios-apps", title: "build-ios-apps", label: "build-ios-apps", subtitle: "SwiftUI iOS skill", symbol: "iphone", kind: .skill),
    .init(id: "@frontend-design", title: "frontend-design", label: "frontend-design", subtitle: "Polished web UI skill", symbol: "paintbrush", kind: .skill),
    .init(id: "@clipboard", title: "clipboard", label: "Clipboard", subtitle: "Paste current clipboard", symbol: "doc.on.clipboard", kind: .clipboard),
  ]

  /// External connector apps, in display order (Context7 and GitHub are the first two).
  static let apps: [MentionItem] = all.filter { $0.kind == .app }

  static func filtered(_ query: String) -> [MentionItem] {
    guard !query.isEmpty else { return all }
    let q = query.lowercased()
    let prefix = all.filter { $0.title.lowercased().hasPrefix(q) }
    let contains = all.filter { !$0.title.lowercased().hasPrefix(q) && $0.title.lowercased().contains(q) }
    return prefix + contains
  }
}

// MARK: - Token attribute

extension NSAttributedString.Key {
  static let mentionToken = NSAttributedString.Key("composer.mentionToken")
  /// Tags an inline image-attachment run with the on-disk PNG path for serialization.
  static let imageAttachmentPath = NSAttributedString.Key("composer.imageAttachmentPath")
}

enum MentionToken {
  /// A styled, single-run token carrying its raw `token` so it round-trips to plain text.
  /// `label` is the visible text; `showDisclosure` appends a `▾` for interactive app chips.
  static func attributed(token: String, label: String, font: NSFont, showDisclosure: Bool) -> NSAttributedString {
    let chip = NSMutableAttributedString(string: label, attributes: [
      .font: font,
      .foregroundColor: NSColor.controlAccentColor,
      .backgroundColor: NSColor.controlAccentColor.withAlphaComponent(0.14),
    ])
    if showDisclosure { chip.append(MentionChip.disclosure(font: font, color: .controlAccentColor)) }
    chip.addAttribute(.mentionToken, value: token, range: NSRange(location: 0, length: chip.length))
    return chip
  }
}

extension NSAttributedString {
  /// Self-contained plain text:
  /// - mention chips/tokens collapse to their raw id ("@github"), once per chip;
  /// - inline image attachments collapse to "[image: <file>]";
  /// - everything else is literal text.
  ///
  /// A chip is multiple style runs (icon attachment + thin space + colored name) that
  /// share one `.mentionToken` value, so we walk by `longestEffectiveRange` per key to
  /// emit each chip exactly once.
  var composerPlainText: String {
    var out = ""
    let ns = string as NSString
    var index = 0
    while index < length {
      var range = NSRange()
      let remaining = NSRange(location: index, length: length - index)

      if let id = attribute(.mentionToken, at: index, longestEffectiveRange: &range, in: remaining) as? String {
        out += id
        index = range.location + range.length
      } else if let path = attribute(.imageAttachmentPath, at: index, longestEffectiveRange: &range, in: remaining) as? String {
        out += "[image: \((path as NSString).lastPathComponent)]"
        index = range.location + range.length
      } else {
        out += ns.substring(with: NSRange(location: index, length: 1))
        index += 1
      }
    }
    return out
  }
}
