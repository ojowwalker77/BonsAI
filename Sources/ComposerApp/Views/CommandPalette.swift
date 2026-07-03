import SwiftUI
import SwiftData

// MARK: - Command model

/// A board-level action surfaced in the ⌘K palette. `run` calls straight into the canvas's
/// existing handlers, so the palette is just another entry point — never a parallel code path.
struct PaletteCommand: Identifiable {
  let id: String
  let title: String
  var subtitle: String? = nil
  let symbol: String
  var shortcut: String? = nil
  let run: () -> Void
}

// MARK: - Fuzzy ranking

/// Case-insensitive ranking for palette entries: exact > prefix > substring > subsequence, with a
/// consecutive-run bonus. Returns nil when `query` isn't even a subsequence of `text`. An empty
/// query matches everything (score 0) so the idle palette shows its full list. Mirrors the
/// connector scorers (`BrowserService`/`FinderService`) so search feels the same across the app.
func paletteFuzzyScore(_ text: String, query: String) -> Int? {
  let needle = query.lowercased().filter { !$0.isWhitespace }
  guard !needle.isEmpty else { return 0 }
  let hay = text.lowercased()
  guard !hay.isEmpty else { return nil }
  if hay == needle { return 10_000 - hay.count }
  if hay.hasPrefix(needle) { return 8_500 - hay.count }
  if let range = hay.range(of: needle) {
    let distance = hay.distance(from: hay.startIndex, to: range.lowerBound)
    return 7_000 - distance * 8 - hay.count
  }
  let haystack = Array(hay)
  var cursor = 0, last = -1, streak = 0, score = 2_000
  for ch in needle {
    var found: Int?
    while cursor < haystack.count {
      if haystack[cursor] == ch { found = cursor; cursor += 1; break }
      cursor += 1
    }
    guard let index = found else { return nil }
    if index == last + 1 { streak += 1; score += 15 * streak } else { streak = 0; score -= 2 }
    last = index
  }
  return score - haystack.count
}

// MARK: - Palette

/// The ⌘K spotlight: fuzzy-search every board by title and run buried board-level actions, both
/// fully from the keyboard. Boards come first (the common case — "where was that prompt about X")
/// then actions. A transient overlay on the board window; it never touches the two-window geometry.
struct CommandPalette: View {
  @ObservedObject var store: DumpStore
  let commands: [PaletteCommand]
  var onPickBoard: (PersistentIdentifier) -> Void
  var onRunCommand: (PaletteCommand) -> Void
  var onDismiss: () -> Void

  @State private var query = ""
  @State private var selection = 0
  @State private var hovered: Int? = nil

  /// With no query, the palette leads with the few most-recent boards rather than the whole stack.
  private let idleBoardLimit = 6
  private let rowHeight: CGFloat = 36
  private let headerHeight: CGFloat = 26
  private let maxVisibleRows = 7
  /// Row content aligns to this inset; the section headers share it so labels sit over their rows.
  private let contentInset: CGFloat = 8
  /// Fixed leading icon slot — every glyph is optically centered in the same 24pt column.
  private let iconSlot: CGFloat = 24

  var body: some View {
    VStack(spacing: 0) {
      searchRow
      Rectangle().fill(Theme.Palette.panelHairline).frame(height: 1)
      results
    }
    .frame(width: 560)
    .composerPopupSurface()
    .animation(Theme.Motion.accessory, value: rowCount)
  }

  // MARK: Filtered data

  private var filteredBoards: [Dump] {
    let trimmed = query.trimmed
    guard !trimmed.isEmpty else { return Array(store.dumps.prefix(idleBoardLimit)) }
    return store.dumps.enumerated()
      .compactMap { index, dump -> (Dump, Int, Int)? in
        guard let score = paletteFuzzyScore(dump.title, query: trimmed) else { return nil }
        return (dump, score, index)
      }
      .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.2 < $1.2 }
      .map(\.0)
  }

  private var filteredCommands: [PaletteCommand] {
    let trimmed = query.trimmed
    guard !trimmed.isEmpty else { return commands }
    return commands.enumerated()
      .compactMap { index, command -> (PaletteCommand, Int, Int)? in
        let haystack = command.subtitle.map { "\(command.title) \($0)" } ?? command.title
        guard let score = paletteFuzzyScore(haystack, query: trimmed) else { return nil }
        return (command, score, index)
      }
      .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.2 < $1.2 }
      .map(\.0)
  }

  private var rowCount: Int { filteredBoards.count + filteredCommands.count }

  /// `selection` can briefly point past the list as the query narrows; clamp before every read.
  private var safeSelection: Int { rowCount == 0 ? 0 : min(max(selection, 0), rowCount - 1) }

  // MARK: Search row

  private var searchRow: some View {
    HStack(spacing: 10) {
      Image(systemName: "magnifyingglass")
        .font(.system(size: 15, weight: .regular))
        .foregroundStyle(Theme.Palette.placeholder)
        .frame(width: iconSlot)
      FocusedSearchField(
        text: Binding(get: { query }, set: { query = $0; selection = 0 }),
        placeholder: "Search boards and actions…",
        // System font, not the editor font: the palette is chrome (its rows are all system fonts),
        // and the custom app fonts' lying vertical metrics clip ascenders in NSTextField.
        font: .systemFont(ofSize: 15),
        onMoveUp: { move(-1) },
        onMoveDown: { move(1) },
        onCommit: { commit() },
        onCancel: { onDismiss() }
      )
      .frame(height: 28)
    }
    .padding(.horizontal, contentInset + 6)
    .frame(height: 44)
  }

  // MARK: Results

  @ViewBuilder
  private var results: some View {
    if rowCount == 0 {
      HStack(spacing: 8) {
        Image(systemName: "magnifyingglass")
          .font(.system(size: 13))
          .foregroundStyle(Theme.Palette.placeholder)
          .frame(width: iconSlot)
        Text("No matches").font(Theme.Typography.menuName).foregroundStyle(Theme.Palette.placeholder)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, contentInset).padding(.vertical, 14)
    } else {
      ScrollViewReader { proxy in
        ScrollView(.vertical) {
          VStack(alignment: .leading, spacing: 2) {
            if !filteredBoards.isEmpty {
              sectionHeader("Boards")
              ForEach(Array(filteredBoards.enumerated()), id: \.element.persistentModelID) { index, dump in
                boardRow(dump, selected: safeSelection == index)
                  .brightness(hovered == index && safeSelection != index ? 0.12 : 0)
                  .id(index)
                  .onTapGesture { onPickBoard(dump.persistentModelID) }
                  .onHover { inside in updateHover(index, inside) }
              }
            }
            if !filteredCommands.isEmpty {
              sectionHeader("Actions")
              ForEach(Array(filteredCommands.enumerated()), id: \.element.id) { index, command in
                let row = filteredBoards.count + index
                commandRow(command, selected: safeSelection == row)
                  .brightness(hovered == row && safeSelection != row ? 0.12 : 0)
                  .id(row)
                  .onTapGesture { onRunCommand(command) }
                  .onHover { inside in updateHover(row, inside) }
              }
            }
          }
          .padding(.horizontal, contentInset)
          .padding(.vertical, 6)
        }
        .scrollIndicators(.never)
        .frame(maxHeight: listMaxHeight)
        .onChange(of: safeSelection) { _, index in
          withAnimation(Theme.Motion.accessory) { proxy.scrollTo(index, anchor: .center) }
        }
      }
    }
  }

  /// Hover paints no background (guardrail) — it only brightens the row's foreground and, on enter,
  /// fires the trackpad tick that stands in for a hover fill everywhere in the chrome.
  private func updateHover(_ index: Int, _ inside: Bool) {
    if inside {
      if hovered != index { Haptics.hover() }
      hovered = index
    } else if hovered == index {
      hovered = nil
    }
  }

  /// Sized to the exact content height (capped at `maxVisibleRows`), so the scroll area never
  /// leaves empty glass below a short list — a greedy `ScrollView` fills whatever it's offered.
  private var listMaxHeight: CGFloat {
    let visibleRows = min(rowCount, maxVisibleRows)
    let headers = (filteredBoards.isEmpty ? 0 : 1) + (filteredCommands.isEmpty ? 0 : 1)
    return CGFloat(visibleRows) * (rowHeight + 2) + CGFloat(headers) * headerHeight + 12
  }

  private func sectionHeader(_ text: String) -> some View {
    Text(text.uppercased())
      .font(.system(size: 10.5, weight: .semibold))
      .tracking(0.4)
      .foregroundStyle(Theme.Palette.placeholder)
      .padding(.leading, rowContentInset)
      .padding(.top, 12)
      .padding(.bottom, 4)
  }

  /// Text inside a row starts after the icon slot; headers align to the same x so a label sits
  /// directly over its rows' titles.
  private var rowContentInset: CGFloat { 8 + iconSlot + 8 }

  private func boardRow(_ dump: Dump, selected: Bool) -> some View {
    let isEmpty = dump.title.isEmpty
    return HStack(spacing: 8) {
      Circle()
        .fill(dump.persistentModelID == store.currentID ? Theme.Palette.accent : Color.clear)
        .frame(width: 6, height: 6)
        .frame(width: iconSlot)
      Text(isEmpty ? "Empty draft" : dump.title)
        .font(Theme.Typography.menuName)
        .foregroundStyle(isEmpty ? Theme.Palette.placeholder : Theme.Palette.body)
        .lineLimit(1)
      Spacer(minLength: 8)
      Text(relativeDumpTime(dump.updatedAt))
        .font(.system(size: 11).monospacedDigit())
        .foregroundStyle(Theme.Palette.placeholder)
    }
    .padding(.horizontal, 8)
    .frame(height: rowHeight)
    .background(rowFill(selected))
    .contentShape(Rectangle())
  }

  private func commandRow(_ command: PaletteCommand, selected: Bool) -> some View {
    HStack(spacing: 8) {
      Image(systemName: command.symbol)
        .font(.system(size: 14, weight: .medium))
        .foregroundStyle(selected ? Theme.Palette.accent : Theme.Palette.placeholder)
        .frame(width: iconSlot)
      Text(command.title)
        .font(Theme.Typography.menuName)
        .foregroundStyle(Theme.Palette.body)
        .lineLimit(1)
        .layoutPriority(1)
      if let subtitle = command.subtitle {
        Text(subtitle)
          .font(.system(size: 11.5))
          .foregroundStyle(Theme.Palette.placeholder)
          .lineLimit(1)
          .truncationMode(.tail)
      }
      Spacer(minLength: 8)
      if let shortcut = command.shortcut {
        Text(shortcut)
          .font(.system(size: 11, design: .monospaced))
          .foregroundStyle(Theme.Palette.placeholder)
          .lineLimit(1)
          .fixedSize()
      }
    }
    .padding(.horizontal, 8)
    .frame(height: rowHeight)
    .background(rowFill(selected))
    .contentShape(Rectangle())
  }

  private func rowFill(_ selected: Bool) -> some View {
    RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
      .fill(selected ? Theme.Palette.accent.opacity(0.14) : Color.clear)
  }

  // MARK: Keyboard

  private func move(_ delta: Int) {
    guard rowCount > 0 else { return }
    selection = (safeSelection + delta + rowCount) % rowCount
  }

  private func commit() {
    guard rowCount > 0 else { return }
    let index = safeSelection
    let boards = filteredBoards
    if index < boards.count {
      onPickBoard(boards[index].persistentModelID)
    } else {
      onRunCommand(filteredCommands[index - boards.count])
    }
  }
}
