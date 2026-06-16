import SwiftUI
import AppKit

// MARK: - Published state

/// Snapshot of the current selection for anchoring the floating action bar.
struct EditorSelection: Equatable {
  var range = NSRange(location: 0, length: 0)
  var text = ""
  /// Selection rect in the panel's SwiftUI space (top-left origin, y down).
  var rectInView: CGRect?
  var isEmpty: Bool { range.length == 0 }
}

/// Drives the `@` autocomplete overlay.
@MainActor
final class MentionState: ObservableObject {
  @Published var items: [MentionItem] = []
  @Published var selectedIndex = 0
  @Published var anchorInView: CGPoint?   // caret point in panel SwiftUI space
  @Published var isOpen = false
  /// Set by the coordinator; called by the SwiftUI list on click.
  var commitRequested: ((MentionItem) -> Void)?
}

/// A stable handle the canvas uses to drive the editor (focus, replace selection).
@MainActor
final class EditorController: ObservableObject {
  weak var coordinator: FreeWriteEditor.Coordinator?

  func focus() {
    guard let tv = coordinator?.textView else { return }
    tv.window?.makeFirstResponder(tv)
  }

  func replace(range: NSRange, with string: String) {
    coordinator?.replace(range: range, with: string)
  }

  /// Self-contained plain text with mention tokens serialized back to "@name".
  var plainText: String {
    guard let tv = coordinator?.textView else { return "" }
    return tv.attributedString().composerPlainText
  }
}

// MARK: - Representable

/// A chromeless free-write editor: a transparent `NSTextView` over the panel vibrancy.
struct FreeWriteEditor: NSViewRepresentable {
  @Binding var text: String
  var placeholder = "Start writing\u{2026}"
  var onCountChange: (Int) -> Void = { _ in }
  var onSelectionChange: (EditorSelection) -> Void = { _ in }
  var onEscape: () -> Void = {}
  @ObservedObject var mentions: MentionState
  @ObservedObject var appSearch: AppSearchState
  @ObservedObject var controller: EditorController

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  func makeNSView(context: Context) -> NSScrollView {
    let scrollView = NSScrollView()
    scrollView.borderType = .noBorder
    scrollView.drawsBackground = false
    scrollView.backgroundColor = .clear
    scrollView.hasVerticalScroller = false
    scrollView.hasHorizontalScroller = false
    scrollView.scrollerStyle = .overlay
    scrollView.automaticallyAdjustsContentInsets = false

    // Build the text stack by hand so we can use our ComposerTextView subclass
    // (scrollableTextView() always returns a plain NSTextView).
    let contentSize = scrollView.contentSize
    let container = NSTextContainer(
      containerSize: NSSize(width: contentSize.width, height: CGFloat.greatestFiniteMagnitude))
    container.widthTracksTextView = true
    container.heightTracksTextView = false
    let layoutManager = NSLayoutManager()
    layoutManager.addTextContainer(container)
    let storage = NSTextStorage()
    storage.addLayoutManager(layoutManager)

    let tv = ComposerTextView(frame: NSRect(origin: .zero, size: contentSize), textContainer: container)

    tv.drawsBackground = false
    tv.backgroundColor = .clear
    tv.isRichText = true            // keep: styled chips + image attachments persist in-session
    tv.importsGraphics = false      // keep FALSE: ComposerTextView is the only image path
    tv.isAutomaticQuoteSubstitutionEnabled = false
    tv.isAutomaticDashSubstitutionEnabled = false
    tv.isAutomaticTextReplacementEnabled = false
    tv.isAutomaticSpellingCorrectionEnabled = false
    tv.smartInsertDeleteEnabled = false
    tv.allowsUndo = true
    tv.insertionPointColor = .controlAccentColor
    tv.isVerticallyResizable = true
    tv.isHorizontallyResizable = false
    tv.autoresizingMask = [.width]
    tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    tv.minSize = NSSize(width: 0, height: contentSize.height)
    tv.textContainerInset = Theme.Inset.textContainer
    tv.font = Theme.Typography.body
    tv.defaultParagraphStyle = context.coordinator.paragraphStyle()
    tv.typingAttributes = context.coordinator.bodyAttributes()
    tv.textColor = .labelColor
    tv.delegate = context.coordinator
    scrollView.documentView = tv

    context.coordinator.textView = tv
    controller.coordinator = context.coordinator
    tv.onChipClick = { [weak coordinator = context.coordinator] range in
      coordinator?.handleChipClick(range)
    }

    if !text.isEmpty {
      tv.textStorage?.setAttributedString(
        NSAttributedString(string: text, attributes: context.coordinator.bodyAttributes()))
    }
    context.coordinator.installPlaceholder(in: tv, text: placeholder)
    context.coordinator.updatePlaceholderVisibility()

    // Restyle inserted chips when async favicons arrive.
    MentionStyleCache.shared.onUpdate = { [weak coordinator = context.coordinator] in
      coordinator?.updateExistingChips()
    }
    return scrollView
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    guard let tv = scrollView.documentView as? NSTextView else { return }
    context.coordinator.parent = self
    if tv.string != text {
      let sel = tv.selectedRange()
      tv.textStorage?.setAttributedString(
        NSAttributedString(string: text, attributes: context.coordinator.bodyAttributes()))
      let clamped = NSRange(location: min(sel.location, (text as NSString).length), length: 0)
      tv.setSelectedRange(clamped)
    }
    context.coordinator.updatePlaceholderVisibility()
  }
}

// MARK: - Coordinator

extension FreeWriteEditor {
  @MainActor
  final class Coordinator: NSObject, NSTextViewDelegate {
    var parent: FreeWriteEditor
    weak var textView: NSTextView?
    private let placeholderView = NSTextField(labelWithString: "")
    private var selectionWork: DispatchWorkItem?

    init(_ parent: FreeWriteEditor) {
      self.parent = parent
      super.init()
      parent.mentions.commitRequested = { [weak self] item in self?.commit(item) }
    }

    // MARK: Typography
    func paragraphStyle() -> NSMutableParagraphStyle {
      let style = NSMutableParagraphStyle()
      style.lineSpacing = Theme.Typography.bodyLineSpacing
      return style
    }
    func bodyAttributes() -> [NSAttributedString.Key: Any] {
      [.font: Theme.Typography.body,
       .foregroundColor: NSColor.labelColor,
       .paragraphStyle: paragraphStyle()]
    }

    // MARK: Text change → binding + count + mention scan
    func textDidChange(_ notification: Notification) {
      guard let tv = textView else { return }
      let value = tv.string
      if parent.text != value { parent.text = value }
      parent.onCountChange(value.count)
      updatePlaceholderVisibility()
      refreshMentionMenu(tv)
      publishSelection(tv)
    }

    // MARK: Selection change → debounced snapshot (anti-flicker on drag)
    func textViewDidChangeSelection(_ notification: Notification) {
      guard let tv = textView else { return }
      // Caret moved inside the editor (click-away / arrow keys) → dismiss app search.
      if parent.appSearch.isOpen { closeAppSearch() }
      refreshMentionMenu(tv)
      selectionWork?.cancel()
      let work = DispatchWorkItem { [weak self, weak tv] in
        guard let self, let tv else { return }
        self.publishSelection(tv)
      }
      selectionWork = work
      DispatchQueue.main.asyncAfter(deadline: .now() + Theme.Motion.selectionDebounce, execute: work)
    }

    private func publishSelection(_ tv: NSTextView) {
      let range = tv.selectedRange()
      var snap = EditorSelection(range: range,
                                 text: (tv.string as NSString).substring(with: range))
      if range.length > 0, let screen = screenRect(for: range) {
        snap.rectInView = panelRect(fromScreen: screen)
      }
      parent.onSelectionChange(snap)
    }

    // MARK: Undo-safe programmatic replacement (the Refine path)
    @discardableResult
    func replace(range targetRange: NSRange? = nil, with string: String) -> Bool {
      guard let tv = textView else { return false }
      let range = targetRange ?? tv.selectedRange()
      guard tv.shouldChangeText(in: range, replacementString: string) else { return false }
      tv.textStorage?.replaceCharacters(
        in: range, with: NSAttributedString(string: string, attributes: bodyAttributes()))
      tv.didChangeText()
      tv.setSelectedRange(NSRange(location: range.location, length: (string as NSString).length))
      parent.text = tv.string
      parent.onCountChange(tv.string.count)
      updatePlaceholderVisibility()
      publishSelection(tv)
      return true
    }

    // MARK: Geometry — everything resolves through screen space, then the panel frame.
    private func screenRect(for range: NSRange) -> CGRect? {
      guard let tv = textView, let lm = tv.layoutManager,
            let container = tv.textContainer, let win = tv.window else { return nil }
      let glyph = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
      var rect = lm.boundingRect(forGlyphRange: glyph, in: container)
      let origin = tv.textContainerOrigin
      rect = rect.offsetBy(dx: origin.x, dy: origin.y)
      let winRect = tv.convert(rect, to: nil)
      return win.convertToScreen(winRect)
    }

    /// Cocoa screen rect (y up) → panel SwiftUI space (top-left, y down).
    private func panelRect(fromScreen screen: CGRect) -> CGRect? {
      guard let frame = textView?.window?.frame else { return nil }
      return CGRect(x: screen.minX - frame.minX,
                    y: frame.maxY - screen.maxY,
                    width: screen.width, height: screen.height)
    }

    // MARK: @-mention detection
    private func refreshMentionMenu(_ tv: NSTextView) {
      guard let query = activeMentionQuery(in: tv) else { closeMenu(); return }
      let results = MentionCatalog.filtered(query.text)
      guard !results.isEmpty else { closeMenu(); return }

      let screen = tv.firstRect(forCharacterRange: query.range, actualRange: nil)
      if let frame = tv.window?.frame {
        parent.mentions.anchorInView = CGPoint(x: screen.minX - frame.minX,
                                               y: frame.maxY - screen.minY)
      }
      parent.mentions.items = results
      parent.mentions.selectedIndex = min(parent.mentions.selectedIndex, results.count - 1)
      parent.mentions.isOpen = true
    }

    private func closeMenu() {
      guard parent.mentions.isOpen || !parent.mentions.items.isEmpty else { return }
      parent.mentions.isOpen = false
      parent.mentions.items = []
      parent.mentions.selectedIndex = 0
      parent.mentions.anchorInView = nil
    }

    // MARK: Keyboard — Escape always handled; nav keys only while the menu is open
    func textView(_ tv: NSTextView, doCommandBy selector: Selector) -> Bool {
      if selector == #selector(NSResponder.cancelOperation(_:)) {
        if parent.mentions.isOpen { closeMenu() } else { parent.onEscape() }
        return true
      }
      guard parent.mentions.isOpen else { return false }
      switch selector {
      case #selector(NSResponder.moveUp(_:)): move(-1); return true
      case #selector(NSResponder.moveDown(_:)): move(+1); return true
      case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
        commitSelected(); return true
      default: return false
      }
    }
    private func move(_ delta: Int) {
      let count = parent.mentions.items.count
      guard count > 0 else { return }
      parent.mentions.selectedIndex = (parent.mentions.selectedIndex + delta + count) % count
    }
    private func commitSelected() {
      guard parent.mentions.items.indices.contains(parent.mentions.selectedIndex) else { return }
      commit(parent.mentions.items[parent.mentions.selectedIndex])
    }

    // MARK: Insert the chosen mention as an undo-safe chip + trailing space
    func commit(_ item: MentionItem) {
      guard let tv = textView, let query = activeMentionQuery(in: tv) else { return }
      let chip = ChipFactory.make(token: item.id, font: Theme.Typography.body)
      let token = NSMutableAttributedString(attributedString: chip)
      token.append(NSAttributedString(string: " ", attributes: bodyAttributes()))
      guard tv.shouldChangeText(in: query.range, replacementString: token.string) else { return }
      tv.textStorage?.replaceCharacters(in: query.range, with: token)
      tv.didChangeText()
      tv.setSelectedRange(NSRange(location: query.range.location + token.length, length: 0))
      tv.typingAttributes = bodyAttributes()
      parent.text = tv.string
      parent.onCountChange(tv.string.count)
      closeMenu()

      // Apps don't just tag — open their inline search so the user picks a concrete thing.
      if item.kind == .app {
        let chipRange = NSRange(location: query.range.location, length: chip.length)
        openAppSearch(appID: item.id, targetRange: chipRange, kind: nil)
      }
    }

    /// Restyle already-inserted chips in place when async favicons land. One
    /// shouldChangeText/didChangeText pair; edits applied descending so ranges stay valid.
    func updateExistingChips() {
      guard let tv = textView, let storage = tv.textStorage else { return }
      let saved = tv.selectedRange()

      var edits: [(NSRange, NSAttributedString)] = []
      storage.enumerateAttribute(.mentionToken,
                                 in: NSRange(location: 0, length: storage.length),
                                 options: []) { value, range, _ in
        guard let token = value as? String else { return }
        edits.append((range, ChipFactory.make(token: token, font: Theme.Typography.body)))
      }
      guard !edits.isEmpty else { return }

      let descending = edits.sorted { $0.0.location > $1.0.location }
      let full = NSRange(location: 0, length: storage.length)
      guard tv.shouldChangeText(in: full, replacementString: tv.string) else { return }
      storage.beginEditing()
      for (range, rebuilt) in descending {
        storage.replaceCharacters(in: range, with: rebuilt)
      }
      storage.endEditing()
      tv.didChangeText()

      var delta = 0
      for (range, rebuilt) in edits where range.location + range.length <= saved.location {
        delta += rebuilt.length - range.length
      }
      tv.setSelectedRange(NSRange(location: min(saved.location + delta, storage.length), length: 0))
      parent.text = tv.string
    }

    // MARK: - Inline app search (Context7 / GitHub)

    /// Open the search popover for the app token at `targetRange`, anchored under the chip.
    func openAppSearch(appID: String, targetRange: NSRange, kind: GitHubItemKind?) {
      guard let anchor = anchorBelow(range: targetRange) else { return }
      let state = parent.appSearch
      state.targetRange = targetRange
      state.appID = appID
      state.githubKind = kind ?? .issue
      state.query = ""
      state.results = []
      state.selectedIndex = 0
      state.isLoading = false
      state.errorText = nil
      state.anchorInView = anchor
      state.onCommit = { [weak self] result in self?.resolveSelection(result) }
      state.onCancel = { [weak self] in self?.closeAppSearchAndFocus() }
      state.isOpen = true
    }

    /// Clicking an app chip re-opens its search, pre-scoped to its current kind.
    func handleChipClick(_ range: NSRange) {
      guard let tv = textView, let storage = tv.textStorage, range.location < storage.length,
            let token = storage.attribute(.mentionToken, at: range.location, effectiveRange: nil) as? String,
            let parsed = AppToken.parse(token) else { return }
      var kind: GitHubItemKind?
      if case let .github(k, _) = parsed.selection { kind = k }
      closeMenu()
      openAppSearch(appID: parsed.appID, targetRange: range, kind: kind)
    }

    /// Replace the target chip with one resolved to the picked result, keeping one trailing space.
    func resolveSelection(_ result: AppSearchResult) {
      guard let tv = textView, let storage = tv.textStorage,
            let range = parent.appSearch.targetRange,
            range.location + range.length <= storage.length else { closeAppSearch(); return }

      let token = AppToken.string(appID: parent.appSearch.appID, selection: result.selection)
      let chip = NSMutableAttributedString(attributedString: ChipFactory.make(token: token, font: Theme.Typography.body))

      let after = range.location + range.length
      let hasSpace = after < storage.length &&
        (storage.string as NSString).substring(with: NSRange(location: after, length: 1)) == " "
      if !hasSpace { chip.append(NSAttributedString(string: " ", attributes: bodyAttributes())) }

      guard tv.shouldChangeText(in: range, replacementString: chip.string) else { closeAppSearch(); return }
      storage.replaceCharacters(in: range, with: chip)
      tv.didChangeText()
      tv.setSelectedRange(NSRange(location: range.location + chip.length, length: 0))
      tv.typingAttributes = bodyAttributes()
      parent.text = tv.string
      parent.onCountChange(tv.string.count)
      closeAppSearch()
      tv.window?.makeFirstResponder(tv)
    }

    func closeAppSearch() {
      let state = parent.appSearch
      guard state.isOpen else { return }
      state.isOpen = false
      state.targetRange = nil
      state.results = []
      state.anchorInView = nil
      state.onCommit = nil
      state.onCancel = nil
    }

    func closeAppSearchAndFocus() {
      closeAppSearch()
      textView?.window?.makeFirstResponder(textView)
    }

    /// Panel-space point at the bottom-left of the chip (same geometry as the `@` menu).
    private func anchorBelow(range: NSRange) -> CGPoint? {
      guard let tv = textView, let frame = tv.window?.frame else { return nil }
      let screen = tv.firstRect(forCharacterRange: range, actualRange: nil)
      guard screen.width.isFinite, screen.minY.isFinite else { return nil }
      return CGPoint(x: screen.minX - frame.minX, y: frame.maxY - screen.minY)
    }

    // MARK: Placeholder (NSTextView has none of its own)
    func installPlaceholder(in tv: NSTextView, text: String) {
      placeholderView.stringValue = text
      placeholderView.font = Theme.Typography.body
      placeholderView.textColor = .placeholderTextColor
      placeholderView.backgroundColor = .clear
      placeholderView.isBezeled = false
      placeholderView.drawsBackground = false
      placeholderView.translatesAutoresizingMaskIntoConstraints = false
      tv.addSubview(placeholderView)
      NSLayoutConstraint.activate([
        placeholderView.leadingAnchor.constraint(
          equalTo: tv.leadingAnchor, constant: Theme.Inset.textContainer.width + 5),
        placeholderView.topAnchor.constraint(
          equalTo: tv.topAnchor, constant: Theme.Inset.textContainer.height),
      ])
    }
    func updatePlaceholderVisibility() {
      placeholderView.isHidden = !(textView?.string.isEmpty ?? true)
    }
  }
}

// MARK: - Backward @-query scan

struct MentionQuery { let range: NSRange; let text: String } // range covers "@query" incl. @

/// Scan backward from the caret. nil if there's a real selection, whitespace before an @,
/// or an @ preceded by an alphanumeric (so "foo@bar" never triggers). UTF-16 units.
func activeMentionQuery(in tv: NSTextView) -> MentionQuery? {
  let sel = tv.selectedRange()
  guard sel.length == 0, sel.location > 0 else { return nil }
  let ns = tv.string as NSString
  let caret = sel.location
  var i = caret - 1
  while i >= 0 {
    guard let scalar = UnicodeScalar(ns.character(at: i)) else { return nil }
    let ch = Character(scalar)
    if ch == "@" {
      if i > 0, let prevScalar = UnicodeScalar(ns.character(at: i - 1)) {
        let prev = Character(prevScalar)
        if prev.isLetter || prev.isNumber { return nil }
      }
      return MentionQuery(
        range: NSRange(location: i, length: caret - i),
        text: ns.substring(with: NSRange(location: i + 1, length: caret - i - 1)))
    }
    if ch == " " || ch == "\n" || ch == "\t" { return nil }
    i -= 1
  }
  return nil
}
