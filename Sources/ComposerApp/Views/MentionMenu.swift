import SwiftUI

/// The `@` autocomplete list, anchored just below the caret.
struct MentionMenu: View {
  @ObservedObject var mentions: MentionState

  var body: some View {
    VStack(spacing: 0) {
      ScrollViewReader { proxy in
        ScrollView(.vertical) {
          VStack(spacing: 0) {
            ForEach(Array(mentions.items.enumerated()), id: \.element.id) { index, item in
              row(item, selected: index == mentions.selectedIndex)
                .id(index)
                .onTapGesture { mentions.commitRequested?(item) }
            }
          }
          .padding(.vertical, 5)
        }
        .scrollIndicators(.never)
        .frame(maxHeight: listMaxHeight)
        .onChange(of: mentions.selectedIndex) { _, index in
          withAnimation(Theme.Motion.accessory) { proxy.scrollTo(index, anchor: .center) }
        }
        .onAppear { proxy.scrollTo(mentions.selectedIndex, anchor: .center) }
      }

      footer
    }
    .frame(width: Theme.Size.menuWidth)
    .composerPopupSurface()
  }

  private var listMaxHeight: CGFloat {
    let rows = min(CGFloat(max(mentions.items.count, 1)), Theme.Size.menuMaxVisibleRows)
    return rows * Theme.Size.menuRowHeight + 10
  }

  private func row(_ item: MentionItem, selected: Bool) -> some View {
    HStack(spacing: 9) {
      Image(systemName: item.symbol)
        .font(.body)
        .foregroundStyle(selected ? AnyShapeStyle(Theme.Palette.accent) : AnyShapeStyle(Theme.Palette.menuDesc))
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
    .padding(.horizontal, 12)
    .frame(height: Theme.Size.menuRowHeight)
    .background(
      RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
        .fill(selected ? Theme.Palette.selectedRowFill : Color.clear)
        .padding(.horizontal, 6)
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
      Rectangle().fill(Theme.Palette.separator).frame(height: 1)
    }
  }

  private func keycap(_ text: String) -> some View {
    Text(text)
      .font(.caption2.weight(.medium))
      .foregroundStyle(.secondary)
      .padding(.horizontal, 5)
      .padding(.vertical, 1.5)
      .background(RoundedRectangle(cornerRadius: 4).fill(Theme.Palette.keycapFill))
  }
}
