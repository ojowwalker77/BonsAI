import SwiftUI

/// The card that appears when you hover an underlined ambiguity. Shows the one
/// clarifying question, offers one-tap drop-in fixes, and can escalate to Claude.
/// Styled to match `MentionMenu` / `SelectionActionBar` so it reads as part of the app.
struct LintPopover: View {
  let flag: LintFlag
  var onPick: (String) -> Void
  var onAskClaude: () -> Void
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

      hairline
      askClaudeButton
    }
    .frame(width: 300, alignment: .leading)
    .background(VisualEffectBackground(material: Theme.Material.menu, blending: .withinWindow, forceDark: true))
    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.menu, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: Theme.Radius.menu, style: .continuous)
        .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
    )
    .shadow(color: Theme.Shadow.menu.color, radius: Theme.Shadow.menu.radius, y: Theme.Shadow.menu.y)
    .scaleEffect(shown ? 1 : 0.96, anchor: .topLeading)
    .opacity(shown ? 1 : 0)
    .onAppear { withAnimation(Theme.Motion.accessory) { shown = true } }
    .onHover { onHover($0) }
  }

  // MARK: Pieces

  private var header: some View {
    HStack(alignment: .top, spacing: 9) {
      Image(systemName: flag.kind.symbol)
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(flag.kind.tint)
        .frame(width: 16)
      VStack(alignment: .leading, spacing: 2) {
        Text(flag.question)
          .font(.system(size: 12.5, weight: .medium))
          .foregroundStyle(Theme.Palette.body)
          .fixedSize(horizontal: false, vertical: true)
        Text(flag.kind.label)
          .font(.system(size: 10.5))
          .foregroundStyle(Theme.Palette.title)
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
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(.secondary)
          .frame(width: 14)
        Text(suggestion)
          .font(.system(size: 12.5))
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

  private var askClaudeButton: some View {
    Button(action: onAskClaude) {
      HStack(spacing: 7) {
        Image(systemName: "sparkles").font(.system(size: 11, weight: .medium))
        Text("Refine with Claude").font(.system(size: 11.5, weight: .medium))
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
    Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)
  }
}
