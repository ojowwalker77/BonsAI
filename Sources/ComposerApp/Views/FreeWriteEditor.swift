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

  /// Drop first responder so the card leaves text-edit mode (back to selected/movable).
  func resignFocus() {
    guard let tv = coordinator?.textView, tv.window?.firstResponder == tv else { return }
    tv.window?.makeFirstResponder(nil)
  }

  func replace(range: NSRange, with string: String) {
    coordinator?.replace(range: range, with: string)
  }

  /// Apply a linter quick-fix, but only if the span still reads exactly as flagged
  /// (guards against the text having shifted under us).
  func applyLintFix(range: NSRange, expecting phrase: String, with replacement: String) {
    coordinator?.applyLintFix(range: range, expecting: phrase, with: replacement)
  }

  /// Apply a markdown formatting action (selection bar) to the current selection/line.
  func applyMarkdown(_ action: MarkdownStyle.Action) {
    coordinator?.applyMarkdown(action)
  }

  /// Self-contained plain text with mention tokens serialized back to "@name".
  var plainText: String {
    plainTextIfLoaded ?? ""
  }

  var plainTextIfLoaded: String? {
    guard let tv = coordinator?.textView else { return nil }
    return tv.attributedString().composerPlainText
  }

  /// A lossless copy of the whole document (chips + attachments) for revert.
  var attributedSnapshot: NSAttributedString? {
    guard let storage = coordinator?.textView?.textStorage else { return nil }
    return storage.attributedSubstring(from: NSRange(location: 0, length: storage.length))
  }

  /// Replace the entire draft with refined plain text (whole-draft refine).
  func replaceWholeDraft(with string: String) {
    coordinator?.replaceWholeDraft(with: string)
  }

  /// Restore a previously captured snapshot — used to revert a refine.
  func restore(_ snapshot: NSAttributedString) {
    coordinator?.restore(snapshot)
  }
}

// MARK: - Representable

/// A chromeless free-write editor: a transparent `NSTextView` over the panel vibrancy.
struct FreeWriteEditor: NSViewRepresentable {
  @Binding var text: String
  var initialAttributedText: NSAttributedString?
  var placeholder = "Start writing\u{2026}"
  var onCountChange: (Int) -> Void = { _ in }
  var onSelectionChange: (EditorSelection) -> Void = { _ in }
  var onEscape: () -> Void = {}
  /// Fired when this editor gains/loses first responder (canvas active-card tracking).
  var onFocusChange: (Bool) -> Void = { _ in }
  /// Reports the editor's intrinsic content height (laid-out text + container inset) so a text
  /// card can auto-grow to fit what's typed — Excalidraw point text, not a fixed box.
  var onHeightChange: (CGFloat) -> Void = { _ in }
  /// Supplies the rest of the board's text as read-only context for the linter. `nil` ⇒
  /// behaves exactly as the single-editor era.
  var boardContext: () -> String? = { nil }
  /// Board-scoped copy-time variable names, so a `$name` reference highlights even when its
  /// `name = …` definition lives in another card.
  var definedVariables: () -> Set<String> = { [] }
  @ObservedObject var mentions: MentionState
  @ObservedObject var appSearch: AppSearchState
  @ObservedObject var controller: EditorController
  @ObservedObject var lint: LintState
  @ObservedObject var refine: RefineState
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
    tv.isRichText = true            // keep: styled chips + image attachments persist in-session
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
    tv.font = Theme.Typography.body
    tv.defaultParagraphStyle = context.coordinator.paragraphStyle()
    tv.typingAttributes = context.coordinator.bodyAttributes()
    tv.textColor = Theme.nsBodyText
    tv.delegate = context.coordinator
    scrollView.documentView = tv

    context.coordinator.textView = tv
    controller.coordinator = context.coordinator
    tv.onChipClick = { [weak coordinator = context.coordinator] range in
      coordinator?.handleChipClick(range)
    }
    tv.onHoverPoint = { [weak coordinator = context.coordinator] point in
      coordinator?.handleHover(point)
    }
    tv.onFocusChange = { [weak coordinator = context.coordinator] active in
      coordinator?.parent.onFocusChange(active)
    }
    tv.smartPasteHandler = context.coordinator

    if let initialAttributedText {
      tv.textStorage?.setAttributedString(initialAttributedText)
    } else if !text.isEmpty {
      // `text` is the serialized form (e.g. "@github") — rebuild it into styled chips so a
      // reloaded card edits with real chips, not raw tokens.
      tv.textStorage?.setAttributedString(
        ChipFactory.attributedDocument(fromPlainText: text, font: Theme.Typography.body,
                                       paragraph: context.coordinator.paragraphStyle()))
    }
    // Style what's already there (shell-token highlight, chip restyle) so a focused card shows
    // its tokens immediately, not only after the first keystroke.
    if (tv.textStorage?.length ?? 0) > 0 { context.coordinator.applyCurrentFormatting() }
    context.coordinator.installPlaceholder(in: tv, text: placeholder)
    context.coordinator.updatePlaceholderVisibility()
    context.coordinator.reportHeight(force: true)
    // Chip restyle on async favicon arrival is wired per-coordinator via the
    // .composerStyleCacheUpdated notification (see Coordinator.init) so N cards all update,
    // instead of a single shared closure the last card would clobber.
    return scrollView
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    guard let tv = scrollView.documentView as? NSTextView else { return }
    context.coordinator.parent = self
    // Compare against the serialized form so chip styling (visible ≠ serialized) isn't mistaken
    // for an external edit — only a real change to the bound text re-seeds the editor.
    if tv.attributedString().composerPlainText != text {
      let sel = tv.selectedRange()
      tv.textStorage?.setAttributedString(
        ChipFactory.attributedDocument(fromPlainText: text, font: Theme.Typography.body,
                                       paragraph: context.coordinator.paragraphStyle()))
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
  final class Coordinator: NSObject, NSTextViewDelegate, ComposerSmartPasteHandling {
    var parent: FreeWriteEditor
    weak var textView: NSTextView?
    private let placeholderView = NSTextField(labelWithString: "")
    private var selectionWork: DispatchWorkItem?
    private var lintWork: DispatchWorkItem?
    private var hideWork: DispatchWorkItem?
    private var fontSizeObserver: NSObjectProtocol?
    private var styleObserver: NSObjectProtocol?
    private var isNormalizingFormatting = false
    /// Monotonic guard so a slow analysis can't apply onto newer text.
    private var lintVersion = 0
    /// Last height pushed up to the card, so repeated layout passes don't thrash the binding.
    private var lastReportedHeight: CGFloat = -1
    /// Width the last height was measured at — lets `updateNSView` skip the (non-trivial) text
    /// layout pass on renders that only moved the card (pan/drag), measuring only on a reflow.
    private var lastLayoutWidth: CGFloat = -1

    init(_ parent: FreeWriteEditor) {
      self.parent = parent
      super.init()
      parent.mentions.commitRequested = { [weak self] item in self?.commit(item) }
      parent.lint.cancelHide = { [weak self] in self?.hideWork?.cancel() }
      parent.lint.requestHide = { [weak self] in self?.scheduleHide() }
      fontSizeObserver = NotificationCenter.default.addObserver(
        forName: .composerFontSizeChanged, object: nil, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.applyCurrentFormatting() }
      }
      // Restyle this card's chips when an async favicon/brand color lands. Per-coordinator
      // (not a single shared closure) so every card on the board updates, not just the last.
      styleObserver = NotificationCenter.default.addObserver(
        forName: .composerStyleCacheUpdated, object: nil, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.updateExistingChips() }
      }
      // Warm the on-device model so the first pause doesn't pay cold-start latency.
      SemanticLintService.shared.prewarm()
    }

    deinit {
      if let fontSizeObserver { NotificationCenter.default.removeObserver(fontSizeObserver) }
      if let styleObserver { NotificationCenter.default.removeObserver(styleObserver) }
    }

    // MARK: Typography
    func paragraphStyle() -> NSMutableParagraphStyle {
      let style = NSMutableParagraphStyle()
      style.lineSpacing = Theme.Typography.bodyLineSpacing
      return style
    }
    func bodyAttributes() -> [NSAttributedString.Key: Any] {
      [.font: Theme.Typography.body,
       .foregroundColor: Theme.nsBodyText,
       .paragraphStyle: paragraphStyle()]
    }

    func textView(_ textView: NSTextView,
                  shouldChangeTypingAttributes oldTypingAttributes: [String: Any],
                  toAttributes newTypingAttributes: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
      bodyAttributes()
    }

    /// Re-apply the current editor font/color to plain text while preserving chips and images.
    /// This strips pasted rich-text colors (the black-on-dark bug) and handles ⌘+/⌘− live.
    func applyCurrentFormatting() {
      guard let tv = textView else { return }
      tv.font = Theme.Typography.body
      tv.textColor = Theme.nsBodyText
      tv.defaultParagraphStyle = paragraphStyle()
      tv.typingAttributes = bodyAttributes()
      placeholderView.font = Theme.Typography.body
      placeholderView.textColor = Theme.nsPlaceholderText
      normalizeBodyRuns(in: tv)
      restyleExistingChips(notifyTextView: false)
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
      storage.enumerateAttributes(in: full, options: []) { attributes, range, _ in
        guard attributes[.mentionToken] == nil, attributes[.attachment] == nil else { return }
        bodyRanges.append(range)
      }
      guard !bodyRanges.isEmpty else { return }

      isNormalizingFormatting = true
      storage.beginEditing()
      for range in bodyRanges { storage.setAttributes(attrs, range: range) }
      MarkdownStyle.apply(to: storage, baseFont: Theme.Typography.body)
      highlightShellTokens(in: storage)
      storage.endEditing()
      isNormalizingFormatting = false
      tv.typingAttributes = attrs
    }

    /// Syntax-highlight the copy-time shell tokens (`{{x = cmd}}`, `{{x}}`, `[sh: cmd]`) so they
    /// read as live code while you type, matched to the rendered card. Display-only: it changes
    /// font/color/background on existing characters, never the text, so `composerPlainText` still
    /// round-trips the literal source. Runs after the body reset (so it wins) and inside the
    /// caller's begin/endEditing batch.
    private func highlightShellTokens(in storage: NSTextStorage) {
      let size = Theme.Typography.body.pointSize
      // Board-scoped names ∪ this card's own definitions (so a just-typed `name =` references live).
      let names = parent.definedVariables().union(ShellTemplate.definedNames(in: storage.string))
      for expression in ShellTemplate.expressions(in: storage.string, definedNames: names) {
        let range = expression.range
        guard range.location + range.length <= storage.length else { continue }
        storage.addAttributes([
          .font: ShellTokenStyle.font(for: expression.kind, size: size),
          .foregroundColor: ShellTokenStyle.tint(for: expression.kind),
        ], range: range)
      }
    }

    // MARK: Text change → binding + count + mention scan
    func textDidChange(_ notification: Notification) {
      guard let tv = textView else { return }
      normalizeBodyRuns(in: tv)
      let serialized = tv.attributedString().composerPlainText
      if parent.text != serialized { parent.text = serialized }
      parent.onCountChange(tv.string.count)
      updatePlaceholderVisibility()
      refreshMentionMenu(tv)
      publishSelection(tv)
      // Editing invalidates any existing flags; clear now, re-lint once you pause.
      resetLint()
      scheduleLint(tv)
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
      guard height > 0, abs(height - lastReportedHeight) > 0.5 else { return }
      lastReportedHeight = height
      let callback = parent.onHeightChange
      DispatchQueue.main.async { callback(height) }
    }

    private func contentHeight(of tv: NSTextView) -> CGFloat {
      guard let lm = tv.layoutManager, let container = tv.textContainer else { return 0 }
      lm.ensureLayout(for: container)
      return lm.usedRect(for: container).height + tv.textContainerInset.height * 2
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
      parent.text = tv.attributedString().composerPlainText
      parent.onCountChange(tv.string.count)
      updatePlaceholderVisibility()
      publishSelection(tv)
      return true
    }

    // MARK: - Whole-draft refine

    /// Replace the entire document with refined plain text, keeping it undo-safe.
    func replaceWholeDraft(with string: String) {
      guard let tv = textView else { return }
      let whole = NSRange(location: 0, length: (tv.string as NSString).length)
      _ = replace(range: whole, with: string)
      tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
    }

    /// Restore a snapshot verbatim (chips + attachments intact) to revert a refine.
    func restore(_ snapshot: NSAttributedString) {
      guard let tv = textView, let storage = tv.textStorage else { return }
      let whole = NSRange(location: 0, length: storage.length)
      guard tv.shouldChangeText(in: whole, replacementString: snapshot.string) else { return }
      storage.replaceCharacters(in: whole, with: snapshot)
      tv.didChangeText()
      tv.setSelectedRange(NSRange(location: 0, length: 0))
      tv.typingAttributes = bodyAttributes()
      parent.text = tv.attributedString().composerPlainText
      parent.onCountChange(tv.string.count)
      updatePlaceholderVisibility()
    }

    // MARK: - Semantic linter

    /// Debounced: only analyze once typing pauses, so the sentinel never fires mid-thought.
    private func scheduleLint(_ tv: NSTextView) {
      lintWork?.cancel()
      guard SemanticLintService.shared.isAvailable else { return }
      let work = DispatchWorkItem { [weak self, weak tv] in
        guard let self, let tv else { return }
        self.runLint(tv)
      }
      lintWork = work
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.1, execute: work)
    }

    private func runLint(_ tv: NSTextView) {
      let visibleSnapshot = tv.string
      let plainSnapshot = tv.attributedString().composerPlainText
      let boardContext = parent.boardContext()
      lintVersion &+= 1
      let version = lintVersion
      Task { [weak self] in
        let flags = await SemanticLintService.shared.analyze(
          visibleText: visibleSnapshot, plainText: plainSnapshot, boardContext: boardContext)
        guard let self, let tv = self.textView else { return }
        // Discard if the text changed or a newer pass started while we were thinking.
        guard version == self.lintVersion,
              tv.string == visibleSnapshot,
              tv.attributedString().composerPlainText == plainSnapshot else { return }
        self.applyLintFlags(flags)
      }
    }

    /// Paint the underlines as **temporary attributes** (display-only): they never enter
    /// the text storage, so they don't serialize, don't dirty undo, and reflow with the text.
    private func applyLintFlags(_ flags: [LintFlag]) {
      guard let tv = textView, let lm = tv.layoutManager else { return }
      clearLintDecorations()
      let length = (tv.string as NSString).length

      var resolved: [LintFlag] = []
      for var flag in flags {
        guard flag.range.location >= 0,
              flag.range.location + flag.range.length <= length,
              !intersectsMentionToken(flag.range, in: tv),
              !intersectsAttachment(flag.range, in: tv) else { continue }
        lm.addTemporaryAttributes(
          [.underlineStyle: NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDot.rawValue,
           .underlineColor: flag.kind.nsTint.withAlphaComponent(0.48),
           .backgroundColor: flag.kind.nsTint.withAlphaComponent(0.025)],
          forCharacterRange: flag.range)
        flag.rectInView = rectInPanel(for: flag.range)
        resolved.append(flag)
      }

      parent.lint.flags = resolved
      if let active = parent.lint.activeFlagID, !resolved.contains(where: { $0.id == active }) {
        parent.lint.activeFlagID = nil
      }
    }

    private func intersectsMentionToken(_ range: NSRange, in tv: NSTextView) -> Bool {
      guard let storage = tv.textStorage else { return false }
      var hit = false
      storage.enumerateAttribute(.mentionToken, in: range, options: []) { value, _, stop in
        if value != nil { hit = true; stop.pointee = true }
      }
      return hit
    }

    private func intersectsAttachment(_ range: NSRange, in tv: NSTextView) -> Bool {
      guard let storage = tv.textStorage else { return false }
      var hit = false
      storage.enumerateAttribute(.attachment, in: range, options: []) { value, _, stop in
        if value != nil { hit = true; stop.pointee = true }
      }
      return hit
    }

    /// Full reset on edit: drop decorations and any open popover until the next pause.
    private func resetLint() {
      clearLintDecorations()
      hideWork?.cancel()
      if !parent.lint.flags.isEmpty { parent.lint.flags = [] }
      if parent.lint.activeFlagID != nil { parent.lint.activeFlagID = nil }
    }

    private func clearLintDecorations() {
      guard let tv = textView, let lm = tv.layoutManager else { return }
      let full = NSRange(location: 0, length: (tv.string as NSString).length)
      for key in [NSAttributedString.Key.underlineStyle, .underlineColor, .backgroundColor] {
        lm.removeTemporaryAttribute(key, forCharacterRange: full)
      }
    }

    // MARK: Hover → popover (hit-test against the flagged rects)

    func handleHover(_ point: NSPoint?) {
      guard let point, !parent.lint.flags.isEmpty else { scheduleHide(); return }
      let hit = parent.lint.flags.first {
        guard let r = viewRect(for: $0.range) else { return false }
        return r.insetBy(dx: -5, dy: -7).contains(point)
      }
      guard let flag = hit else { scheduleHide(); return }
      hideWork?.cancel()
      if parent.lint.activeFlagID != flag.id { parent.lint.activeFlagID = flag.id }
    }

    /// Small grace period so the mouse can cross from the underline into the popover.
    private func scheduleHide() {
      hideWork?.cancel()
      let work = DispatchWorkItem { [weak self] in self?.parent.lint.activeFlagID = nil }
      hideWork = work
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.55, execute: work)
    }

    func applyLintFix(range: NSRange, expecting phrase: String, with replacement: String) {
      guard let tv = textView else { return }
      let ns = tv.string as NSString
      guard range.location + range.length <= ns.length,
            ns.substring(with: range) == phrase else { return }
      _ = replace(range: range, with: replacement)
      parent.lint.activeFlagID = nil
    }

    /// Flag rect in the text view's own coordinates (for hover hit-testing).
    private func viewRect(for range: NSRange) -> CGRect? {
      guard let tv = textView, let lm = tv.layoutManager, let c = tv.textContainer else { return nil }
      let glyphs = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
      let rect = lm.boundingRect(forGlyphRange: glyphs, in: c)
      let origin = tv.textContainerOrigin
      return rect.offsetBy(dx: origin.x, dy: origin.y)
    }

    /// Flag rect in panel SwiftUI space (for anchoring the popover).
    private func rectInPanel(for range: NSRange) -> CGRect? {
      guard let screen = screenRect(for: range) else { return nil }
      return panelRect(fromScreen: screen)
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

    // MARK: Smart paste

    func handleSmartPaste(_ pasted: String, in textView: ComposerTextView) -> Bool {
      if let token = SmartPaste.syncToken(for: pasted) {
        textView.insertTokenChip(token)
        parent.text = textView.attributedString().composerPlainText
        parent.onCountChange(textView.string.count)
        return true
      }
      guard SmartPaste.looksLikeLibraryQuery(pasted) else { return false }
      let range = textView.selectedRange()
      guard let insertedRange = insertPlainSmartPaste(pasted, replacing: range, in: textView) else {
        return false
      }
      Task { await resolveContext7Paste(pasted, insertedRange: insertedRange, in: textView) }
      return true
    }

    private func insertPlainSmartPaste(_ string: String, replacing range: NSRange, in textView: ComposerTextView) -> NSRange? {
      guard let storage = textView.textStorage,
            textView.shouldChangeText(in: range, replacementString: string) else { return nil }
      let attributed = NSAttributedString(string: string, attributes: bodyAttributes())
      storage.replaceCharacters(in: range, with: attributed)
      textView.didChangeText()
      let insertedRange = NSRange(location: range.location, length: (string as NSString).length)
      textView.setSelectedRange(NSRange(location: insertedRange.upperBound, length: 0))
      parent.text = textView.attributedString().composerPlainText
      parent.onCountChange(textView.string.count)
      updatePlaceholderVisibility()
      publishSelection(textView)
      return insertedRange
    }

    private func resolveContext7Paste(_ query: String, insertedRange: NSRange, in textView: ComposerTextView) async {
      if let token = await SmartPaste.context7Token(for: query) {
        let current = textView.string as NSString
        guard insertedRange.upperBound <= current.length,
              current.substring(with: insertedRange) == query else { return }
        textView.insertTokenChip(token, replacing: insertedRange)
        parent.text = textView.attributedString().composerPlainText
        parent.onCountChange(textView.string.count)
      }
    }

    // MARK: @-mention detection
    private func refreshMentionMenu(_ tv: NSTextView) {
      // A `$word` the user is typing autocompletes board variables — it takes priority over `@`.
      if let variable = activeVariableQuery(in: tv) {
        let items = variableMenuItems(matching: variable.text)
        if !items.isEmpty { openMenu(items: items, at: variable.range, in: tv); return }
      }
      guard let query = activeMentionQuery(in: tv) else { closeMenu(); return }
      let results = MentionCatalog.filtered(query.text)
      guard !results.isEmpty else { closeMenu(); return }
      openMenu(items: results, at: query.range, in: tv)
    }

    private func openMenu(items: [MentionItem], at range: NSRange, in tv: NSTextView) {
      let screen = tv.firstRect(forCharacterRange: range, actualRange: nil)
      if let frame = tv.window?.frame {
        parent.mentions.anchorInView = CGPoint(x: screen.minX - frame.minX,
                                               y: frame.maxY - screen.minY)
      }
      parent.mentions.items = items
      parent.mentions.selectedIndex = min(parent.mentions.selectedIndex, items.count - 1)
      parent.mentions.isOpen = true
    }

    /// Board variables matching `query`, as menu items. The `$`-prefixed id tells `commit` to
    /// insert plain `$name` text rather than an `@`-style chip. Empty when nothing matches (so a
    /// `$` typed on a board with no variables — e.g. heading into `$(cmd)` — never pops a menu).
    private func variableMenuItems(matching query: String) -> [MentionItem] {
      let names = parent.definedVariables().sorted()
      let matches = query.isEmpty ? names : names.filter { $0.lowercased().hasPrefix(query.lowercased()) }
      return matches.map {
        MentionItem(id: "$\($0)", title: $0.lowercased(), label: "$\($0)",
                    subtitle: "board variable", symbol: "dollarsign", kind: .skill)
      }
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
        if parent.store.compiledDraft != nil { parent.store.compiledDraft = nil }
        else if parent.store.isSettingsOpen { parent.store.isSettingsOpen = false }
        else if parent.mentions.isOpen { closeMenu() }
        else if parent.store.isHistoryOpen { parent.store.isHistoryOpen = false }
        else if parent.refine.isMenuOpen { parent.refine.isMenuOpen = false }
        else if parent.refine.pending != nil { parent.refine.revert?() }
        else { parent.onEscape() }
        return true
      }
      if selector == #selector(NSResponder.insertNewline(_:)), !parent.mentions.isOpen,
         handleMarkdownNewline(tv) {
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
      guard let tv = textView else { return }
      // Board-variable completion: insert plain `$name` (the highlighter tints it), not a chip.
      if item.id.hasPrefix("$"), let variable = activeVariableQuery(in: tv) {
        guard tv.shouldChangeText(in: variable.range, replacementString: item.id) else { return }
        tv.textStorage?.replaceCharacters(in: variable.range, with: NSAttributedString(string: item.id, attributes: bodyAttributes()))
        tv.setSelectedRange(NSRange(location: variable.range.location + (item.id as NSString).length, length: 0))
        tv.typingAttributes = bodyAttributes()
        tv.didChangeText()
        parent.text = tv.attributedString().composerPlainText
        parent.onCountChange(tv.string.count)
        closeMenu()
        return
      }
      guard let query = activeMentionQuery(in: tv) else { return }
      let chip = ChipFactory.make(token: item.id, font: Theme.Typography.body)
      let token = NSMutableAttributedString(attributedString: chip)
      token.append(NSAttributedString(string: " ", attributes: bodyAttributes()))
      guard tv.shouldChangeText(in: query.range, replacementString: token.string) else { return }
      tv.textStorage?.replaceCharacters(in: query.range, with: token)
      tv.didChangeText()
      tv.setSelectedRange(NSRange(location: query.range.location + token.length, length: 0))
      tv.typingAttributes = bodyAttributes()
      parent.text = tv.attributedString().composerPlainText
      parent.onCountChange(tv.string.count)
      closeMenu()

      // Apps don't just tag — open their inline search so the user picks a concrete thing.
      if item.kind == .app {
        let chipRange = NSRange(location: query.range.location, length: chip.length)
        openAppSearch(appID: item.id, targetRange: chipRange, kind: nil)
      }
    }

    /// Restyle already-inserted chips in place when async favicons land.
    func updateExistingChips() {
      restyleExistingChips(notifyTextView: true)
    }

    /// Rebuild chip runs with the current font/cache while preserving the selection.
    /// Edits are applied descending so stored ranges stay valid.
    private func restyleExistingChips(notifyTextView: Bool) {
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

      let full = NSRange(location: 0, length: storage.length)
      if notifyTextView, !tv.shouldChangeText(in: full, replacementString: tv.string) { return }

      let descending = edits.sorted { $0.0.location > $1.0.location }
      storage.beginEditing()
      for (range, rebuilt) in descending {
        storage.replaceCharacters(in: range, with: rebuilt)
      }
      storage.endEditing()
      if notifyTextView { tv.didChangeText() }

      func adjusted(_ point: Int) -> Int {
        var value = point
        for (range, rebuilt) in edits where range.location + range.length <= point {
          value += rebuilt.length - range.length
        }
        return min(max(value, 0), storage.length)
      }

      let newLocation = adjusted(saved.location)
      let newEnd = adjusted(saved.location + saved.length)
      tv.setSelectedRange(NSRange(location: newLocation, length: max(0, newEnd - newLocation)))
      tv.typingAttributes = bodyAttributes()
      parent.text = tv.attributedString().composerPlainText
      parent.onCountChange(tv.string.count)
    }

    // MARK: - Inline app search (connectors)

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
      state.hasSearched = false
      state.errorText = nil
      state.anchorInView = anchor
      state.onCommit = { [weak self] result in self?.resolveSelection(result) }
      state.onCancel = { [weak self] in self?.closeAppSearchAndFocus() }
      state.isOpen = true
      state.reload()
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
      parent.text = tv.attributedString().composerPlainText
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
      state.hasSearched = false
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

// MARK: - Backward $-query scan (variable autocomplete)

struct VariableQuery { let range: NSRange; let text: String }   // range covers "$query" incl. $

/// Scan backward from the caret for the `$identifier` being typed. nil unless the caret sits right
/// after `$` + word characters, with `$` not glued to a preceding letter/number/`$` (so `a$b` and
/// `$$` never trigger) and nothing but identifier chars between `$` and the caret (so `$(` stops).
func activeVariableQuery(in tv: NSTextView) -> VariableQuery? {
  let sel = tv.selectedRange()
  guard sel.length == 0, sel.location > 0 else { return nil }
  let ns = tv.string as NSString
  let caret = sel.location
  var i = caret - 1
  while i >= 0 {
    guard let scalar = UnicodeScalar(ns.character(at: i)) else { return nil }
    let ch = Character(scalar)
    if ch == "$" {
      if i > 0, let prevScalar = UnicodeScalar(ns.character(at: i - 1)) {
        let prev = Character(prevScalar)
        if prev.isLetter || prev.isNumber || prev == "$" { return nil }
      }
      return VariableQuery(
        range: NSRange(location: i, length: caret - i),
        text: ns.substring(with: NSRange(location: i + 1, length: caret - i - 1)))
    }
    if ch.isLetter || ch.isNumber || ch == "_" { i -= 1; continue }
    return nil   // a non-identifier, non-`$` char before the caret ⇒ not in a `$word`
  }
  return nil
}
