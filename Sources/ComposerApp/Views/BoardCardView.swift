import AppKit
import ImageIO
import SwiftUI

/// One text card on the board, with Excalidraw-style interaction:
/// • single click selects (ring + corner resize handles), • drag the body moves it,
/// • double-click (or click an already-selected card) edits the text, • corner handles resize,
/// • ✕ deletes. The body is the unmodified `FreeWriteEditor`; it only receives mouse events
/// while editing, so a drag on a non-editing card moves it instead of selecting text.
struct BoardCardView: View {
  let card: CardState
  @ObservedObject var interaction: CardInteraction
  let isSelected: Bool
  let isEditing: Bool
  /// Board zoom — gesture translations are divided by it so moves/resizes track the cursor.
  let scale: CGFloat
  let board: BoardViewModel
  var onEscape: () -> Void

  @State private var moveDelta: CGSize = .zero
  @GestureState private var resize: ResizeSession?
  @State private var hovering = false
  @FocusState private var labelFocused: Bool
  /// True only when the press landed on an already-selected card — so the first click on an
  /// unselected card just selects it (and a drag pans/does nothing), and you move it on the next.
  @State private var armedForMove = false

  /// The content's corner radius, so the selection ring hugs each element shape correctly
  /// (a too-round ring around a square image is what reads as "wrong").
  private var radius: CGFloat {
    switch card.elementKind {
    case .text: 12
    case .image: 10
    case .rectangle: 8
    default: 6
    }
  }
  private var minW: CGFloat { card.minimumSize.width }
  private var minH: CGFloat { card.minimumSize.height }
  private var zoom: CGFloat { max(scale, 0.01) }
  private var isTextElement: Bool { card.elementKind == .text }
  /// An empty text card is just a place to write, not a placed object — so it shows no chrome.
  private var isEmptyText: Bool { isTextElement && interaction.text.trimmed.isEmpty }

  /// The frame to draw right now — base frame plus any in-flight move or resize.
  private var liveFrame: CGRect {
    if let resize { return applyResize(resize.corner, translation: resize.translation, to: card.frame) }
    var f = card.frame
    f.origin.x += moveDelta.width / zoom
    f.origin.y += moveDelta.height / zoom
    f.origin.x += interaction.dragDelta.width
    f.origin.y += interaction.dragDelta.height
    return f
  }

  var body: some View {
    cardBody
      .opacity(card.isArchived ? 0.4 : 1)   // superseded ideas fade but stay for lineage
      .frame(width: liveFrame.width, height: liveFrame.height, alignment: .topLeading)
      .background(surface)
      .overlay(selectionChrome)
      .overlay(deleteButton, alignment: .topTrailing)
      .overlay(lockBadge, alignment: .topLeading)
      .offset(x: liveFrame.minX, y: liveFrame.minY)
      .onHover { hovering = $0 }
      .onChange(of: interaction.text) { oldValue, newValue in
        // FreeWriteEditor writes serialized text here. Keeping the plain-text cache current lets
        // static cards and persistence read it without materializing an NSTextView controller.
        interaction.cachePlainText(newValue)
        board.noteEdited(cardID: card.id, previousText: oldValue)
      }
  }

  // MARK: Body (editor + move/select catcher)

  private var cardBody: some View {
    ZStack {
      if isEditing, isTextElement {
        FreeWriteEditor(
          text: $interaction.text,
          initialAttributedText: interaction.attributedSnapshot,
          placeholder: "Brain dump\u{2026}",
          onCountChange: { interaction.count = $0 },
          onSelectionChange: { interaction.selection = $0 },
          onEscape: handleEscape,
          onFocusChange: { active in
            if active {
              board.beginEditing(card.id)
            } else if !interaction.appSearch.isOpen, !interaction.mentions.isOpen {
              // The editor only truly stopped editing if focus left for a real reason (a
              // click-away) — not because our own inline search field or mention menu took
              // first responder. Tearing down editing there would kill the very popup the
              // user is picking from.
              board.endEditing(card.id)
            }
          },
          onHeightChange: { contentHeight in
            // + the editor's vertical padding below, so the card frame fits the text exactly.
            board.fitTextHeight(card.id, to: contentHeight + 20)
          },
          boardContext: { board.lintContext(excluding: card.id) },
          mentions: interaction.mentions,
          appSearch: interaction.appSearch,
          controller: interaction.controller,
          lint: interaction.lint,
          refine: interaction.refine,
          store: DumpStore.shared
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
      } else {
        // Non-editing cards render from the serialized plain text (tokens like "@github"), so
        // the chip renderer can rebuild the styled chips — `interaction.text` is the visible
        // string, where a chip has already collapsed to its bare label.
        CanvasElementContent(card: card, text: interaction.plainText)
          .padding(.horizontal, isTextElement ? 16 : 0)
          .padding(.vertical, isTextElement ? 18 : 0)
          .allowsHitTesting(false)

        if isEditing, !isTextElement {
          shapeLabelEditor
        }

        // Select on mouse-down so handles appear immediately. SwiftUI's separate
        // single/double tap recognizers wait out the double-click interval first.
        CardPointerCatcher(
          onPress: { modifiers in
            let extending = modifiers.contains(.shift)
            let toggling = modifiers.contains(.command)
            // A plain press selects (if needed) AND arms the move, so one click + drag moves the
            // card in a single gesture; a click with no drag just selects. The 4px drag dead-zone
            // keeps a plain click from nudging it.
            armedForMove = !extending && !toggling
            if extending || toggling || !isSelected {
              board.select(card.id, extending: extending, toggling: toggling)
            }
          },
          onDoubleClick: enterEditing,
          onDragChanged: updateMovePreview,
          onDragEnded: commitMove
        )
        .allowsHitTesting(!isEditing)
      }
    }
  }

  private var shapeLabelEditor: some View {
    TextField("Label", text: $interaction.text)
      .textFieldStyle(.plain)
      .font(.system(size: 15, weight: .medium))
      .foregroundStyle(Theme.Palette.body)
      .multilineTextAlignment(.center)
      .padding(.horizontal, 10)
      .padding(.vertical, 7)
      .frame(width: min(max(liveFrame.width - 20, 120), 220))
      .background(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(Color.black.opacity(0.36))
          .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
      )
      .focused($labelFocused)
      .onSubmit { board.endEditing(card.id) }
      .onExitCommand { handleEscape() }
      .onAppear {
        DispatchQueue.main.async { labelFocused = true }
      }
  }

  private func enterEditing() {
    board.beginEditing(card.id)
    if isTextElement {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { interaction.controller.focus() }
    }
  }

  private func handleEscape() {
    if isEditing {
      if isTextElement {
        interaction.controller.resignFocus()
      } else {
        board.endEditing(card.id)
      }
    } else {
      onEscape()
    }
  }

  private func commitMove(_ translation: CGSize) {
    moveDelta = .zero
    guard armedForMove, !card.locked else { return }
    guard hypot(translation.width, translation.height) >= 1 else { return }
    let boardDelta = CGSize(width: translation.width / zoom, height: translation.height / zoom)
    if board.selectedCardIDs.contains(card.id), board.selectedCardIDs.count > 1 {
      board.finishMovePreview(commit: true)
    } else {
      board.setFrame(card.id, CGRect(
        x: card.x + boardDelta.width,
        y: card.y + boardDelta.height,
      width: card.w, height: card.h))
    }
  }

  private func updateMovePreview(_ translation: CGSize) {
    guard armedForMove, !card.locked else { return }
    if board.selectedCardIDs.contains(card.id), board.selectedCardIDs.count > 1 {
      board.updateMovePreview(by: CGSize(width: translation.width / zoom, height: translation.height / zoom))
    } else {
      moveDelta = translation
    }
  }

  // MARK: Selection ring + resize handles

  /// Px the selection ring sits outside the content, so it frames the element with a little
  /// breathing room instead of crowding it (and the handles ride that same expanded rect).
  private let selectionGap: CGFloat = 5

  @ViewBuilder
  private var selectionChrome: some View {
    // An empty text card stays bare — a writing spot, not a boxed object. While you type into
    // a text card it's chromeless too; the ring returns only once it's a placed object you
    // select to move or resize. Shapes keep their ring while editing.
    if (isSelected || isEditing) && !isEmptyText {
      let showRing = !isTextElement || (isSelected && !isEditing)
      let showHandles = isSelected && !isEditing && !card.locked
      GeometryReader { geo in
        ZStack {
          if showRing {
            RoundedRectangle(cornerRadius: radius + selectionGap, style: .continuous)
              .strokeBorder(Color.accentColor.opacity(isEditing ? 0.9 : 0.7), lineWidth: 1)
              .frame(width: geo.size.width + selectionGap * 2, height: geo.size.height + selectionGap * 2)
              .position(x: geo.size.width / 2, y: geo.size.height / 2)
              .allowsHitTesting(false)
          }
          if showHandles {
            ForEach(Corner.allCases, id: \.self) { corner in
              handleDot
                .position(handlePoint(corner, in: geo.size))
                .gesture(resizeGesture(corner))
            }
          }
        }
      }
    }
  }

  private func handlePoint(_ corner: Corner, in size: CGSize) -> CGPoint {
    switch corner {
    case .topLeading: CGPoint(x: -selectionGap, y: -selectionGap)
    case .topTrailing: CGPoint(x: size.width + selectionGap, y: -selectionGap)
    case .bottomLeading: CGPoint(x: -selectionGap, y: size.height + selectionGap)
    case .bottomTrailing: CGPoint(x: size.width + selectionGap, y: size.height + selectionGap)
    }
  }

  /// A small white square with a hairline accent edge and a soft shadow — reads as a crisp,
  /// premium resize handle on the dark glass rather than a flat blue block.
  private var handleDot: some View {
    RoundedRectangle(cornerRadius: 2.5, style: .continuous)
      .fill(Color.white)
      .frame(width: 8, height: 8)
      .overlay(RoundedRectangle(cornerRadius: 2.5, style: .continuous).strokeBorder(Color.accentColor.opacity(0.9), lineWidth: 1))
      .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
      .padding(9)
      .contentShape(Rectangle())
  }

  private func resizeGesture(_ corner: Corner) -> some Gesture {
    DragGesture(minimumDistance: 4, coordinateSpace: .local)
      .updating($resize) { value, state, _ in state = ResizeSession(corner: corner, translation: value.translation) }
      .onEnded { value in board.setFrame(card.id, applyResize(corner, translation: value.translation, to: card.frame)) }
  }

  /// New frame for a corner drag, clamped to the minimum size by pushing the moving edge back.
  private func applyResize(_ corner: Corner, translation t: CGSize, to base: CGRect) -> CGRect {
    let dx = t.width / zoom, dy = t.height / zoom
    var minX = base.minX, minY = base.minY, maxX = base.maxX, maxY = base.maxY
    switch corner {
    case .topLeading: minX += dx; minY += dy
    case .topTrailing: maxX += dx; minY += dy
    case .bottomLeading: minX += dx; maxY += dy
    case .bottomTrailing: maxX += dx; maxY += dy
    }
    if maxX - minX < minW {
      if corner == .topLeading || corner == .bottomLeading { minX = maxX - minW } else { maxX = minX + minW }
    }
    if maxY - minY < minH {
      if corner == .topLeading || corner == .topTrailing { minY = maxY - minH } else { maxY = minY + minH }
    }
    return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
  }

  // MARK: Delete

  @ViewBuilder
  private var deleteButton: some View {
    if isSelected && !isEditing && !card.locked && !isEmptyText {
      Button(action: { board.delete(card.id) }) {
        Image(systemName: "xmark")
          .font(.system(size: 9, weight: .bold))
          .foregroundStyle(Color.white.opacity(0.9))
          .frame(width: 18, height: 18)
          .background(Circle().fill(Color.black.opacity(0.55)))
          .overlay(Circle().strokeBorder(Color.white.opacity(0.16), lineWidth: 0.5))
          .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
          .contentShape(Circle())
      }
      .buttonStyle(.plain)
      .help("Delete card")
      .offset(x: selectionGap + 4, y: -(selectionGap + 4))
    }
  }

  @ViewBuilder
  private var lockBadge: some View {
    if card.locked {
      Image(systemName: "lock.fill")
        .font(.system(size: 10, weight: .bold))
        .foregroundStyle(Color.white.opacity(0.82))
        .frame(width: 20, height: 20)
        .background(Circle().fill(Color.black.opacity(0.45)))
        .overlay(Circle().strokeBorder(Color.white.opacity(0.16), lineWidth: 1))
        .offset(x: -7, y: -7)
        .allowsHitTesting(false)
    }
  }

  // MARK: Surface

  // Text writes directly on the canvas — no filled "text box" behind it. Shapes and images
  // draw their own fills in CanvasElementContent, so every card's frame stays transparent here.
  private var surface: some View { Color.clear }
}

// MARK: - Element rendering

private struct CanvasElementContent: View {
  let card: CardState
  /// Serialized plain text (`@github`, `[image: …]`, literal prose) for text cards.
  let text: String

  var body: some View {
    ZStack {
      Group {
        switch card.elementKind {
        case .text:
          Group {
            if text.trimmed.isEmpty {
              Text("Brain dump\u{2026}")
                .font(Font(Theme.Typography.body))
                .lineSpacing(Theme.Typography.bodyLineSpacing)
                .foregroundStyle(Theme.Palette.placeholder)
            } else {
              ComposerChipText(plain: text)
            }
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
          .clipped()
        case .rectangle:
          ShapeBox(kind: .rectangle)
        case .ellipse:
          ShapeBox(kind: .ellipse)
        case .diamond:
          ShapeBox(kind: .diamond)
        case .line:
          LineShape(arrow: false, points: card.points ?? CardState.defaultLinePoints())
        case .arrow:
          LineShape(arrow: true, points: card.points ?? CardState.defaultLinePoints())
        case .freehand:
          FreehandShape(points: card.points ?? CardState.defaultFreehandPoints())
        case .image:
          ImageObjectPlaceholder(path: card.imagePath)
        }
      }

      if !text.trimmed.isEmpty {
        switch card.elementKind {
        case .rectangle, .ellipse, .diamond:
          // A diagram node: the label fills the box (the box is the boundary).
          NodeLabel(text: text.trimmed)
        case .arrow, .line:
          // A connector label: a floating pill so it stays legible over the canvas.
          CanvasLabel(text: text.trimmed)
        default:
          EmptyView()
        }
      }
    }
  }
}

/// The centered label inside a diagram-node box. No pill background — the surrounding shape is the
/// container — and it wraps/scales to fit rather than truncating mid-word.
private struct NodeLabel: View {
  let text: String

  var body: some View {
    Text(text)
      .font(.system(size: 14, weight: .semibold))
      .multilineTextAlignment(.center)
      .lineLimit(5)
      .minimumScaleFactor(0.82)
      .foregroundStyle(Color.white.opacity(0.95))
      .shadow(color: .black.opacity(0.45), radius: 3, y: 1)
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .allowsHitTesting(false)
  }
}

// MARK: - Chip-aware static text (non-editing cards)

/// Renders a card's serialized plain text with its mention chips styled — brand icon, brand
/// color, and the `▾` affordance on app chips — so a card looks the same whether or not it's
/// being edited. Built as concatenated `Text` runs so it wraps natively and stays cheap; image
/// placeholders show a small inline glyph (the real attachment only lives in the live editor).
private struct ComposerChipText: View {
  let plain: String

  var body: some View {
    composed
      .font(Font(Theme.Typography.body))
      .lineSpacing(Theme.Typography.bodyLineSpacing)
      .foregroundStyle(Theme.Palette.body)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  // Called from `body`, so the main-actor `MentionStyleCache` access in `styledRun` is safe.
  @MainActor private var composed: Text {
    let ns = plain as NSString
    var out = Text(verbatim: "")
    var cursor = 0
    for range in Self.tokenRanges(in: plain) {
      if range.location > cursor {
        out = out + Text(verbatim: ns.substring(with: NSRange(location: cursor, length: range.location - cursor)))
      }
      out = out + Self.styledRun(for: ns.substring(with: range))
      cursor = range.location + range.length
    }
    if cursor < ns.length {
      out = out + Text(verbatim: ns.substring(with: NSRange(location: cursor, length: ns.length - cursor)))
    }
    return out
  }

  /// Matches any catalog mention token (longest id first so `@build-ios-apps` wins over a
  /// shorter prefix), with an optional `:payload`, plus `[image: …]` placeholders.
  private static let tokenRegex: NSRegularExpression? = {
    let ids = MentionCatalog.all.map { NSRegularExpression.escapedPattern(for: $0.id) }
      .sorted { $0.count > $1.count }
      .joined(separator: "|")
    return try? NSRegularExpression(pattern: "(?:\(ids))(?::[^\\s]+)?|\\[image:[^\\]]*\\]")
  }()

  private static func tokenRanges(in text: String) -> [NSRange] {
    guard let regex = tokenRegex else { return [] }
    let ns = text as NSString
    return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map(\.range)
  }

  @MainActor private static func styledRun(for raw: String) -> Text {
    if raw.hasPrefix("[image:") {
      return Text(Image(systemName: "photo")).foregroundColor(Theme.Palette.placeholder)
    }
    let parsed = AppToken.parse(raw)
    let appID = parsed?.appID ?? raw
    let item = MentionCatalog.all.first { $0.id == appID }
    let isApp = item?.kind == .app
    let label = isApp ? AppToken.label(appID: appID, selection: parsed?.selection) : (item?.label ?? raw)
    let cache = MentionStyleCache.shared
    let color = Color(nsColor: cache.color(for: appID) ?? .controlAccentColor)

    var chip = Text(verbatim: "")
    if let icon = cache.inlineImage(for: appID) {
      chip = chip + Text(Image(nsImage: icon)).baselineOffset(-2) + Text(verbatim: "\u{2009}")
    }
    chip = chip + Text(verbatim: label).foregroundColor(color)
    if isApp { chip = chip + Text(verbatim: "\u{2009}\u{25BE}").foregroundColor(color.opacity(0.5)) }
    return chip
  }
}

private struct CanvasLabel: View {
  let text: String

  var body: some View {
    Text(text)
      .font(.system(size: 14, weight: .semibold))
      .lineLimit(2)
      .multilineTextAlignment(.center)
      .foregroundStyle(Color.white.opacity(0.90))
      .padding(.horizontal, 9)
      .padding(.vertical, 5)
      .background(
        RoundedRectangle(cornerRadius: 7, style: .continuous)
          .fill(Color.black.opacity(0.34))
          .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
      )
      .shadow(color: .black.opacity(0.18), radius: 5, y: 2)
      .padding(8)
      .allowsHitTesting(false)
  }
}

private struct ShapeBox: View {
  let kind: BoxShapeKind

  var body: some View {
    BoxShape(kind: kind)
      .fill(Color.black.opacity(0.22))
      .overlay(BoxShape(kind: kind).stroke(Color.white.opacity(0.72), lineWidth: 2))
      .shadow(color: .black.opacity(0.22), radius: 10, y: 4)
      .padding(2)
  }
}

private enum BoxShapeKind {
  case rectangle
  case ellipse
  case diamond
}

private struct BoxShape: Shape {
  let kind: BoxShapeKind

  func path(in rect: CGRect) -> Path {
    switch kind {
    case .rectangle:
      return RoundedRectangle(cornerRadius: 8, style: .continuous).path(in: rect)
    case .ellipse:
      return Ellipse().path(in: rect)
    case .diamond:
      var path = Path()
      path.move(to: CGPoint(x: rect.midX, y: rect.minY))
      path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
      path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
      path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
      path.closeSubpath()
      return path
    }
  }
}

private struct LineShape: View {
  let arrow: Bool
  let points: [CanvasPoint]

  var body: some View {
    GeometryReader { geo in
      Path { path in
        let normalizedStart = points.first?.cgPoint ?? CGPoint(x: 0.06, y: 0.88)
        let normalizedEnd = points.dropFirst().first?.cgPoint ?? CGPoint(x: 0.94, y: 0.12)
        let start = CGPoint(x: normalizedStart.x * geo.size.width, y: normalizedStart.y * geo.size.height)
        let end = CGPoint(x: normalizedEnd.x * geo.size.width, y: normalizedEnd.y * geo.size.height)
        path.move(to: start)
        path.addLine(to: end)
        if arrow {
          let angle = atan2(end.y - start.y, end.x - start.x)
          let head: CGFloat = 15
          for side in [CGFloat.pi * 0.82, -CGFloat.pi * 0.82] {
            let p = CGPoint(
              x: end.x + cos(angle + side) * head,
              y: end.y + sin(angle + side) * head
            )
            path.move(to: end)
            path.addLine(to: p)
          }
        }
      }
      .stroke(Color.white.opacity(0.78), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
      .shadow(color: .black.opacity(0.20), radius: 6, y: 3)
    }
  }
}

private struct FreehandShape: View {
  let points: [CanvasPoint]

  var body: some View {
    GeometryReader { geo in
      Path { path in
        let mapped = points.map { CGPoint(x: $0.x * geo.size.width, y: $0.y * geo.size.height) }
        guard let first = mapped.first else { return }
        path.move(to: first)
        for point in mapped.dropFirst() { path.addLine(to: point) }
      }
      .stroke(Color.white.opacity(0.78), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
      .shadow(color: .black.opacity(0.20), radius: 6, y: 3)
    }
  }
}

private struct ImageObjectPlaceholder: View {
  let path: String?
  @State private var image: NSImage?
  @State private var requestedPath: String?

  var body: some View {
    Group {
      if let image {
      Image(nsImage: image)
        .resizable()
        .scaledToFill()
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
          .strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
      } else {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(Color.black.opacity(0.16))
          .overlay {
            VStack(spacing: 8) {
              Image(systemName: "photo")
                .font(.system(size: 24, weight: .medium))
              Text(path.map { ($0 as NSString).lastPathComponent } ?? "Image")
                .font(.caption.weight(.medium))
                .lineLimit(1)
            }
            .foregroundStyle(Color.white.opacity(0.72))
            .padding(10)
          }
          .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(Color.white.opacity(0.26), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])))
          .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
      }
    }
    .onAppear { loadImage(for: path) }
    .onChange(of: path) { _, nextPath in loadImage(for: nextPath) }
  }

  private func loadImage(for path: String?) {
    requestedPath = path
    image = nil
    guard let path else { return }
    CanvasImageCache.shared.load(path: path) { loaded in
      // Culling/reuse can change this view's card before an asynchronous decode returns.
      guard requestedPath == path else { return }
      image = loaded
    }
  }
}

/// A bounded, asynchronous thumbnail cache. The previous cache kept the full source image for
/// every visited card and decoded it synchronously from `body`, which made panning into a board
/// of large screenshots both a main-thread hitch and an unbounded memory grower.
private final class CanvasImageCache {
  static let shared = CanvasImageCache()
  private let cache = NSCache<NSString, NSImage>()
  private let decodeQueue = DispatchQueue(label: "dev.jow.Composer.canvas-image-decode", qos: .userInitiated)
  private var pending: [String: [(NSImage?) -> Void]] = [:]

  private static let maximumPixelDimension = 1_536

  private init() {
    cache.countLimit = 48
    cache.totalCostLimit = 48 * 1_024 * 1_024
  }

  func load(path: String, completion: @escaping (NSImage?) -> Void) {
    let key = path as NSString
    if let cached = cache.object(forKey: key) {
      completion(cached)
      return
    }
    if pending[path] != nil {
      pending[path, default: []].append(completion)
      return
    }
    pending[path] = [completion]
    decodeQueue.async { [weak self] in
      let decoded = Self.decodeThumbnail(at: path)
      DispatchQueue.main.async {
        guard let self else { return }
        if let image = decoded?.image {
          self.cache.setObject(image, forKey: key, cost: decoded?.cost ?? 0)
        }
        let callbacks = self.pending.removeValue(forKey: path) ?? []
        callbacks.forEach { $0(decoded?.image) }
      }
    }
  }

  private static func decodeThumbnail(at path: String) -> (image: NSImage, cost: Int)? {
    let url = URL(fileURLWithPath: path)
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: maximumPixelDimension,
      kCGImageSourceShouldCacheImmediately: true,
    ]
    guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
    let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    return (image, cgImage.bytesPerRow * cgImage.height)
  }
}

// MARK: - Immediate pointer catcher

private struct CardPointerCatcher: NSViewRepresentable {
  var onPress: (EventModifiers) -> Void
  var onDoubleClick: () -> Void
  var onDragChanged: (CGSize) -> Void
  var onDragEnded: (CGSize) -> Void

  func makeNSView(context: Context) -> CatcherView {
    let view = CatcherView()
    view.callbacks = callbacks
    return view
  }

  func updateNSView(_ nsView: CatcherView, context: Context) {
    nsView.callbacks = callbacks
  }

  private var callbacks: CatcherView.Callbacks {
    CatcherView.Callbacks(
      onPress: onPress,
      onDoubleClick: onDoubleClick,
      onDragChanged: onDragChanged,
      onDragEnded: onDragEnded
    )
  }

  final class CatcherView: NSView {
    struct Callbacks {
      var onPress: (EventModifiers) -> Void = { _ in }
      var onDoubleClick: () -> Void = {}
      var onDragChanged: (CGSize) -> Void = { _ in }
      var onDragEnded: (CGSize) -> Void = { _ in }
    }

    var callbacks = Callbacks()
    /// Drag origin in WINDOW space. The catcher lives inside the card's own moving/scaling
    /// layer, so reading translation in its local space feeds the move back into itself and the
    /// card jitters (and leaves ghost trails). Window space stays put as the card moves.
    private var dragStart: NSPoint?
    private var lastTranslation: CGSize = .zero
    /// A small dead-zone so a click with a touch of jitter doesn't read as a move.
    private var passedThreshold = false

    override var isFlipped: Bool { true }

    override func mouseDown(with event: NSEvent) {
      dragStart = event.locationInWindow
      lastTranslation = .zero
      passedThreshold = false
      callbacks.onPress(EventModifiers(event.modifierFlags))
      if event.clickCount >= 2 {
        dragStart = nil
        callbacks.onDragChanged(.zero)
        callbacks.onDoubleClick()
      }
    }

    override func mouseDragged(with event: NSEvent) {
      guard let dragStart else { return }
      let p = event.locationInWindow
      if !passedThreshold {
        guard hypot(p.x - dragStart.x, p.y - dragStart.y) >= 4 else { return }
        passedThreshold = true
      }
      // Window y is up; the board is y-down, so negate dy. Divided by zoom downstream.
      let translation = CGSize(width: p.x - dragStart.x, height: dragStart.y - p.y)
      lastTranslation = translation
      callbacks.onDragChanged(translation)
    }

    override func mouseUp(with event: NSEvent) {
      guard dragStart != nil else { return }
      dragStart = nil
      passedThreshold = false
      callbacks.onDragEnded(lastTranslation)
      callbacks.onDragChanged(.zero)
      lastTranslation = .zero
    }

    // A non-editing card sits above the board's scroll surface, so without these the cursor
    // hovering a card would dead-end two-finger scroll / pinch. Forward them to the canvas so
    // panning and zooming work everywhere; the card is still draggable once you grab it.
    override func scrollWheel(with event: NSEvent) {
      NotificationCenter.default.post(
        name: .composerCanvasScroll, object: nil,
        userInfo: ["dx": event.scrollingDeltaX, "dy": event.scrollingDeltaY])
    }

    // Pinch-zoom is handled board-wide by PinchZoomCatcher's event monitor, so cards don't need to
    // forward magnify (which anchored inconsistently at the viewport center).
  }
}

// MARK: - Corner geometry

private enum Corner: CaseIterable, Hashable {
  case topLeading, topTrailing, bottomLeading, bottomTrailing

  func point(in size: CGSize) -> CGPoint {
    switch self {
    case .topLeading: CGPoint(x: 0, y: 0)
    case .topTrailing: CGPoint(x: size.width, y: 0)
    case .bottomLeading: CGPoint(x: 0, y: size.height)
    case .bottomTrailing: CGPoint(x: size.width, y: size.height)
    }
  }
}

private struct ResizeSession: Equatable {
  let corner: Corner
  var translation: CGSize
}

private extension EventModifiers {
  init(_ flags: NSEvent.ModifierFlags) {
    var modifiers: EventModifiers = []
    if flags.contains(.shift) { modifiers.insert(.shift) }
    if flags.contains(.command) { modifiers.insert(.command) }
    if flags.contains(.option) { modifiers.insert(.option) }
    if flags.contains(.control) { modifiers.insert(.control) }
    self = modifiers
  }
}
