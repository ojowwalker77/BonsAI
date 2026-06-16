import AppKit

/// NSTextView that intercepts pasted/dropped images and renders them inline as
/// scaled `NSTextAttachment`s backed by a PNG we own. `importsGraphics` stays FALSE,
/// so this override is the only path that ever inserts an image.
final class ComposerTextView: NSTextView {

  /// Set by the editor coordinator; fired when an interactive app chip is clicked.
  var onChipClick: ((NSRange) -> Void)?

  /// Intercept clicks that land on an app chip (Context7/GitHub) and open its search
  /// instead of placing a caret. Other clicks fall through to normal text behavior.
  override func mouseDown(with event: NSEvent) {
    if let range = appChipRange(at: event) {
      onChipClick?(range)
      return
    }
    super.mouseDown(with: event)
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
    return super.readSelection(from: pboard, type: type)
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
    typingAttributes = [.font: font as Any, .foregroundColor: NSColor.labelColor]
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
          let png = rep.representation(using: .png, properties: [:]) else { return nil }
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    let dir = base.appendingPathComponent("Composer/Attachments", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("\(UUID().uuidString).png")
    do { try png.write(to: url); return url } catch { return nil }
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
