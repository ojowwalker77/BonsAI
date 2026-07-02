import AppKit

// MARK: - Mention catalog

/// How a mention is grouped in Settings. `app` entries are external connectors
/// (Context7, GitHub) surfaced in the Apps list; the rest are local helpers.
enum MentionKind {
  case app      // external connector with its own brand icon
  case skill    // bundled agent skill
  case clipboard
}

/// Groups connector apps in Settings (and the picker) by where their context comes from:
/// the local machine vs. an external service.
enum ConnectorCategory: String, CaseIterable {
  case local      // reads this Mac — files, tabs, build results — no account
  case service    // reaches an external tool/API

  var title: String {
    switch self {
    case .local: "On this Mac"
    case .service: "Services"
    }
  }
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
    // On this Mac — local context, no account
    .init(id: "@finder", title: "finder", label: "Finder", subtitle: "Local file or folder", symbol: "folder", kind: .app),
    .init(id: "@browser", title: "browser", label: "Browser", subtitle: "Open Safari or Chromium tab", symbol: "safari", kind: .app),
    .init(id: "@xcode", title: "xcode", label: "Xcode", subtitle: "Build errors & test failures", symbol: "hammer", kind: .app),
    // Services — external tools and APIs
    .init(id: "@github", title: "github", label: "GitHub", subtitle: "Issue or PR URL", symbol: "chevron.left.forwardslash.chevron.right", kind: .app),
    .init(id: "@context7", title: "context7", label: "Context7", subtitle: "Live library docs", symbol: "books.vertical", kind: .app),
    .init(id: "@linear", title: "linear", label: "Linear", subtitle: "Issue context", symbol: "checklist", kind: .app),
    .init(id: "@notion", title: "notion", label: "Notion", subtitle: "Pages, specs, docs", symbol: "doc.text", kind: .app),
    .init(id: "@sentry", title: "sentry", label: "Sentry", subtitle: "Issues & stack traces", symbol: "exclamationmark.triangle", kind: .app),
    .init(id: "@figma", title: "figma", label: "Figma", subtitle: "Frame from a URL", symbol: "paintpalette", kind: .app),
    // Skills + clipboard
    .init(id: "@build-macos-apps", title: "build-macos-apps", label: "build-macos-apps", subtitle: "Native macOS skill", symbol: "macwindow", kind: .skill),
    .init(id: "@build-ios-apps", title: "build-ios-apps", label: "build-ios-apps", subtitle: "SwiftUI iOS skill", symbol: "iphone", kind: .skill),
    .init(id: "@frontend-design", title: "frontend-design", label: "frontend-design", subtitle: "Polished web UI skill", symbol: "paintbrush", kind: .skill),
    .init(id: "@clipboard", title: "clipboard", label: "Clipboard", subtitle: "Paste current clipboard", symbol: "doc.on.clipboard", kind: .clipboard),
  ]

  /// External connector apps, in display order.
  static let apps: [MentionItem] = all.filter { $0.kind == .app }

  /// Which category each connector belongs to (see ConnectorCategory), keyed by token id.
  static let appCategory: [String: ConnectorCategory] = [
    "@finder": .local, "@browser": .local, "@xcode": .local,
    "@github": .service, "@context7": .service, "@linear": .service, "@notion": .service, "@sentry": .service, "@figma": .service,
  ]

  static func category(for id: String) -> ConnectorCategory? { appCategory[id] }

  /// Connector apps grouped by category, in category order, skipping empty groups.
  static var appsByCategory: [(category: ConnectorCategory, items: [MentionItem])] {
    ConnectorCategory.allCases.compactMap { category in
      let items = apps.filter { appCategory[$0.id] == category }
      return items.isEmpty ? nil : (category, items)
    }
  }

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
  /// Marks a run of text ink colored with a theme tint slot (Int). Chips never carry it.
  static let inkSlot = NSAttributedString.Key("composer.inkSlot")
  /// Tags an inline image-attachment run with the on-disk PNG path for serialization.
  static let imageAttachmentPath = NSAttributedString.Key("composer.imageAttachmentPath")
}

enum MentionToken {
  /// A styled, single-run token carrying its raw `token` so it round-trips to plain text.
  /// `label` is the visible text; `showDisclosure` appends a `▾` for interactive app chips.
  static func attributed(token: String, label: String, font: NSFont, showDisclosure: Bool) -> NSAttributedString {
    let chip = NSMutableAttributedString(string: label, attributes: [
      .font: font,
      .foregroundColor: Theme.Palette.nsAccent,
      .backgroundColor: Theme.Palette.nsAccent.withAlphaComponent(0.14),
    ])
    if showDisclosure { chip.append(MentionChip.disclosure(font: font, color: Theme.Palette.nsAccent.withAlphaComponent(0.42))) }
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
        // Advance by a whole composed-character sequence, not a single UTF-16 unit: emoji and
        // other non-BMP scalars are surrogate pairs (and ZWJ/skin-tone/flag emoji span several),
        // so a length-1 slice severs them and they corrupt to U+FFFD (the tofu glyph).
        let charRange = ns.rangeOfComposedCharacterSequence(at: index)
        out += ns.substring(with: charRange)
        index = charRange.location + charRange.length
      }
    }
    return out
  }

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
      if let id = attribute(.mentionToken, at: index, longestEffectiveRange: &range, in: remaining) as? String {
        out += id
        outLength += (id as NSString).length
        index = range.location + range.length
      } else if let path = attribute(.imageAttachmentPath, at: index, longestEffectiveRange: &range, in: remaining) as? String {
        let token = "[image: \((path as NSString).lastPathComponent)]"
        out += token
        outLength += (token as NSString).length
        index = range.location + range.length
      } else {
        let charRange = ns.rangeOfComposedCharacterSequence(at: index)
        let slot = attribute(.inkSlot, at: index, effectiveRange: nil) as? Int
        appendPlain(ns.substring(with: charRange), slot: slot)
        index = charRange.location + charRange.length
      }
    }
    return (out, runs)
  }
}
