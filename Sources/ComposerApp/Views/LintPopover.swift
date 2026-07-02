import SwiftUI

/// The card that appears when you hover an underlined ambiguity. Shows the one
/// clarifying question, offers one-tap drop-in fixes, and can escalate to the chat agent.
/// Styled to match `MentionMenu` / `SelectionActionBar` so it reads as part of the app.
struct LintPopover: View {
  let flag: LintFlag
  /// The engine the "Refine with …" escalation runs on (the resolved Chat Agent pick). `nil` when no
  /// engine is enabled + installed — the escalate row is hidden, leaving just the question + fixes.
  let escalationEngine: HeadlessEngine?
  var onPick: (String) -> Void
  var onEscalate: () -> Void
  /// Reports its own hover so the coordinator can keep it alive across the gap.
  var onHover: (Bool) -> Void

  @State private var shown = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header

      if !flag.suggestions.isEmpty {
        hairline
        VStack(spacing: 0) {
          ForEach(flag.suggestions, id: \.self) { suggestion in
            suggestionRow(suggestion)
          }
        }
        .padding(.vertical, 4)
      }

      if let engine = escalationEngine {
        hairline
        escalateButton(engine)
      }
    }
    .frame(width: 300, alignment: .leading)
    .composerPopupSurface()
    .scaleEffect(shown ? 1 : 0.96, anchor: .topLeading)
    .opacity(shown ? 1 : 0)
    .onAppear { withAnimation(Theme.Motion.accessory) { shown = true } }
    .onHover { onHover($0) }
  }

  // MARK: Pieces

  private var header: some View {
    HStack(alignment: .top, spacing: 9) {
      Image(systemName: flag.kind.symbol)
        .font(.body.weight(.medium))
        .foregroundStyle(flag.kind.tint.opacity(0.72))
        .frame(width: 16)
      VStack(alignment: .leading, spacing: 2) {
        Text(flag.question)
          .font(.body.weight(.medium))
          .foregroundStyle(Theme.Palette.body)
          .fixedSize(horizontal: false, vertical: true)
        Text(flag.kind.label)
          .font(.caption)
          .foregroundStyle(Theme.Palette.menuDesc)
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
  }

  private func suggestionRow(_ suggestion: String) -> some View {
    Button { onPick(suggestion) } label: {
      HStack(spacing: 8) {
        Image(systemName: "arrow.turn.down.right")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
          .frame(width: 14)
        Text(suggestion)
          .font(.body)
          .foregroundStyle(Theme.Palette.body)
          .multilineTextAlignment(.leading)
          .fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
      .contentShape(Rectangle())
    }
    .buttonStyle(HoverButtonStyle())
  }

  private func escalateButton(_ engine: HeadlessEngine) -> some View {
    Button(action: onEscalate) {
      HStack(spacing: 7) {
        EngineLogo(engine: engine)
        Text("Refine with \(engine.title)").font(Theme.Typography.actionLabel)
        Spacer(minLength: 0)
      }
      .foregroundStyle(Theme.Palette.body)
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .contentShape(Rectangle())
    }
    .buttonStyle(HoverButtonStyle())
  }

  private var hairline: some View {
    Rectangle().fill(Theme.Palette.separator).frame(height: 1)
  }
}
