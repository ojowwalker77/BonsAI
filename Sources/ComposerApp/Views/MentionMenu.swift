import SwiftUI

/// The `@` autocomplete list, anchored just below the caret.
struct MentionMenu: View {
  @ObservedObject var mentions: MentionState

  var body: some View {
    VStack(spacing: 0) {
      VStack(spacing: 0) {
        ForEach(Array(mentions.items.enumerated()), id: \.element.id) { index, item in
          row(item, selected: index == mentions.selectedIndex)
            .onTapGesture { mentions.commitRequested?(item) }
        }
      }
      .padding(.vertical, 5)

      footer
    }
    .frame(width: Theme.Size.menuWidth)
    .background(VisualEffectBackground(material: Theme.Material.menu, blending: .withinWindow, forceDark: true))
    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.menu, style: .continuous))
    .shadow(color: Theme.Shadow.menu.color, radius: Theme.Shadow.menu.radius, y: Theme.Shadow.menu.y)
  }

  private func row(_ item: MentionItem, selected: Bool) -> some View {
    HStack(spacing: 9) {
      Image(systemName: item.symbol)
        .font(.body)
        .foregroundStyle(selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Theme.Palette.menuDesc))
        .frame(width: 16)
      Text(item.id)
        .font(Theme.Typography.menuName)
        .foregroundStyle(Theme.Palette.body)
      Spacer(minLength: 10)
      Text(item.subtitle)
        .font(Theme.Typography.menuDesc)
        .foregroundStyle(selected ? Theme.Palette.body : Theme.Palette.menuDesc)
        .lineLimit(1)
    }
    .padding(.horizontal, 10)
    .frame(height: Theme.Size.menuRowHeight)
    .background(
      RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
        .fill(selected ? Theme.Palette.selectedRowFill : Theme.Palette.rowFill)
        .padding(.horizontal, 5)
    )
    .contentShape(Rectangle())
  }

  private var footer: some View {
    HStack(spacing: 6) {
      keycap("↑↓")
      Text("navigate").font(.caption2).foregroundStyle(Theme.Palette.title)
      keycap("↵")
      Text("insert").font(.caption2).foregroundStyle(Theme.Palette.title)
      Spacer()
    }
    .padding(.horizontal, 12)
    .frame(height: 26)
    .overlay(alignment: .top) {
      Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)
    }
  }

  private func keycap(_ text: String) -> some View {
    Text(text)
      .font(.caption2.weight(.medium))
      .foregroundStyle(.secondary)
      .padding(.horizontal, 5)
      .padding(.vertical, 1.5)
      .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.08)))
  }
}
