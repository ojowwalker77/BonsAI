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
  /// True only in the select tool. When false (any drawing tool) the card is pointer-transparent,
  /// so a drag starting over it falls through to the canvas and draws a new element instead of
  /// grabbing this card — selection/move/resize belong to the select tool alone.
  let selectable: Bool
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
    case .image: 8
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
      .frame(width: liveFrame.width * zoom, height: liveFrame.height * zoom, alignment: .topLeading)
      .background(surface)
      .overlay(selectionChrome)
      .overlay(deleteButton, alignment: .topTrailing)
      .overlay(lockBadge, alignment: .topLeading)
      .offset(x: liveFrame.minX * zoom, y: liveFrame.minY * zoom)
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
    ZStack(alignment: .topLeading) {
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
          definedVariables: { board.definedVariableNames },
          mentions: interaction.mentions,
          appSearch: interaction.appSearch,
          controller: interaction.controller,
          lint: interaction.lint,
          refine: interaction.refine,
          store: DumpStore.shared
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        // The live editor keeps its native (board-size) layout and is scaled to fill the card.
        // Its text softens only while you're actively editing this one card — every other card
        // is layout-zoomed and stays crisp. Anchored top-left to line up with the static render.
        .frame(width: liveFrame.width, height: liveFrame.height, alignment: .topLeading)
        .scaleEffect(zoom, anchor: .topLeading)
      } else {
        // Non-editing cards render from the serialized plain text (tokens like "@github"), so
        // the chip renderer can rebuild the styled chips — `interaction.text` is the visible
        // string, where a chip has already collapsed to its bare label. Fonts/padding scale with
        // zoom so the text is laid out at screen size (crisp), not stretched.
        CanvasElementContent(card: card, text: interaction.plainText, definedVars: board.definedVariableNames, failedCommands: board.failedShellCommands, zoom: zoom)
          .padding(.horizontal, (isTextElement ? 16 : 0) * zoom)
          .padding(.vertical, (isTextElement ? 18 : 0) * zoom)
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
        .allowsHitTesting(!isEditing && selectable)
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
        // Same solid adaptive chip as the rendered label, so entering/leaving edit doesn't flash
        // between a dark editor and a themed chip.
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(Theme.Palette.labelChipFill)
          .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(Theme.Palette.panelHairline, lineWidth: 1))
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
      // Image cards draw their own rounded border, so a ring sitting `selectionGap` px outside reads
      // as an ugly double border with a gap. Hug the image's own edge instead — a single clean
      // accent outline. Other elements (text, shapes, lines) keep the offset ring.
      let hugsContent = card.elementKind == .image
      let ringGap: CGFloat = hugsContent ? 1 : selectionGap
      let ringRadius: CGFloat = hugsContent ? radius : radius + selectionGap
      // Handles only grab in the select tool — in a drawing tool a corner drag should draw, not resize.
      let showHandles = isSelected && !isEditing && !card.locked && selectable
      GeometryReader { geo in
        ZStack {
          if showRing {
            RoundedRectangle(cornerRadius: ringRadius, style: .continuous)
              .strokeBorder(Theme.Palette.accent.opacity(isEditing ? 0.9 : 0.7), lineWidth: hugsContent ? 1.5 : 1)
              .frame(width: geo.size.width + ringGap * 2, height: geo.size.height + ringGap * 2)
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
      .overlay(RoundedRectangle(cornerRadius: 2.5, style: .continuous).strokeBorder(Theme.Palette.accent.opacity(0.9), lineWidth: 1))
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
    if isSelected && !isEditing && !card.locked && !isEmptyText && selectable {
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
  /// Board-scoped variable names, for styling `$name` references defined in other cards.
  var definedVars: Set<String> = []
  /// Commands that failed on the last copy — their tokens render amber.
  var failedCommands: Set<String> = []
  /// Board zoom — fonts scale by it so text is laid out (and stays crisp) at screen size.
  var zoom: CGFloat = 1

  var body: some View {
    ZStack {
      Group {
        switch card.elementKind {
        case .text:
          Group {
            if text.trimmed.isEmpty {
              Text("Brain dump\u{2026}")
                .font(.system(size: Theme.Typography.body.pointSize * zoom))
                .lineSpacing(Theme.Typography.bodyLineSpacing * zoom)
                .foregroundStyle(Theme.Palette.placeholder)
            } else {
              ComposerChipText(plain: text, definedVars: definedVars, failedCommands: failedCommands, zoom: zoom)
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
            .overlay(alignment: .bottomTrailing) {
              // A captured screenshot that's been read on-device carries text into the prompt; mark
              // it so it doesn't look like an inert image.
              if let understanding = card.imageUnderstanding, !understanding.isEmpty {
                Image(systemName: "text.viewfinder")
                  .font(.system(size: 11, weight: .semibold))
                  .foregroundStyle(.white)
                  .padding(5)
                  .background(Color.black.opacity(0.55), in: Circle())
                  .padding(6)
                  .help("Read on-device — this screenshot adds text to the compiled prompt")
              }
            }
        }
      }

      if !text.trimmed.isEmpty {
        switch card.elementKind {
        case .rectangle, .ellipse, .diamond:
          // A diagram node: the label fills the box (the box is the boundary).
          NodeLabel(text: text.trimmed, zoom: zoom)
        case .arrow, .line:
          // A connector label: a floating pill so it stays legible over the canvas.
          CanvasLabel(text: text.trimmed, zoom: zoom)
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
  var zoom: CGFloat = 1

  var body: some View {
    Text(text)
      .font(.system(size: 14 * zoom, weight: .semibold))
      .multilineTextAlignment(.center)
      .lineLimit(5)
      .minimumScaleFactor(0.82)
      // Board ink, not white — and ink on paper casts no shadow (elementShadow is clear in light).
      .foregroundStyle(Theme.Palette.body)
      .shadow(color: Theme.Palette.elementShadow, radius: 3, y: 1)
      .padding(.horizontal, 12 * zoom)
      .padding(.vertical, 8 * zoom)
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
  /// Board-scoped variable names, so a `$name` reference styles even when defined in another card.
  var definedVars: Set<String> = []
  /// Commands that failed on the last copy — their `$(…)` tokens render amber instead of green.
  var failedCommands: Set<String> = []
  /// Board zoom — the base font + chip icons scale by it so the text is laid out at screen size.
  var zoom: CGFloat = 1

  var body: some View {
    composed
      .font(.system(size: Theme.Typography.body.pointSize * zoom))
      .lineSpacing(Theme.Typography.bodyLineSpacing * zoom)
      .foregroundStyle(Theme.Palette.body)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  /// One styled span over the plain text: an `@mention`/image token, or a copy-time shell token.
  private enum Span { case mention(String); case shell(ShellTemplate.Kind) }

  // Called from `body`, so the main-actor `MentionStyleCache` access in `styledRun` is safe.
  @MainActor private var composed: Text {
    let ns = plain as NSString

    // Merge mention spans and shell-token spans into one ordered, non-overlapping list.
    var spans: [(range: NSRange, span: Span)] = []
    for range in Self.tokenRanges(in: plain) { spans.append((range, .mention(ns.substring(with: range)))) }
    for expression in ShellTemplate.expressions(in: plain, definedNames: definedVars) {
      spans.append((expression.range, .shell(expression.kind)))
    }
    spans.sort { $0.range.location < $1.range.location }

    var out = Text(verbatim: "")
    var cursor = 0
    for (range, span) in spans {
      if range.location < cursor { continue }   // overlap (rare): keep the first, skip the rest
      if range.location > cursor {
        out = out + Text(verbatim: ns.substring(with: NSRange(location: cursor, length: range.location - cursor)))
      }
      switch span {
      case let .mention(raw): out = out + Self.styledRun(for: raw, zoom: zoom)
      case let .shell(kind): out = out + Self.shellRun(kind, raw: ns.substring(with: range), zoom: zoom, failed: failedCommands)
      }
      cursor = range.location + range.length
    }
    if cursor < ns.length {
      out = out + Text(verbatim: ns.substring(with: NSRange(location: cursor, length: ns.length - cursor)))
    }
    return out
  }

  /// A copy-time shell token, tinted in place — green monospaced for a `$(…)` command, violet for a
  /// variable definition or `$name` reference. The literal syntax is kept (that's why it was chosen);
  /// only its color and weight change (bold), so it reads as live without a background swatch.
  @MainActor private static func shellRun(_ kind: ShellTemplate.Kind, raw: String, zoom: CGFloat, failed: Set<String>) -> Text {
    // Pin to the card's actual body point size (× zoom) — SwiftUI's semantic `.body` is smaller than
    // `Theme.Typography.body` (the user-adjustable editor font), which shrank the tokens.
    let size = Theme.Typography.body.pointSize * zoom
    // A command that failed on the last copy reads amber, so you can see which `$(…)` to fix.
    let didFail = { if case let .command(command) = kind { return failed.contains(command) }; return false }()
    var content = AttributedString(raw)
    content.font = ShellTokenStyle.isCode(kind)
      ? .system(size: size, weight: .bold, design: .monospaced)
      : .system(size: size, weight: .bold)
    content.foregroundColor = Color(nsColor: didFail ? ShellTokenStyle.warning : ShellTokenStyle.tint(for: kind))
    return Text(content)
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

  @MainActor private static func styledRun(for raw: String, zoom: CGFloat) -> Text {
    if raw.hasPrefix("[image:") {
      return Text(Image(systemName: "photo")).foregroundColor(Theme.Palette.placeholder)
    }
    let parsed = AppToken.parse(raw)
    let appID = parsed?.appID ?? raw
    let item = MentionCatalog.all.first { $0.id == appID }
    let isApp = item?.kind == .app
    let label = isApp ? AppToken.label(appID: appID, selection: parsed?.selection) : (item?.label ?? raw)
    let cache = MentionStyleCache.shared
    let color = Color(nsColor: cache.color(for: appID) ?? Theme.Palette.nsAccent)

    var chip = Text(verbatim: "")
    // Build the inline icon at the zoomed size so the brand mark stays crisp alongside the text.
    if let icon = cache.inlineImage(for: appID, side: (15 * zoom).rounded()) {
      chip = chip + Text(Image(nsImage: icon)).baselineOffset(-2 * zoom) + Text(verbatim: "\u{2009}")
    }
    chip = chip + Text(verbatim: label).foregroundColor(color)
    if isApp { chip = chip + Text(verbatim: "\u{2009}\u{25BE}").foregroundColor(color.opacity(0.5)) }
    return chip
  }
}

private struct CanvasLabel: View {
  let text: String
  var zoom: CGFloat = 1

  var body: some View {
    Text(text)
      .font(.system(size: 14 * zoom, weight: .semibold))
      .lineLimit(2)
      .multilineTextAlignment(.center)
      .foregroundStyle(Theme.Palette.body)
      .padding(.horizontal, 9 * zoom)
      .padding(.vertical, 5 * zoom)
      .background(
        // Solid fill — a translucent chip lets its own drop shadow bleed through and muddies it.
        RoundedRectangle(cornerRadius: 7, style: .continuous)
          .fill(Theme.Palette.labelChipFill)
          .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .strokeBorder(Theme.Palette.panelHairline, lineWidth: 1))
      )
      .shadow(color: .black.opacity(0.12), radius: 4, y: 1)
      .padding(8)
      .allowsHitTesting(false)
  }
}

private struct ShapeBox: View {
  let kind: BoxShapeKind

  var body: some View {
    BoxShape(kind: kind)
      .fill(Theme.Palette.elementFill)
      .overlay(BoxShape(kind: kind).stroke(Theme.Palette.elementStroke, lineWidth: 2))
      .shadow(color: Theme.Palette.elementShadow, radius: 10, y: 4)
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
      .stroke(Theme.Palette.elementStroke, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
      .shadow(color: Theme.Palette.elementShadow, radius: 6, y: 3)
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
      .stroke(Theme.Palette.elementStroke, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
      .shadow(color: Theme.Palette.elementShadow, radius: 6, y: 3)
    }
  }
}

private struct ImageObjectPlaceholder: View {
  let path: String?
  @State private var image: NSImage?

  var body: some View {
    Group {
      if let image {
      Image(nsImage: image)
        .resizable()
        .scaledToFill()
        // Clamp to the card frame so `scaledToFill` fills-and-crops within the card instead of
        // overflowing it — the image's rounded border (and the selection ring) then hug the frame.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
          .strokeBorder(Theme.Palette.panelHairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
      } else {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(Theme.Palette.elementFill)
          .overlay {
            VStack(spacing: 8) {
              Image(systemName: "photo")
                .font(.system(size: 24, weight: .medium))
              Text(path.map { ($0 as NSString).lastPathComponent } ?? "Image")
                .font(.caption.weight(.medium))
                .lineLimit(1)
            }
            .foregroundStyle(Theme.Palette.chromeText)
            .padding(10)
          }
          .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(Theme.Palette.chromeDivider, style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])))
          .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
      }
    }
    // `.task(id:)` runs on appear AND whenever `path` changes, and is cancelled on disappear — so a
    // card reloaded from a saved board (or culled and re-added while panning) reliably re-decodes,
    // instead of the old `.onAppear` + stored-path guard silently dropping the result.
    .task(id: path) {
      guard let path else { image = nil; return }
      let loaded: NSImage? = await withCheckedContinuation { continuation in
        CanvasImageCache.shared.load(path: path) { continuation.resume(returning: $0) }
      }
      if !Task.isCancelled { image = loaded }
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
