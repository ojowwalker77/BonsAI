import SwiftUI
import SwiftData

// MARK: - Rail surface

extension View {
  /// The rail floats over the desktop, so it can't use adaptive Liquid Glass (that turns
  /// white over a light wallpaper). It mirrors the card's own material — HUD vibrancy blurring
  /// the desktop + a matching dark tint — so it reads as the same glass, just detached.
  func railSurface() -> some View {
    let shape = Capsule(style: .continuous)
    return self
      .background {
        ZStack {
          VisualEffectBackground(material: .hudWindow, blending: .behindWindow, state: .active)
          Color.black.opacity(0.6)
        }
      }
      .clipShape(shape)
  }
}

// MARK: - History list

/// The stack of dumps, newest first. Click to jump; hover to delete. A "New dump" row up top.
/// Sizes to its content (no empty void), scrolls past six.
struct HistoryList: View {
  @ObservedObject var store: DumpStore
  var onPick: (PersistentIdentifier) -> Void
  var onDelete: (PersistentIdentifier) -> Void
  var onRename: (PersistentIdentifier, String) -> Void
  var onNew: () -> Void

  private let rowHeight: CGFloat = 38
  private var listHeight: CGFloat {
    min(CGFloat(max(store.dumps.count, 1)), 6) * rowHeight + 12
  }

  var body: some View {
    VStack(spacing: 0) {
      HistoryNewRow(action: onNew)
      Rectangle().fill(Theme.Palette.separator).frame(height: 1)
      ScrollView(.vertical) {
        VStack(spacing: 0) {
          ForEach(store.dumps, id: \.persistentModelID) { dump in
            HistoryRow(
              dump: dump,
              height: rowHeight,
              isCurrent: dump.persistentModelID == store.currentID,
              onPick: { onPick(dump.persistentModelID) },
              onDelete: store.dumps.count > 1 ? { onDelete(dump.persistentModelID) } : nil,
              onRename: { onRename(dump.persistentModelID, $0) }
            )
          }
        }
        .padding(.vertical, 6)
      }
      .scrollIndicators(.never)
      .frame(height: listHeight)
    }
    .frame(width: 320)
    .composerPopupSurface()
  }
}

private struct HistoryNewRow: View {
  var action: () -> Void
  @State private var hovering = false

  var body: some View {
    Button(action: action) {
      HStack(spacing: 10) {
        Image(systemName: "plus").font(.body.weight(.semibold)).frame(width: 20)
        Text("New board").font(.body.weight(.medium))
        Spacer(minLength: 0)
        Text("⌘N").font(.caption.weight(.medium)).foregroundStyle(.tertiary)
      }
      .foregroundStyle(hovering ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Theme.Palette.body))
      .padding(.horizontal, 14)
      .frame(height: 42)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
  }
}

private struct HistoryRow: View {
  let dump: Dump
  let height: CGFloat
  let isCurrent: Bool
  var onPick: () -> Void
  var onDelete: (() -> Void)?
  var onRename: (String) -> Void
  @State private var hovering = false
  @State private var confirmingDelete = false
  @State private var isRenaming = false
  @State private var draftName = ""
  @FocusState private var nameFieldFocused: Bool

  var body: some View {
    Group {
      if isRenaming { renamingRow } else { pickRow }
    }
    .onHover { hovering = $0; if !$0 { confirmingDelete = false } }
  }

  // MARK: Normal (pick / hover-actions) row

  private var pickRow: some View {
    Button(action: onPick) {
      HStack(spacing: 10) {
        indicator
        Text(dump.title.isEmpty ? "Empty draft" : dump.title)
          .font(.body)
          .foregroundStyle(dump.title.isEmpty ? Theme.Palette.menuDesc : Theme.Palette.body)
          .lineLimit(1)
        Spacer(minLength: 8)
        trailing
      }
      .padding(.horizontal, 12)
      .frame(height: height)
      .background(rowBackground)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .contextMenu { Button("Rename", action: beginRename) }
  }

  @ViewBuilder
  private var trailing: some View {
    if hovering && confirmingDelete, let onDelete {
      // Second click confirms — a deleted board can't be recovered.
      Button(action: onDelete) {
        Text("Delete?")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.white)
          .padding(.horizontal, 8).frame(height: 20)
          .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.red.opacity(0.85)))
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help("Click again to permanently delete this board")
    } else if hovering {
      HStack(spacing: 2) {
        rowIconButton("pencil", help: "Rename board", action: beginRename)
        // The last board can't be deleted, so it has no ✕ — but it can still be renamed.
        if onDelete != nil {
          rowIconButton("xmark", help: "Delete board") { confirmingDelete = true }
        }
      }
    } else {
      Text(relativeDumpTime(dump.updatedAt))
        .font(.caption.monospacedDigit())
        .foregroundStyle(Theme.Palette.title)
    }
  }

  private func rowIconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: symbol).font(.caption.weight(.bold)).foregroundStyle(.secondary)
        .frame(width: 20, height: 20).contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(help)
  }

  // MARK: Inline rename row

  private var renamingRow: some View {
    HStack(spacing: 10) {
      indicator
      TextField("Board name", text: $draftName)
        .textFieldStyle(.plain)
        .font(.body)
        .foregroundStyle(Theme.Palette.body)
        .focused($nameFieldFocused)
        .onSubmit(commitRename)
        .onExitCommand(perform: cancelRename)
      Spacer(minLength: 8)
    }
    .padding(.horizontal, 12)
    .frame(height: height)
    .background(rowBackground)
    // Defer a runloop tick: focusing straight from onAppear can miss while the overlay animates in.
    .onAppear { DispatchQueue.main.async { nameFieldFocused = true } }
    // Clicking away (focus leaves the field) commits, so the rename isn't lost.
    .onChange(of: nameFieldFocused) { _, focused in if !focused { commitRename() } }
  }

  private func beginRename() {
    draftName = dump.title
    confirmingDelete = false
    isRenaming = true
  }

  private func commitRename() {
    guard isRenaming else { return }   // guard so the focus-loss path doesn't re-fire after a cancel
    isRenaming = false
    onRename(draftName)
  }

  private func cancelRename() { isRenaming = false }

  // MARK: Shared chrome

  private var indicator: some View {
    Circle().fill(isCurrent ? Color.accentColor : Color.clear).frame(width: 6, height: 6)
  }

  private var rowBackground: some View {
    RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
      .fill(isCurrent ? Theme.Palette.selectedRowFill : (hovering ? Theme.Palette.rowFill : Color.clear))
      .padding(.horizontal, 6)
  }
}

/// Compact relative time — "now", "5m", "2h", "3d", then a date.
func relativeDumpTime(_ date: Date) -> String {
  let seconds = Date().timeIntervalSince(date)
  if seconds < 60 { return "now" }
  if seconds < 3600 { return "\(Int(seconds / 60))m" }
  if seconds < 86_400 { return "\(Int(seconds / 3600))h" }
  let days = Int(seconds / 86_400)
  if days < 7 { return "\(days)d" }
  let formatter = DateFormatter()
  formatter.dateFormat = "MMM d"
  return formatter.string(from: date)
}
