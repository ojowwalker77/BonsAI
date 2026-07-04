import SwiftUI

/// The promotion seam's one affordance: a small floating glass chip that appears near a card when
/// the canvas recognizes what that card could become (freehand→shape, text→equation, text→cards,
/// axes→graph). Clicking it promotes in a single undo step, preserving the card's id, tint, and
/// placement — "continuity of matter". It whispers, never shouts: no hover background fill (the
/// trackpad tick plus a foreground brightness bump stand in, the house rule for chrome), and it
/// auto-dismisses so it never lingers as clutter.
///
/// One offer at most is live at a time; `ComposerCanvas` owns the lifecycle (arm, place, dismiss).

/// What a live promotion would do, and how to render its chip. The payload is kind-specific so the
/// canvas can run the right `BoardViewModel` mutation on click.
struct PromotionOffer: Equatable {
  enum Kind: Equatable {
    /// A committed freehand stroke the recognizer read as a clean shape/line/arrow.
    case freehandToShape(ShapeRecognizer.Kind)
    /// A committed text card whose ink is math-like LaTeX.
    case textToEquation
    /// A committed text card that reads as a bullet list.
    case textToCards
    /// A freshly drawn line/arrow that found a perpendicular partner — an axis pair.
    case arrowsToGraph
  }

  /// The card the chip hangs over and promotes.
  let cardID: UUID
  let kind: Kind
  /// Short verb label, e.g. "Make rectangle".
  let label: String
  /// SF Symbol matching the target — the same symbols `CanvasToolbar` uses for each tool.
  let symbol: String
}

extension ShapeRecognizer.Kind {
  /// The tool symbol + label a recognized freehand shape promotes into — kept in lockstep with the
  /// symbols `CanvasToolbar` shows for each tool so the chip previews the same icon the tool wears.
  var promotionSymbol: String {
    switch self {
    case .rectangle: "rectangle"
    case .ellipse: "circle"
    case .diamond: "diamond"
    case .line: "line.diagonal"
    case .arrow: "arrow.up.right"
    }
  }

  var promotionLabel: String {
    switch self {
    case .rectangle: "Make rectangle"
    case .ellipse: "Make ellipse"
    case .diamond: "Make diamond"
    case .line: "Make line"
    case .arrow: "Make arrow"
    }
  }

  /// True for the `.arrow` case — lets the freehand promotion pick the arrow vs line kind without
  /// re-destructuring the associated points.
  var isArrow: Bool {
    if case .arrow = self { return true }
    return false
  }
}

/// The chip view itself: a compact accent pill built exactly like the app's other small glass chips
/// (`composerPopupSurface`, `WindowChrome.labelFont`, accent icon+label). Hover brightens the
/// foreground and ticks the trackpad — never a background fill (guardrail).
struct PromotionChip: View {
  let offer: PromotionOffer
  let action: () -> Void

  @State private var hovering = false

  var body: some View {
    Button(action: action) {
      HStack(spacing: 6) {
        Image(systemName: offer.symbol)
          .font(.system(size: 12, weight: .medium))
        Text(offer.label)
          .font(WindowChrome.labelFont)
          .lineLimit(1)
      }
      .foregroundStyle(Theme.Palette.accent)
      .brightness(hovering ? 0.16 : 0)
      .padding(.horizontal, 10)
      .padding(.vertical, 5)
      .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .composerPopupSurface(radius: WindowChrome.radius)
    // No hover fill anywhere in the chrome — the trackpad tick plus the glyph brightening above
    // are the hover feedback.
    .onHover { over in
      hovering = over
      if over { Haptics.hover() }
    }
    .animation(.easeOut(duration: 0.12), value: hovering)
    .help(offer.label)
  }
}
