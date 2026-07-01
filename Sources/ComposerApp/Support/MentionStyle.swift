import AppKit

// MARK: - Domain mapping

enum MentionDomain {
  static let map: [String: String] = ["@github": "github.com", "@context7": "context7.com", "@linear": "linear.app", "@notion": "notion.so", "@sentry": "sentry.io", "@figma": "figma.com"]
  static func host(for id: String) -> String? { map[id] }
}

// MARK: - Dominant color extraction

/// Representative brand color of a favicon. Downsamples to 32×32 RGBA8 and averages
/// pixels weighted by alpha AND saturation, so a small vivid glyph beats large
/// white/transparent areas. Then normalizes in HSB for the forced-dark panel.
func dominantColor(of image: NSImage) -> NSColor {
  let side = 32
  guard let rep = NSBitmapImageRep(
          bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
          bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
          colorSpaceName: .deviceRGB, bytesPerRow: side * 4, bitsPerPixel: 32),
        let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return legibleNeutral() }

  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = ctx
  NSColor.clear.set()
  NSBezierPath(rect: NSRect(x: 0, y: 0, width: side, height: side)).fill()
  image.draw(in: NSRect(x: 0, y: 0, width: side, height: side),
             from: .zero, operation: .sourceOver, fraction: 1.0)
  NSGraphicsContext.restoreGraphicsState()

  guard let data = rep.bitmapData else { return legibleNeutral() }
  let bytesPerRow = rep.bytesPerRow
  var sumR = 0.0, sumG = 0.0, sumB = 0.0, weightTotal = 0.0
  var satSum = 0.0, satWeight = 0.0

  for y in 0..<side {
    let row = data.advanced(by: y * bytesPerRow)
    for x in 0..<side {
      let p = row.advanced(by: x * 4)
      let a = Double(p[3]) / 255.0
      if a < 0.10 { continue }
      // deviceRGB + hasAlpha bitmap data is premultiplied; un-premultiply before averaging.
      let r = (Double(p[0]) / 255.0) / a
      let g = (Double(p[1]) / 255.0) / a
      let b = (Double(p[2]) / 255.0) / a
      let maxc = max(r, g, b), minc = min(r, g, b)
      let sat = maxc <= 0 ? 0 : (maxc - minc) / maxc
      let w = a * (0.10 + sat)
      sumR += min(r, 1.0) * w; sumG += min(g, 1.0) * w; sumB += min(b, 1.0) * w
      weightTotal += w
      satSum += sat * a; satWeight += a
    }
  }
  guard weightTotal > 0 else { return legibleNeutral() }
  let avgSat = satWeight > 0 ? satSum / satWeight : 0
  if avgSat < 0.08 { return legibleNeutral() }   // essentially grayscale (e.g. the octocat)

  let raw = NSColor(srgbRed: CGFloat(sumR / weightTotal),
                    green: CGFloat(sumG / weightTotal),
                    blue: CGFloat(sumB / weightTotal), alpha: 1.0)
  return normalizeForCanvas(raw)
}

/// Grayscale brand marks (the Octocat, Notion's N) get the flavor's ink instead of a washed
/// average. A dynamic color so it re-resolves at draw time after a theme switch.
private func legibleNeutral() -> NSColor {
  NSColor(name: nil) { _ in Theme.flavor.text }
}

/// Clamp a brand color for legibility on the CURRENT canvas, preserving hue: raise too-dark
/// colors on the dark board, deepen too-bright ones on paper. A dynamic color, so chips stay
/// legible when the theme flips without re-extracting anything.
private func normalizeForCanvas(_ color: NSColor) -> NSColor {
  guard let rgb = color.usingColorSpace(.sRGB) else { return legibleNeutral() }
  var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
  rgb.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
  if s < 0.12 { return legibleNeutral() }
  let lum = 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent
  return NSColor(name: nil) { _ in
    if Theme.flavor.isDark {
      var db = b, ds = s
      if lum < 0.55 {
        db = min(1.0, max(b, 0.80))
        ds = min(s, 0.85)
      }
      return NSColor(hue: h, saturation: ds, brightness: db, alpha: 1.0)
    } else {
      var db = b, ds = s
      if lum > 0.60 {
        db = min(b, 0.58)
        ds = max(s, 0.55)
      }
      return NSColor(hue: h, saturation: ds, brightness: db, alpha: 1.0)
    }
  }
}

// MARK: - Style cache (favicon fetch + cache + preload)

@MainActor
final class MentionStyleCache {
  static let shared = MentionStyleCache()

  private(set) var images: [String: NSImage] = [:]
  private(set) var colors: [String: NSColor] = [:]
  /// Small, line-height-sized copies for inline use in SwiftUI `Text` (non-editing cards),
  /// built lazily and reused so panning/redrawing never re-rasterizes a 64px icon per frame.
  private var inlineImages: [String: NSImage] = [:]
  /// Fires on the main actor when a favicon/color lands; wire to updateExistingChips().
  var onUpdate: (() -> Void)?

  /// Notifies multiple observers (chips + Settings Apps list) without clobbering `onUpdate`.
  private func broadcast() {
    onUpdate?()
    NotificationCenter.default.post(name: .composerStyleCacheUpdated, object: nil)
  }

  private let dir: URL = {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    let directory = base.appendingPathComponent("Composer/Favicons", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }()

  func image(for id: String) -> NSImage? { images[id] }
  func color(for id: String) -> NSColor? { colors[id] }

  /// A `side`×`side` copy of the brand icon for inline `Text` use, cached per id *and size* — the
  /// board zooms, so the same chip is requested at several sizes; keying by id alone froze the icon
  /// at its first (1×) size while the surrounding text grew.
  func inlineImage(for id: String, side: CGFloat = 15) -> NSImage? {
    let key = "\(id)@\(Int(side.rounded()))"
    if let cached = inlineImages[key] { return cached }
    guard let base = images[id] else { return nil }
    let resized = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
      base.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
      return true
    }
    inlineImages[key] = resized
    return resized
  }

  func preload() {
    for item in MentionCatalog.all {
      if item.id == "@github" {
        // Use the official Octocat vector instead of a fetched favicon.
        let image = githubOctocatImage()
        images[item.id] = image
        colors[item.id] = dominantColor(of: image)   // white glyph → legible light neutral
      } else if item.id == "@figma" {
        // Official multi-color Figma mark instead of a fetched favicon.
        images[item.id] = figmaLogoImage()
        colors[item.id] = figmaColor(0xA259FF)        // brand purple for the chip tint
      } else if item.id == "@finder", let image = localAppIcon(bundleID: "com.apple.finder", fallbackPath: "/System/Library/CoreServices/Finder.app") {
        images[item.id] = image
        colors[item.id] = dominantColor(of: image)
      } else if item.id == "@browser", let image = localAppIcon(bundleID: "com.apple.Safari", fallbackPath: "/Applications/Safari.app") {
        images[item.id] = image
        colors[item.id] = dominantColor(of: image)
      } else if item.id == "@xcode", let image = localAppIcon(bundleID: "com.apple.dt.Xcode", fallbackPath: "/Applications/Xcode.app") {
        images[item.id] = image
        colors[item.id] = dominantColor(of: image)
      } else if let host = MentionDomain.host(for: item.id) {
        loadFavicon(id: item.id, host: host)
      } else {
        images[item.id] = symbolImage(item.symbol)
        colors[item.id] = NSColor(name: nil) { _ in Theme.flavor.info }
      }
    }
    broadcast()
  }

  private func localAppIcon(bundleID: String, fallbackPath: String) -> NSImage? {
    let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
      ?? (FileManager.default.fileExists(atPath: fallbackPath) ? URL(fileURLWithPath: fallbackPath) : nil)
    guard let url else { return nil }
    let image = NSWorkspace.shared.icon(forFile: url.path)
    image.size = NSSize(width: 64, height: 64)
    return image
  }

  private func loadFavicon(id: String, host: String) {
    let file = dir.appendingPathComponent("\(sanitized(id)).png")
    if let data = try? Data(contentsOf: file), let image = NSImage(data: data), image.size.width > 1 {
      ingest(id: id, image: image)
      return
    }
    let candidates = [
      URL(string: "https://www.google.com/s2/favicons?sz=64&domain=\(host)")!,
      URL(string: "https://\(host)/favicon.ico")!,
    ]
    Task { [weak self] in
      for url in candidates {
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
              let image = NSImage(data: data), image.size.width > 1 else { continue }
        try? data.write(to: file)
        await MainActor.run { self?.ingest(id: id, image: image) }
        return
      }
    }
  }

  private func ingest(id: String, image: NSImage) {
    images[id] = image
    colors[id] = dominantColor(of: image)
    inlineImages = inlineImages.filter { !$0.key.hasPrefix("\(id)@") }   // drop every stale sized copy
    broadcast()
  }

  private func sanitized(_ id: String) -> String { String(id.drop(while: { $0 == "@" })) }

  private func symbolImage(_ symbol: String) -> NSImage {
    let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
    let fallback = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)?
      .withSymbolConfiguration(config) ?? NSImage(size: NSSize(width: 14, height: 14))
    let base = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
      .withSymbolConfiguration(config) ?? fallback
    let tint = Theme.Palette.nsAccent
    return NSImage(size: base.size, flipped: false) { rect in
      base.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
      tint.set()
      rect.fill(using: .sourceAtop)
      return true
    }
  }
}

// MARK: - Unified chip factory

/// The single place chips are built — used by insert, async favicon restyle, and resolve.
/// `token` is the serialized `@id` (possibly carrying a resolved selection); the chip's
/// visible label is derived from it, and the whole run carries `.mentionToken: token`
/// so `composerPlainText` round-trips it.
enum ChipFactory {
  @MainActor
  static func make(token: String, font: NSFont) -> NSAttributedString {
    let parsed = AppToken.parse(token)
    let appID = parsed?.appID ?? token
    let item = MentionCatalog.all.first { $0.id == appID }
    let isApp = item?.kind == .app
    let label = isApp ? AppToken.label(appID: appID, selection: parsed?.selection) : (item?.label ?? token)

    let cache = MentionStyleCache.shared
    if let image = cache.image(for: appID), let color = cache.color(for: appID) {
      return MentionChip.attributed(token: token, label: label, font: font,
                                    image: image, color: color, showDisclosure: isApp)
    }
    return MentionToken.attributed(token: token, label: label, font: font, showDisclosure: isApp)
  }

  /// Inverse of `composerPlainText` for the editor: rebuild an attributed string from serialized
  /// plain text, re-styling each `@token` as a chip. This is what lets a reloaded card show real
  /// chips instead of raw "@github" text. Image placeholders stay literal (the bitmap isn't
  /// recoverable from the serialized text).
  @MainActor
  static func attributedDocument(fromPlainText plain: String, font: NSFont,
                                 paragraph: NSParagraphStyle) -> NSAttributedString {
    let body: [NSAttributedString.Key: Any] = [
      .font: font, .foregroundColor: Theme.nsBodyText, .paragraphStyle: paragraph]
    let result = NSMutableAttributedString()
    let ns = plain as NSString
    var cursor = 0
    for range in mentionTokenRanges(in: plain) {
      if range.location > cursor {
        result.append(NSAttributedString(
          string: ns.substring(with: NSRange(location: cursor, length: range.location - cursor)),
          attributes: body))
      }
      result.append(make(token: ns.substring(with: range), font: font))
      cursor = range.location + range.length
    }
    if cursor < ns.length {
      result.append(NSAttributedString(
        string: ns.substring(with: NSRange(location: cursor, length: ns.length - cursor)),
        attributes: body))
    }
    return result
  }

  private static let mentionRegex: NSRegularExpression? = {
    let ids = MentionCatalog.all.map { NSRegularExpression.escapedPattern(for: $0.id) }
      .sorted { $0.count > $1.count }.joined(separator: "|")
    return try? NSRegularExpression(pattern: "(?:\(ids))(?::[^\\s]+)?")
  }()

  private static func mentionTokenRanges(in text: String) -> [NSRange] {
    guard let regex = mentionRegex else { return [] }
    let ns = text as NSString
    return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map(\.range)
  }
}

// MARK: - Chip builder

enum MentionChip {
  /// favicon attachment + thin space + name colored by the dominant color, optionally
  /// followed by a `▾` disclosure. The whole run carries `.mentionToken`.
  static func attributed(token: String, label: String, font: NSFont,
                         image: NSImage, color: NSColor, showDisclosure: Bool) -> NSAttributedString {
    let cap = font.capHeight
    let glyph = (max(cap + 3, 12)).rounded()
    let scaled = resize(image, to: NSSize(width: glyph, height: glyph))

    let attachment = NSTextAttachment()
    attachment.image = scaled
    // Center the glyph box on the cap-height midline (≈ the font's optical center).
    // Derived purely from cap + glyph, so it stays centered at every font size.
    attachment.bounds = NSRect(x: 0, y: (cap - glyph) / 2, width: glyph, height: glyph)

    let chip = NSMutableAttributedString(attributedString: NSAttributedString(attachment: attachment))
    chip.append(NSAttributedString(string: "\u{2009}", attributes: [.font: font]))
    let nameFont = NSFont.systemFont(ofSize: font.pointSize - 1, weight: .medium)
    chip.append(NSAttributedString(string: label, attributes: [.font: nameFont, .foregroundColor: color]))
    if showDisclosure { chip.append(disclosure(font: font, color: color.withAlphaComponent(0.42))) }
    chip.addAttribute(.mentionToken, value: token, range: NSRange(location: 0, length: chip.length))
    return chip
  }

  /// The "click to search" affordance appended to interactive app chips — a quiet
  /// chevron that sits a hair below the cap line so it reads as an affordance, not a glyph.
  static func disclosure(font: NSFont, color: NSColor) -> NSAttributedString {
    let small = NSFont.systemFont(ofSize: font.pointSize - 4, weight: .medium)
    return NSAttributedString(string: "\u{2009}\u{25BE}", attributes: [
      .font: small,
      .foregroundColor: color,
      .baselineOffset: 0.5,
    ])
  }

  private static func resize(_ image: NSImage, to size: NSSize) -> NSImage {
    NSImage(size: size, flipped: false) { rect in
      image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
      return true
    }
  }
}

// MARK: - GitHub Octocat (vector)

/// Official GitHub mark path (16×16 viewBox, even-odd fill). We render it from the
/// vector with NSBezierPath because NSImage's SVG rep draws blank in offscreen/bitmap
/// contexts (which color extraction and chip sizing rely on).
private let githubOctocatPathData = "M8 0C3.58 0 0 3.58 0 8C0 11.54 2.29 14.53 5.47 15.59C5.87 15.66 6.02 15.42 6.02 15.21C6.02 15.02 6.01 14.39 6.01 13.72C4 14.09 3.48 13.23 3.32 12.78C3.23 12.55 2.84 11.84 2.5 11.65C2.22 11.5 1.82 11.13 2.49 11.12C3.12 11.11 3.57 11.7 3.72 11.94C4.44 13.15 5.59 12.81 6.05 12.6C6.12 12.08 6.33 11.73 6.56 11.53C4.78 11.33 2.92 10.64 2.92 7.58C2.92 6.71 3.23 5.99 3.74 5.43C3.66 5.23 3.38 4.41 3.82 3.31C3.82 3.31 4.49 3.1 6.02 4.13C6.66 3.95 7.34 3.86 8.02 3.86C8.7 3.86 9.38 3.95 10.02 4.13C11.55 3.09 12.22 3.31 12.22 3.31C12.66 4.41 12.38 5.23 12.3 5.43C12.81 5.99 13.12 6.7 13.12 7.58C13.12 10.65 11.25 11.33 9.47 11.53C9.76 11.78 10.01 12.26 10.01 13.01C10.01 14.08 10 14.94 10 15.21C10 15.42 10.15 15.67 10.55 15.59C13.71 14.53 16 11.53 16 8C16 3.58 12.42 0 8 0Z"

/// The white Octocat, drawn from the vector path so it rasterizes crisply at any size.
func githubOctocatImage(size: CGFloat = 64) -> NSImage {
  NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
    let path = parseSVGPath(githubOctocatPathData, box: 16)
    let transform = NSAffineTransform()
    transform.scale(by: rect.width / 16.0)
    path.transform(using: transform as AffineTransform)
    path.windingRule = .evenOdd
    NSColor.white.setFill()
    path.fill()
    return true
  }
}

// MARK: - Figma logo (vector)

/// The official Figma mark — five colored tiles in a 54×80 (portrait) viewBox. Like the Octocat we
/// draw it from vector paths rather than NSImage's SVG rep, which renders blank in the offscreen
/// bitmap contexts color extraction and chip sizing rely on. Each tile keeps its brand color.
private let figmaLogoTiles: [(data: String, fill: NSColor)] = [
  ("M13.3333 80.0002C20.6933 80.0002 26.6667 74.0268 26.6667 66.6668V53.3335H13.3333C5.97333 53.3335 0 59.3068 0 66.6668C0 74.0268 5.97333 80.0002 13.3333 80.0002Z", figmaColor(0x0ACF83)),
  ("M0 39.9998C0 32.6398 5.97333 26.6665 13.3333 26.6665H26.6667V53.3332H13.3333C5.97333 53.3332 0 47.3598 0 39.9998Z", figmaColor(0xA259FF)),
  ("M0 13.3333C0 5.97333 5.97333 0 13.3333 0H26.6667V26.6667H13.3333C5.97333 26.6667 0 20.6933 0 13.3333Z", figmaColor(0xF24E1E)),
  ("M26.6667 0H40.0001C47.3601 0 53.3334 5.97333 53.3334 13.3333C53.3334 20.6933 47.3601 26.6667 40.0001 26.6667H26.6667V0Z", figmaColor(0xFF7262)),
  ("M53.3334 39.9998C53.3334 47.3598 47.3601 53.3332 40.0001 53.3332C32.6401 53.3332 26.6667 47.3598 26.6667 39.9998C26.6667 32.6398 32.6401 26.6665 40.0001 26.6665C47.3601 26.6665 53.3334 32.6398 53.3334 39.9998Z", figmaColor(0x1ABCFE)),
]

private func figmaColor(_ hex: UInt32) -> NSColor {
  NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
          green: CGFloat((hex >> 8) & 0xFF) / 255,
          blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

/// The Figma mark, drawn from its vector tiles so it rasterizes crisply at any size. The portrait
/// artwork is fit by height and centered in the square icon so it never distorts.
func figmaLogoImage(size: CGFloat = 64) -> NSImage {
  NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
    let viewW: CGFloat = 54, viewH: CGFloat = 80
    let scale = rect.height / viewH
    let xOffset = (rect.width - viewW * scale) / 2
    for tile in figmaLogoTiles {
      let path = parseSVGPath(tile.data, box: viewH)
      let scaleT = NSAffineTransform(); scaleT.scale(by: scale)
      path.transform(using: scaleT as AffineTransform)
      let moveT = NSAffineTransform(); moveT.translateX(by: xOffset, yBy: 0)
      path.transform(using: moveT as AffineTransform)
      tile.fill.setFill()
      path.fill()
    }
    return true
  }
}

// MARK: - Minimal SVG path parser (absolute/relative M L H V C Z)

private enum SVGToken { case command(Character); case number(CGFloat) }

private func tokenizeSVGPath(_ d: String) -> [SVGToken] {
  var tokens: [SVGToken] = []
  let chars = Array(d)
  var i = 0
  while i < chars.count {
    let ch = chars[i]
    if ch.isLetter {
      tokens.append(.command(ch)); i += 1
    } else if ch == "-" || ch == "." || ch.isNumber {
      var s = ""
      if ch == "-" { s.append("-"); i += 1 }
      var seenDot = false
      while i < chars.count {
        let c = chars[i]
        if c.isNumber { s.append(c); i += 1 }
        else if c == "." && !seenDot { seenDot = true; s.append(c); i += 1 }
        else { break }
      }
      if let v = Double(s) { tokens.append(.number(CGFloat(v))) }
    } else {
      i += 1   // commas, spaces
    }
  }
  return tokens
}

/// Build an NSBezierPath in a y-up coordinate box (SVG is y-down, so y is flipped).
private func parseSVGPath(_ d: String, box: CGFloat) -> NSBezierPath {
  let tokens = tokenizeSVGPath(d)
  let path = NSBezierPath()
  var current = CGPoint.zero
  var start = CGPoint.zero
  var index = 0
  var command: Character = " "

  func number() -> CGFloat {
    if index < tokens.count, case let .number(v) = tokens[index] { index += 1; return v }
    return 0
  }
  func peekIsNumber() -> Bool {
    guard index < tokens.count else { return false }
    if case .number = tokens[index] { return true }
    return false
  }
  func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: box - y) }

  while index < tokens.count {
    if case let .command(ch) = tokens[index] { command = ch; index += 1 }
    let relative = command.isLowercase
    switch Character(command.uppercased()) {
    case "M":
      var x = number(), y = number()
      if relative { x += current.x; y += current.y }
      current = CGPoint(x: x, y: y); start = current
      path.move(to: point(x, y))
      while peekIsNumber() {
        var lx = number(), ly = number()
        if relative { lx += current.x; ly += current.y }
        current = CGPoint(x: lx, y: ly); path.line(to: point(lx, ly))
      }
    case "L":
      while peekIsNumber() {
        var x = number(), y = number()
        if relative { x += current.x; y += current.y }
        current = CGPoint(x: x, y: y); path.line(to: point(x, y))
      }
    case "H":
      while peekIsNumber() {
        var x = number(); if relative { x += current.x }
        current.x = x; path.line(to: point(current.x, current.y))
      }
    case "V":
      while peekIsNumber() {
        var y = number(); if relative { y += current.y }
        current.y = y; path.line(to: point(current.x, current.y))
      }
    case "C":
      while peekIsNumber() {
        var x1 = number(), y1 = number(), x2 = number(), y2 = number(), x = number(), y = number()
        if relative {
          x1 += current.x; y1 += current.y
          x2 += current.x; y2 += current.y
          x += current.x; y += current.y
        }
        path.curve(to: point(x, y), controlPoint1: point(x1, y1), controlPoint2: point(x2, y2))
        current = CGPoint(x: x, y: y)
      }
    case "Z":
      path.close(); current = start
    default:
      break
    }
  }
  return path
}
