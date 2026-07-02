import AppKit

/// NSTextView that intercepts pasted/dropped images and renders them inline as
/// scaled `NSTextAttachment`s backed by a PNG we own. `importsGraphics` stays FALSE,
/// so this override is the only path that ever inserts an image.
final class ComposerTextView: NSTextView {

  /// Set by the editor coordinator; fired when an interactive app chip is clicked.
  var onChipClick: ((NSRange) -> Void)?
  /// Fired when this card's text view gains/loses first responder, so the canvas can
  /// track the active card and route per-card actions (font, selection refine) to it.
  var onFocusChange: ((Bool) -> Void)?
  /// When set, pasted plain text may be turned into connector chips before insertion.
  weak var smartPasteHandler: ComposerSmartPasteHandling?

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    if ComposerPreferences.handleEditorFontKeyEquivalent(event) { return true }
    return super.performKeyEquivalent(with: event)
  }

  override func becomeFirstResponder() -> Bool {
    let became = super.becomeFirstResponder()
    if became { onFocusChange?(true) }
    return became
  }

  override func resignFirstResponder() -> Bool {
    let resigned = super.resignFirstResponder()
    if resigned { onFocusChange?(false) }
    return resigned
  }

  /// Intercept clicks that land on an app chip and open its connector picker
  /// instead of placing a caret. Other clicks fall through to normal text behavior.
  override func mouseDown(with event: NSEvent) {
    if let range = appChipRange(at: event) {
      onChipClick?(range)
      return
    }
    if toggleCheckbox(at: event) { return }
    super.mouseDown(with: event)
  }

  /// A click on a markdown checkbox toggles `[ ]` ↔ `[x]` instead of placing the caret.
  private func toggleCheckbox(at event: NSEvent) -> Bool {
    guard let lm = layoutManager, let container = textContainer, let storage = textStorage,
          storage.length > 0 else { return false }
    let point = convert(event.locationInWindow, from: nil)
    let origin = textContainerOrigin
    let inContainer = NSPoint(x: point.x - origin.x, y: point.y - origin.y)
    var fraction: CGFloat = 0
    let glyphIndex = lm.glyphIndex(for: inContainer, in: container, fractionOfDistanceThroughGlyph: &fraction)
    let charIndex = lm.characterIndexForGlyph(at: glyphIndex)
    guard charIndex < storage.length else { return false }

    let ns = storage.string as NSString
    let lineRange = ns.lineRange(for: NSRange(location: charIndex, length: 0))
    let line = ns.substring(with: lineRange)
    guard let checkbox = MarkdownStyle.checkboxBox(in: line) else { return false }
    let boxRange = NSRange(location: lineRange.location + checkbox.box.location, length: checkbox.box.length)
    guard charIndex >= boxRange.location, charIndex < boxRange.location + boxRange.length else { return false }

    // Reject clicks past the line's glyphs (whitespace to the right of a short line).
    let glyphRange = lm.glyphRange(forCharacterRange: boxRange, actualCharacterRange: nil)
    let rect = lm.boundingRect(forGlyphRange: glyphRange, in: container).offsetBy(dx: origin.x, dy: origin.y)
    guard rect.insetBy(dx: -2, dy: -2).contains(point) else { return false }

    let replacement = checkbox.checked ? "[ ]" : "[x]"
    guard shouldChangeText(in: boxRange, replacementString: replacement) else { return true }
    storage.replaceCharacters(in: boxRange, with: replacement)
    didChangeText()
    return true
  }

  /// The full `.mentionToken` run under the click, but only for interactive app tokens
  /// and only when the point is actually inside the chip's glyphs (not past line end).
  private func appChipRange(at event: NSEvent) -> NSRange? {
    guard let lm = layoutManager, let container = textContainer, let storage = textStorage,
          storage.length > 0 else { return nil }
    let point = convert(event.locationInWindow, from: nil)
    let origin = textContainerOrigin
    let inContainer = NSPoint(x: point.x - origin.x, y: point.y - origin.y)

    var fraction: CGFloat = 0
    let glyphIndex = lm.glyphIndex(for: inContainer, in: container, fractionOfDistanceThroughGlyph: &fraction)
    let charIndex = lm.characterIndexForGlyph(at: glyphIndex)
    guard charIndex < storage.length else { return nil }

    var range = NSRange()
    guard let token = storage.attribute(.mentionToken, at: charIndex, longestEffectiveRange: &range,
                                        in: NSRange(location: 0, length: storage.length)) as? String,
          AppToken.parse(token) != nil else { return nil }

    // Reject clicks beyond the glyphs (e.g. trailing whitespace area on the line).
    let glyphRange = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
    let rect = lm.boundingRect(forGlyphRange: glyphRange, in: container).offsetBy(dx: origin.x, dy: origin.y)
    guard rect.contains(point) else { return nil }
    return range
  }

  // MARK: Treat a mention chip as one atomic block when deleting.
  //
  // A chip ("@github", "@finder:…") is a single `.mentionToken` run, but visually one
  // unit — deleting it one character at a time is surprising. When the caret sits next to
  // a chip (no selection), one press removes the whole run instead of a single glyph.

  override func deleteBackward(_ sender: Any?) {
    if deleteChipRun(adjacentTo: selectedRange(), before: true) { return }
    super.deleteBackward(sender)
  }

  override func deleteForward(_ sender: Any?) {
    if deleteChipRun(adjacentTo: selectedRange(), before: false) { return }
    super.deleteForward(sender)
  }

  /// If `selection` is an empty caret touching a mention-token run on the given side,
  /// delete that entire run undo-safely and return true; otherwise return false.
  private func deleteChipRun(adjacentTo selection: NSRange, before: Bool) -> Bool {
    guard selection.length == 0, let storage = textStorage, storage.length > 0 else { return false }
    let probe = before ? selection.location - 1 : selection.location
    guard probe >= 0, probe < storage.length else { return false }

    var range = NSRange()
    guard storage.attribute(.mentionToken, at: probe, longestEffectiveRange: &range,
                            in: NSRange(location: 0, length: storage.length)) is String else { return false }
    guard shouldChangeText(in: range, replacementString: "") else { return false }
    storage.replaceCharacters(in: range, with: "")
    didChangeText()
    setSelectedRange(NSRange(location: range.location, length: 0))
    return true
  }

  /// Required for the PASTE path: the default importsGraphics=false readable list has
  /// no image/file-URL type, so Cmd-V can't prefer an image without prepending these.
  /// (Drag is already accepted via editable + rich-text; this does not affect drag.)
  override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
    var types = super.readablePasteboardTypes
    for type in [NSPasteboard.PasteboardType.png, .tiff, .fileURL] where !types.contains(type) {
      types.insert(type, at: 0)
    }
    return types
  }

  /// The single read path for BOTH Cmd-V paste and drag-drop. We inspect the
  /// pasteboard directly so an image is preferred over an alternative representation.
  override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
    if let image = firstImage(from: pboard) {
      insertImageAttachment(image)
      return true
    }
    if let string = pboard.string(forType: .string),
       let handler = smartPasteHandler,
       handler.handleSmartPaste(string, in: self) {
      return true
    }
    return super.readSelection(from: pboard, type: type)
  }

  /// Insert a serialized `@token` as a styled chip at the current selection (or replace `range`).
  func insertTokenChip(_ token: String, replacing range: NSRange? = nil) {
    let target = range ?? selectedRange()
    let chip = ChipFactory.make(token: token, font: font ?? Theme.Typography.body)
    let run = NSMutableAttributedString(attributedString: chip)
    run.append(NSAttributedString(string: " ", attributes: bodyAttributes()))
    guard shouldChangeText(in: target, replacementString: run.string) else { return }
    textStorage?.replaceCharacters(in: target, with: run)
    didChangeText()
    setSelectedRange(NSRange(location: target.location + run.length, length: 0))
    typingAttributes = bodyAttributes()
  }

  private func bodyAttributes() -> [NSAttributedString.Key: Any] {
    let style = NSMutableParagraphStyle()
    style.lineSpacing = Theme.Typography.bodyLineSpacing
    return [
      .font: font ?? Theme.Typography.body,
      .foregroundColor: Theme.nsBodyText,
      .paragraphStyle: style,
    ]
  }

  // MARK: Extract an image — raw data first, then an image file URL.

  private func firstImage(from pboard: NSPasteboard) -> NSImage? {
    if pboard.canReadObject(forClasses: [NSImage.self], options: nil),
       let images = pboard.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage],
       let first = images.first, first.size.width > 0 {
      return first
    }
    let options: [NSPasteboard.ReadingOptionKey: Any] = [
      .urlReadingFileURLsOnly: true,
      .urlReadingContentsConformToTypes: NSImage.imageTypes,
    ]
    if let urls = pboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL],
       let url = urls.first, let image = NSImage(contentsOf: url) {
      return image
    }
    return nil
  }

  // MARK: Build + insert the attachment, undo-safely.

  private func insertImageAttachment(_ image: NSImage) {
    guard let url = ComposerTextView.savePNG(image) else { return }
    let target = scaledSize(for: image, maxWidth: contentWidth())

    let attachment = NSTextAttachment()
    attachment.image = redraw(image, to: target)
    attachment.bounds = CGRect(origin: .zero, size: target)   // required, else full Retina size

    let run = NSMutableAttributedString(attributedString: NSAttributedString(attachment: attachment))
    run.addAttribute(.imageAttachmentPath, value: url.path, range: NSRange(location: 0, length: run.length))

    let range = selectedRange()
    guard shouldChangeText(in: range, replacementString: run.string) else { return }
    textStorage?.replaceCharacters(in: range, with: run)
    didChangeText()
    setSelectedRange(NSRange(location: range.location + run.length, length: 0))
    let style = NSMutableParagraphStyle()
    style.lineSpacing = Theme.Typography.bodyLineSpacing
    typingAttributes = [
      .font: font ?? Theme.Typography.body,
      .foregroundColor: Theme.nsBodyText,
      .paragraphStyle: style,
    ]
  }

  // MARK: Geometry

  private func contentWidth() -> CGFloat {
    guard let container = textContainer else { return 480 }
    let padding = container.lineFragmentPadding * 2
    let inset = textContainerInset.width * 2
    let raw = container.size.width - padding - inset
    let usable = raw.isFinite ? raw : 480
    return max(40, min(usable, 1200))
  }

  private func scaledSize(for image: NSImage, maxWidth: CGFloat) -> NSSize {
    let size = image.size
    guard size.width > 0, size.height > 0 else { return NSSize(width: maxWidth, height: maxWidth) }
    guard size.width > maxWidth else { return size }
    return NSSize(width: maxWidth, height: (maxWidth / size.width) * size.height)
  }

  private func redraw(_ image: NSImage, to size: NSSize) -> NSImage {
    let out = NSImage(size: size)
    out.lockFocus()
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(in: NSRect(origin: .zero, size: size),
               from: NSRect(origin: .zero, size: image.size),
               operation: .copy, fraction: 1)
    out.unlockFocus()
    return out
  }

  // MARK: Persist a PNG copy.

  static func savePNG(_ image: NSImage) -> URL? {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
      UserFacingError.report("Composer could not convert the pasted image into PNG data. The image was not added.")
      return nil
    }
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    let dir = base.appendingPathComponent("Composer/Attachments", isDirectory: true)
    let url = dir.appendingPathComponent("\(UUID().uuidString).png")
    do {
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      try png.write(to: url)
      return url
    } catch {
      UserFacingError.report(error, while: "Saving the pasted image")
      return nil
    }
  }

  // MARK: Hover reporting for the semantic linter
  //
  // Pure observation: we report the cursor's location so the coordinator can hit-test
  // it against flagged ranges. We never consume the event, so caret placement, drag
  // selection, and clicks are completely unaffected.

  /// Called on every move with the point in text-view coords, or nil on exit.
  var onHoverPoint: ((NSPoint?) -> Void)?
  private var hoverTracking: NSTrackingArea?

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let existing = hoverTracking { removeTrackingArea(existing) }
    let area = NSTrackingArea(
      rect: .zero,
      options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
      owner: self, userInfo: nil)
    addTrackingArea(area)
    hoverTracking = area
  }

  override func mouseMoved(with event: NSEvent) {
    super.mouseMoved(with: event)
    onHoverPoint?(convert(event.locationInWindow, from: nil))
  }

  override func mouseExited(with event: NSEvent) {
    super.mouseExited(with: event)
    onHoverPoint?(nil)
  }

  // MARK: Re-fit inline images when the panel resizes (bounds-only, cheap).

  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    reflowImageAttachments()
  }

  private func reflowImageAttachments() {
    guard let storage = textStorage else { return }
    let maxWidth = contentWidth()
    let full = NSRange(location: 0, length: storage.length)
    storage.enumerateAttribute(.attachment, in: full) { value, range, _ in
      guard let attachment = value as? NSTextAttachment, let image = attachment.image else { return }
      let size = attachment.bounds.size
      guard size.width > 0, size.height > 0 else { return }
      let aspect = size.height / size.width
      let width = min(maxWidth, max(size.width, image.size.width))
      let newBounds = CGRect(x: 0, y: 0, width: width, height: width * aspect)
      if newBounds != attachment.bounds {
        attachment.bounds = newBounds
        layoutManager?.invalidateLayout(forCharacterRange: range, actualCharacterRange: nil)
      }
    }
  }
}
