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

/// A stable handle the canvas uses to drive the editor (focus, replace selection).
@MainActor
final class EditorController: ObservableObject {
  weak var coordinator: FreeWriteEditor.Coordinator?

  func focus() {
    guard let tv = coordinator?.textView else { return }
    tv.window?.makeFirstResponder(tv)
  }

  /// Drop first responder so the card leaves text-edit mode (back to selected/movable).
  func resignFocus() {
    guard let tv = coordinator?.textView, tv.window?.firstResponder == tv else { return }
    tv.window?.makeFirstResponder(nil)
  }

  /// Apply a markdown formatting action (selection bar) to the current selection/line.
  func applyMarkdown(_ action: MarkdownStyle.Action) {
    coordinator?.applyMarkdown(action)
  }

  /// Ink the current selection with a theme tint slot (`nil` clears ink on the range). Returns
  /// false when there's no selection so the caller can fall back to whole-card tinting.
  @discardableResult
  func applyInk(_ slot: Int?) -> Bool {
    coordinator?.applyInk(slot) ?? false
  }

  /// Self-contained plain text (image attachments serialized as placeholders).
  var plainText: String {
    plainTextIfLoaded ?? ""
  }

  var plainTextIfLoaded: String? {
    guard let tv = coordinator?.textView else { return nil }
    return tv.attributedString().composerPlainText
  }

  /// Serialized text plus its ink runs, extracted from the same attributed string so their
  /// offsets always agree. Nil while the heavy editor is unmounted.
  var plainTextAndInkIfLoaded: (text: String, ink: [InkRun])? {
    guard let tv = coordinator?.textView else { return nil }
    return tv.attributedString().composerPlainTextAndInk
  }

  /// A lossless copy of the whole document (ink + attachments).
  var attributedSnapshot: NSAttributedString? {
    guard let storage = coordinator?.textView?.textStorage else { return nil }
    return storage.attributedSubstring(from: NSRange(location: 0, length: storage.length))
  }
}

// MARK: - Representable

/// A chromeless free-write editor: a transparent `NSTextView` over the panel vibrancy.
struct FreeWriteEditor: NSViewRepresentable {
  @Binding var text: String
  var initialAttributedText: NSAttributedString?
  /// Persisted per-range ink for the serialized `text`, re-applied when the document is rebuilt
  /// from plain text (a reloaded card with no in-session attributed snapshot).
  var initialInk: [InkRun] = []
  var placeholder = "Start writing...".localizedUI
  var onCountChange: (Int) -> Void = { _ in }
  var onSelectionChange: (EditorSelection) -> Void = { _ in }
  var onEscape: () -> Void = {}
  /// Fired when this editor gains/loses first responder (canvas active-card tracking).
  var onFocusChange: (Bool) -> Void = { _ in }
  /// Reports the editor's OWN layout — natural (unwrapped) content width and laid-out content
  /// height — so a text card can hug what's typed (issue #76). The live NSTextView is the only
  /// sizing authority while editing: a parallel NSString measurement wraps ~10pt later than the
  /// view (different insets/fragment padding), and sizing the card from it left the frame a line
  /// short — the editor then scrolled to the caret and clipped the top line.
  var onLayoutChange: (_ naturalWidth: CGFloat, _ contentHeight: CGFloat) -> Void = { _, _ in }
  /// The editing card's per-card font multiplier (issue #77 corner-drag scaling). The editor font
  /// (and line spacing) scale by it so a live edit matches the static render's `fontSize × textScale`.
  /// 1 for a never-scaled card, so the common path is byte-for-byte unchanged.
  var fontScale: CGFloat = 1
  /// The editing card's whole-card tint slot, so clearing range ink restores the card tint's
  /// color (not the flavor body ink) on the cleared span.
  var cardTint: (() -> Int?)? = nil
  @ObservedObject var controller: EditorController
  @ObservedObject var store: DumpStore

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
    tv.isRichText = true            // keep: ink + image attachments persist in-session
    tv.importsGraphics = false      // keep FALSE: ComposerTextView is the only image path
    tv.isAutomaticQuoteSubstitutionEnabled = false
    tv.isAutomaticDashSubstitutionEnabled = false
    tv.isAutomaticTextReplacementEnabled = false
    tv.isAutomaticSpellingCorrectionEnabled = false
    tv.smartInsertDeleteEnabled = false
    tv.allowsUndo = true
    tv.insertionPointColor = Theme.Palette.nsAccent
    tv.isVerticallyResizable = true
    tv.isHorizontallyResizable = false
    tv.autoresizingMask = [.width]
    tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    tv.minSize = NSSize(width: 0, height: contentSize.height)
    tv.textContainerInset = Theme.Inset.textContainer
    tv.font = context.coordinator.baseFont
    tv.defaultParagraphStyle = context.coordinator.paragraphStyle()
    tv.typingAttributes = context.coordinator.bodyAttributes()
    tv.textColor = Theme.nsBodyText
    tv.delegate = context.coordinator
    scrollView.documentView = tv

    context.coordinator.textView = tv
    controller.coordinator = context.coordinator
    tv.onFocusChange = { [weak coordinator = context.coordinator] active in
      coordinator?.parent.onFocusChange(active)
    }

    if let initialAttributedText {
      tv.textStorage?.setAttributedString(initialAttributedText)
    } else if !text.isEmpty {
      // `text` is the serialized form — rebuild it with its persisted ink runs so a reloaded
      // card edits with its colors intact.
      tv.textStorage?.setAttributedString(
        InkText.attributedDocument(fromPlainText: text, font: context.coordinator.baseFont,
                                   paragraph: context.coordinator.paragraphStyle(),
                                   ink: initialInk))
    }
    // Style what's already there (markdown, ink) so a focused card shows it immediately, not
    // only after the first keystroke.
    if (tv.textStorage?.length ?? 0) > 0 { context.coordinator.applyCurrentFormatting() }
    context.coordinator.installPlaceholder(in: tv, text: placeholder)
    context.coordinator.updatePlaceholderVisibility()
    context.coordinator.reportHeight(force: true)
    return scrollView
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    guard let tv = scrollView.documentView as? NSTextView else { return }
    context.coordinator.parent = self
    // Compare against the serialized form so display styling (visible ≠ serialized) isn't
    // mistaken for an external edit — only a real change to the bound text re-seeds the editor.
    if tv.attributedString().composerPlainText != text {
      let sel = tv.selectedRange()
      tv.textStorage?.setAttributedString(
        InkText.attributedDocument(fromPlainText: text, font: context.coordinator.baseFont,
                                   paragraph: context.coordinator.paragraphStyle(),
                                   ink: initialInk))
      let length = (tv.string as NSString).length
      tv.setSelectedRange(NSRange(location: min(sel.location, length), length: 0))
    }
    context.coordinator.updatePlaceholderVisibility()
    // Width may have changed (card resized) → reflow can change line count → refit height.
    context.coordinator.reportHeight()
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
    private var fontSizeObserver: NSObjectProtocol?
    private var isNormalizingFormatting = false
    /// Last height pushed up to the card, so repeated layout passes don't thrash the binding.
    private var lastReportedHeight: CGFloat = -1
    private var lastReportedNaturalWidth: CGFloat = -1
    /// Width the last height was measured at — lets `updateNSView` skip the (non-trivial) text
    /// layout pass on renders that only moved the card (pan/drag), measuring only on a reflow.
    private var lastLayoutWidth: CGFloat = -1

    init(_ parent: FreeWriteEditor) {
      self.parent = parent
      super.init()
      fontSizeObserver = NotificationCenter.default.addObserver(
        forName: .composerFontSizeChanged, object: nil, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.applyCurrentFormatting() }
      }
    }

    deinit {
      if let fontSizeObserver { NotificationCenter.default.removeObserver(fontSizeObserver) }
    }

    // MARK: Typography

    /// The editor's body font with the card's per-card scale (issue #77) folded in. `Theme.Typography
    /// .body` is the global-slider editor font; scaling its point size here keeps a scaled card's live
    /// edit matched to its static render, and composes multiplicatively with the slider.
    var baseFont: NSFont {
      let scale = max(parent.fontScale, 0.01)
      guard abs(scale - 1) > 0.0001 else { return Theme.Typography.body }
      return ComposerPreferences.appFont(ofSize: Theme.Typography.body.pointSize * scale)
    }
    /// Line spacing scaled the same way, so wrapped lines sit apart proportionally to the font.
    var baseLineSpacing: CGFloat { Theme.Typography.bodyLineSpacing * max(parent.fontScale, 0.01) }

    func paragraphStyle() -> NSMutableParagraphStyle {
      let style = NSMutableParagraphStyle()
      style.lineSpacing = baseLineSpacing
      return style
    }
    func bodyAttributes() -> [NSAttributedString.Key: Any] {
      [.font: baseFont,
       .foregroundColor: Theme.nsBodyText,
       .paragraphStyle: paragraphStyle()]
    }

    func textView(_ textView: NSTextView,
                  shouldChangeTypingAttributes oldTypingAttributes: [String: Any],
                  toAttributes newTypingAttributes: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
      bodyAttributes()
    }

    /// Re-apply the current editor font/color to plain text while preserving images.
    /// This strips pasted rich-text colors (the black-on-dark bug) and handles ⌘+/⌘− live.
    func applyCurrentFormatting() {
      guard let tv = textView else { return }
      tv.font = baseFont
      tv.textColor = Theme.nsBodyText
      tv.defaultParagraphStyle = paragraphStyle()
      tv.typingAttributes = bodyAttributes()
      placeholderView.font = baseFont
      placeholderView.textColor = Theme.nsPlaceholderText
      normalizeBodyRuns(in: tv)
      tv.needsDisplay = true
      reportHeight(force: true)
    }

    private func normalizeBodyRuns(in tv: NSTextView) {
      guard !isNormalizingFormatting, let storage = tv.textStorage, storage.length > 0 else {
        tv.typingAttributes = bodyAttributes()
        return
      }

      let full = NSRange(location: 0, length: storage.length)
      let attrs = bodyAttributes()
      var bodyRanges: [NSRange] = []
      // Per-range ink slots survive the body reset: `setAttributes` replaces every attribute (so
      // `.inkSlot` is wiped), so snapshot the inked spans here and re-apply them last — ink wins
      // over markdown's body/marker colors on the colored characters, keeping the range colored
      // as the user keeps typing.
      var inkedSpans: [(range: NSRange, slot: Int)] = []
      storage.enumerateAttributes(in: full, options: []) { attributes, range, _ in
        guard attributes[.attachment] == nil else { return }
        if let slot = attributes[.inkSlot] as? Int { inkedSpans.append((range, slot)) }
        bodyRanges.append(range)
      }
      guard !bodyRanges.isEmpty else { return }

      isNormalizingFormatting = true
      storage.beginEditing()
      for range in bodyRanges { storage.setAttributes(attrs, range: range) }
      MarkdownStyle.apply(to: storage, baseFont: baseFont)
      for (range, slot) in inkedSpans {
        storage.addAttribute(.inkSlot, value: slot, range: range)
        if let color = Theme.tintColor(slot) { storage.addAttribute(.foregroundColor, value: color, range: range) }
      }
      storage.endEditing()
      isNormalizingFormatting = false
      tv.typingAttributes = attrs
    }

    // MARK: Text change → binding + count
    func textDidChange(_ notification: Notification) {
      guard let tv = textView else { return }
      // IME composition (Japanese/Chinese/Korean, and dead-key accents): while marked/provisional
      // text is on screen, NSTextView posts textDidChange on every keystroke. Reformatting the
      // text storage (normalizeBodyRuns) over that provisional text corrupts the input session — it strips the IME's marked-text styling and can steal the
      // Return that confirms a candidate — and serializing it would persist text the user may still
      // cancel. Do only the cheap on-screen updates and defer the rest to the commit, which posts
      // one final textDidChange with no marked text.
      if tv.hasMarkedText() {
        parent.onCountChange(tv.string.count)
        updatePlaceholderVisibility()
        reportHeight(force: true)
        return
      }
      normalizeBodyRuns(in: tv)
      let serialized = tv.attributedString().composerPlainText
      if parent.text != serialized { parent.text = serialized }
      parent.onCountChange(tv.string.count)
      updatePlaceholderVisibility()
      publishSelection(tv)
      reportHeight(force: true)
    }

    // MARK: Auto-height (point text grows to fit content)

    /// Push the laid-out content height up to the card. Async + epsilon-guarded so it's safe to
    /// call from `updateNSView` (no "modifying state during view update") and can't loop: the
    /// card resizes height only, content height is stable for a fixed width, so it converges.
    ///
    /// `force` runs the measurement now (text/font changed). Otherwise it's skipped unless the
    /// width changed — so panning or dragging the card, which re-renders the editor but doesn't
    /// reflow it, never pays for a text layout pass.
    func reportHeight(force: Bool = false) {
      guard let tv = textView else { return }
      let width = tv.bounds.width
      if !force, abs(width - lastLayoutWidth) < 0.5 { return }
      lastLayoutWidth = width
      let height = contentHeight(of: tv)
      let natural = naturalContentWidth(of: tv)
      guard height > 0,
            abs(height - lastReportedHeight) > 0.5 || abs(natural - lastReportedNaturalWidth) > 0.5
      else { return }
      lastReportedHeight = height
      lastReportedNaturalWidth = natural
      let callback = parent.onLayoutChange
      DispatchQueue.main.async { callback(natural, height) }
    }

    /// The width this editor would take with NO wrapping (its widest hard line), plus its own
    /// horizontal chrome (container inset + fragment padding). Measured on the live storage so
    /// attachments and per-card font scale count exactly as rendered — this is what makes the card's
    /// hugged width agree with where the view actually wraps.
    private func naturalContentWidth(of tv: NSTextView) -> CGFloat {
      guard let storage = tv.textStorage, storage.length > 0 else { return 0 }
      let unwrapped = storage.boundingRect(
        with: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
        options: [.usesLineFragmentOrigin, .usesFontLeading]).width
      let fragmentPadding = tv.textContainer?.lineFragmentPadding ?? 5
      return ceil(unwrapped) + tv.textContainerInset.width * 2 + fragmentPadding * 2
    }

    private func contentHeight(of tv: NSTextView) -> CGFloat {
      guard let lm = tv.layoutManager, let container = tv.textContainer else { return 0 }
      lm.ensureLayout(for: container)
      return lm.usedRect(for: container).height + tv.textContainerInset.height * 2
    }

    // MARK: Selection change → debounced snapshot (anti-flicker on drag)
    func textViewDidChangeSelection(_ notification: Notification) {
      guard let tv = textView else { return }
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

    // MARK: Keyboard — Escape always handled; Return continues markdown lists
    func textView(_ tv: NSTextView, doCommandBy selector: Selector) -> Bool {
      if selector == #selector(NSResponder.cancelOperation(_:)) {
        if parent.store.isSettingsOpen { parent.store.isSettingsOpen = false }
        else { parent.onEscape() }
        return true
      }
      if selector == #selector(NSResponder.insertNewline(_:)), handleMarkdownNewline(tv) {
        return true
      }
      return false
    }

    // MARK: Markdown formatting actions (selection bar)

    /// Wrap/unwrap the selection or toggle line prefixes with literal markdown syntax. Every
    /// mutation routes through shouldChangeText/didChangeText, so undo and restyling just work.
    func applyMarkdown(_ action: MarkdownStyle.Action) {
      guard let tv = textView else { return }
      switch action {
      case .bold: toggleWrap(tv, marker: "**")
      case .italic: toggleWrap(tv, marker: "*")
      case .code: toggleWrap(tv, marker: "`")
      case .quote: toggleLinePrefix(tv, prefix: "> ")
      case .heading: cycleHeading(tv)
      }
      tv.window?.makeFirstResponder(tv)
    }

    /// Ink the current selection with a theme tint slot: set (or clear, when `slot` is nil) the
    /// `.inkSlot` attribute and its resolved `.foregroundColor` across the selection. Serialized
    /// text is untouched — only display attributes change — so `composerPlainTextAndInk` re-derives the runs from the storage.
    /// Returns false with no selection so the caller can fall back to whole-card tinting.
    @discardableResult
    func applyInk(_ slot: Int?) -> Bool {
      guard let tv = textView, let storage = tv.textStorage else { return false }
      let range = tv.selectedRange()
      guard range.length > 0 else { return false }
      // Clearing falls back to the card's tint color (if any) so cleared text matches its
      // untinted siblings, else the flavor's body ink.
      let clearedColor = Theme.tintColor(parent.cardTint?()) ?? Theme.nsBodyText
      let color = slot.flatMap { Theme.tintColor($0) } ?? clearedColor
      storage.beginEditing()
      if let slot {
        storage.addAttribute(.inkSlot, value: slot, range: range)
      } else {
        storage.removeAttribute(.inkSlot, range: range)
      }
      storage.addAttribute(.foregroundColor, value: color, range: range)
      storage.endEditing()
      tv.didChangeText()
      return true
    }

    private func toggleWrap(_ tv: NSTextView, marker: String) {
      guard let storage = tv.textStorage else { return }
      let ns = storage.string as NSString
      let sel = tv.selectedRange()
      let markerLength = (marker as NSString).length

      // Already wrapped (markers just outside the selection)? Unwrap.
      if sel.location >= markerLength,
         sel.location + sel.length + markerLength <= ns.length,
         ns.substring(with: NSRange(location: sel.location - markerLength, length: markerLength)) == marker,
         ns.substring(with: NSRange(location: sel.location + sel.length, length: markerLength)) == marker {
        let outer = NSRange(location: sel.location - markerLength, length: sel.length + markerLength * 2)
        let inner = ns.substring(with: sel)
        guard tv.shouldChangeText(in: outer, replacementString: inner) else { return }
        storage.replaceCharacters(in: outer, with: NSAttributedString(string: inner, attributes: bodyAttributes()))
        tv.didChangeText()
        tv.setSelectedRange(NSRange(location: outer.location, length: sel.length))
        return
      }

      let wrapped = marker + ns.substring(with: sel) + marker
      guard tv.shouldChangeText(in: sel, replacementString: wrapped) else { return }
      storage.replaceCharacters(in: sel, with: NSAttributedString(string: wrapped, attributes: bodyAttributes()))
      tv.didChangeText()
      tv.setSelectedRange(NSRange(location: sel.location + markerLength, length: sel.length))
    }

    private func toggleLinePrefix(_ tv: NSTextView, prefix: String) {
      guard let storage = tv.textStorage else { return }
      let ns = storage.string as NSString
      let lines = ns.lineRange(for: tv.selectedRange())
      let block = ns.substring(with: lines)
      let hasNewline = block.hasSuffix("\n")
      var rows = block.components(separatedBy: "\n")
      if hasNewline { rows.removeLast() }
      guard !rows.isEmpty else { return }
      let allPrefixed = rows.allSatisfy { $0.hasPrefix(prefix) || $0.trimmingCharacters(in: .whitespaces).isEmpty }
      let toggled = rows.map { row -> String in
        if allPrefixed { return row.hasPrefix(prefix) ? String(row.dropFirst(prefix.count)) : row }
        return row.trimmingCharacters(in: .whitespaces).isEmpty ? row : prefix + row
      }.joined(separator: "\n") + (hasNewline ? "\n" : "")
      guard tv.shouldChangeText(in: lines, replacementString: toggled) else { return }
      storage.replaceCharacters(in: lines, with: NSAttributedString(string: toggled, attributes: bodyAttributes()))
      tv.didChangeText()
      tv.setSelectedRange(NSRange(location: lines.location, length: (toggled as NSString).length))
    }

    private func cycleHeading(_ tv: NSTextView) {
      guard let storage = tv.textStorage else { return }
      let ns = storage.string as NSString
      let line = ns.lineRange(for: NSRange(location: tv.selectedRange().location, length: 0))
      let text = ns.substring(with: line)
      let current: Int = {
        if text.hasPrefix("### ") { return 3 }
        if text.hasPrefix("## ") { return 2 }
        if text.hasPrefix("# ") { return 1 }
        return 0
      }()
      let stripped = current > 0 ? String(text.dropFirst(current + 1)) : text
      let next = (current + 1) % 4
      let replacement = (next > 0 ? String(repeating: "#", count: next) + " " : "") + stripped
      guard tv.shouldChangeText(in: line, replacementString: replacement) else { return }
      storage.replaceCharacters(in: line, with: NSAttributedString(string: replacement, attributes: bodyAttributes()))
      tv.didChangeText()
      let caret = min(line.location + (replacement as NSString).length, storage.length)
      tv.setSelectedRange(NSRange(location: caret, length: 0))
    }

    /// Lists write themselves: Enter at the end of a list/checkbox line starts the next item
    /// (numbers increment, checkboxes reset); Enter on an EMPTY item removes the marker and
    /// exits the list — the universal editor convention.
    private func handleMarkdownNewline(_ tv: NSTextView) -> Bool {
      guard let storage = tv.textStorage else { return false }
      let sel = tv.selectedRange()
      guard sel.length == 0 else { return false }
      let ns = storage.string as NSString
      let caret = min(sel.location, ns.length)
      let lineRange = ns.lineRange(for: NSRange(location: caret, length: 0))
      let line = ns.substring(with: lineRange).trimmingCharacters(in: .newlines)
      guard let continuation = MarkdownStyle.listContinuation(of: line) else { return false }
      // Only continue when the caret sits at/after the prefix — Enter inside the marker itself
      // should just break the line.
      guard caret >= lineRange.location + continuation.prefixLength else { return false }

      let content = (line as NSString).substring(from: continuation.prefixLength)
      if content.trimmingCharacters(in: .whitespaces).isEmpty {
        // Empty item: strip the marker, leaving a plain empty line (exit the list).
        let prefixRange = NSRange(location: lineRange.location, length: continuation.prefixLength)
        guard tv.shouldChangeText(in: prefixRange, replacementString: "") else { return true }
        storage.replaceCharacters(in: prefixRange, with: "")
        tv.didChangeText()
        return true
      }

      let insertion = "\n" + continuation.next
      guard tv.shouldChangeText(in: sel, replacementString: insertion) else { return true }
      storage.replaceCharacters(in: sel, with: NSAttributedString(string: insertion, attributes: bodyAttributes()))
      tv.didChangeText()
      tv.setSelectedRange(NSRange(location: sel.location + (insertion as NSString).length, length: 0))
      return true
    }

    // MARK: Placeholder (NSTextView has none of its own)
    func installPlaceholder(in tv: NSTextView, text: String) {
      placeholderView.stringValue = text
      placeholderView.font = baseFont
      placeholderView.textColor = Theme.nsPlaceholderText
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