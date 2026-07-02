import SwiftUI

// MARK: - Intent menu

/// The intent picker — Tighten / Concise / Spec / Checklist — anchored above the pill.
struct RefineMenu: View {
  var onPick: (RefineIntent) -> Void

  var body: some View {
    VStack(spacing: 0) {
      ForEach(RefineIntent.allCases) { intent in
        RefineMenuRow(intent: intent) { onPick(intent) }
      }
    }
    .padding(.vertical, 6)
    .frame(width: 300)
    .composerPopupSurface()
  }
}

private struct RefineMenuRow: View {
  let intent: RefineIntent
  var action: () -> Void
  @State private var hovering = false

  var body: some View {
    Button(action: action) {
      HStack(spacing: 10) {
        Image(systemName: intent.symbol)
          .font(.body)
          .frame(width: 18)
          .foregroundStyle(hovering ? AnyShapeStyle(Theme.Palette.accent) : AnyShapeStyle(Theme.Palette.menuDesc))
        VStack(alignment: .leading, spacing: 1) {
          Text(intent.label).font(.body.weight(.medium)).foregroundStyle(Theme.Palette.body)
          Text(intent.detail).font(.caption).foregroundStyle(Theme.Palette.menuDesc).lineLimit(1)
        }
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 7)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    // No hover background — the trackpad tick plus the icon's accent tint carry hover.
    .onHover { over in
      hovering = over
      if over { Haptics.hover() }
    }
  }
}

// MARK: - Keep / Revert bar

/// Shown after a refine applies. Non-modal: typing keeps the result; Esc reverts.
struct RefineConfirmBar: View {
  let intent: RefineIntent
  var onKeep: () -> Void
  var onRevert: () -> Void

  var body: some View {
    HStack(spacing: 9) {
      Image(systemName: intent.symbol).font(.caption).foregroundStyle(Theme.Palette.accent)
      Text("Refined · \(intent.label)")
        .font(Theme.Typography.actionLabel)
        .foregroundStyle(Theme.Palette.body)
      Divider().frame(height: 14).opacity(0.4)
      RefineBarButton(title: "Revert", prominent: false, action: onRevert)
      RefineBarButton(title: "Keep", prominent: true, action: onKeep)
    }
    .padding(.leading, 14)
    .padding(.trailing, 5)
    .padding(.vertical, 5)
    .floatingGlass(Capsule(style: .continuous))
  }
}

private struct RefineBarButton: View {
  let title: String
  let prominent: Bool
  var action: () -> Void

  var body: some View {
    Button(action: action) {
      Text(title)
        .font(Theme.Typography.actionLabel)
        .foregroundStyle(prominent ? AnyShapeStyle(Theme.Palette.accent) : AnyShapeStyle(Theme.Palette.body))
        .padding(.horizontal, 11)
        .frame(height: Theme.Size.actionBarItemHeight)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { if $0 { Haptics.hover() } }
  }
}
