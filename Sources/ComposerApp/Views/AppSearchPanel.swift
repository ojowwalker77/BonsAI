import SwiftUI
import AppKit

// MARK: - State

/// Drives the inline app-search popover: which app, the live query, results, and the
/// callbacks the editor coordinator wires up to resolve the target chip.
@MainActor
final class AppSearchState: ObservableObject {
  @Published var isOpen = false
  @Published var appID = "@context7"
  @Published var query = ""
  @Published var githubKind: GitHubItemKind = .issue
  @Published var results: [AppSearchResult] = []
  @Published var selectedIndex = 0
  @Published var isLoading = false
  @Published var errorText: String?
  @Published var anchorInView: CGPoint?

  /// Chip range to replace on commit; set by the coordinator when opening.
  var targetRange: NSRange?
  var onCommit: ((AppSearchResult) -> Void)?
  var onCancel: (() -> Void)?

  private let context7 = Context7Service()
  private let github = GitHubService()
  private var searchTask: Task<Void, Never>?

  var app: MentionItem? { MentionCatalog.all.first { $0.id == appID } }
  var isGitHub: Bool { appID == "@github" }
  var placeholder: String { isGitHub ? "Search \(githubKind.shortLabel.lowercased())…" : "Search libraries…" }

  func queryChanged(_ text: String) {
    query = text
    scheduleSearch()
  }

  func setKind(_ kind: GitHubItemKind) {
    guard kind != githubKind else { return }
    githubKind = kind
    selectedIndex = 0
    scheduleSearch()
  }

  func move(_ delta: Int) {
    guard !results.isEmpty else { return }
    selectedIndex = (selectedIndex + delta + results.count) % results.count
  }

  func commitSelected() {
    guard results.indices.contains(selectedIndex) else { return }
    onCommit?(results[selectedIndex])
  }

  func cancel() { onCancel?() }

  private func scheduleSearch() {
    searchTask?.cancel()
    let q = query, app = appID, kind = githubKind
    guard !q.trimmed.isEmpty else {
      results = []; isLoading = false; errorText = nil
      return
    }
    isLoading = true; errorText = nil
    searchTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: 220_000_000)   // debounce keystrokes
      guard let self, !Task.isCancelled else { return }
      do {
        let found = app == "@github"
          ? try await self.github.search(q, kind: kind)
          : try await self.context7.search(q)
        guard !Task.isCancelled, self.query == q, self.appID == app, self.githubKind == kind else { return }
        self.results = found
        self.selectedIndex = 0
        self.isLoading = false
      } catch {
        guard !Task.isCancelled, self.query == q, self.appID == app else { return }
        self.results = []
        self.isLoading = false
        self.errorText = (error as? LocalizedError)?.errorDescription ?? "Search failed."
      }
    }
  }
}

// MARK: - Panel

/// Anchored under the chip; reuses the `@`-menu visual language. Keyboard-driven from
/// the embedded search field, also click-selectable.
struct AppSearchPanel: View {
  @ObservedObject var state: AppSearchState

  var body: some View {
    VStack(spacing: 0) {
      header
      searchField
      Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)
      content
      footer
    }
    .frame(width: 360)
    .background(VisualEffectBackground(material: Theme.Material.menu, blending: .withinWindow, forceDark: true))
    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.menu, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: Theme.Radius.menu, style: .continuous)
        .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
    )
    .shadow(color: Theme.Shadow.menu.color, radius: Theme.Shadow.menu.radius, y: Theme.Shadow.menu.y)
  }

  // MARK: Header (app identity + GitHub Issues/PRs toggle)

  private var header: some View {
    HStack(spacing: 8) {
      appGlyph.frame(width: 16, height: 16)
      Text(state.app?.label ?? "App")
        .font(.system(size: 12.5, weight: .semibold))
        .foregroundStyle(Theme.Palette.body)
      Spacer(minLength: 8)
      if state.isGitHub { kindToggle }
    }
    .padding(.horizontal, 12)
    .frame(height: 36)
  }

  @ViewBuilder
  private var appGlyph: some View {
    if let image = MentionStyleCache.shared.image(for: state.appID) {
      Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
    } else {
      Image(systemName: state.app?.symbol ?? "app").font(.system(size: 12)).foregroundStyle(.secondary)
    }
  }

  private var kindToggle: some View {
    HStack(spacing: 2) {
      ForEach(GitHubItemKind.allCases, id: \.self) { kind in
        let on = state.githubKind == kind
        Text(kind.shortLabel)
          .font(.system(size: 10.5, weight: .medium))
          .foregroundStyle(on ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
          .padding(.horizontal, 8).padding(.vertical, 3)
          .background(RoundedRectangle(cornerRadius: 5).fill(on ? Theme.Palette.accentFill : .clear))
          .contentShape(Rectangle())
          .onTapGesture { state.setKind(kind) }
      }
    }
    .padding(2)
    .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.05)))
  }

  // MARK: Search field

  private var searchField: some View {
    HStack(spacing: 8) {
      Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(.secondary)
      FocusedSearchField(
        text: Binding(get: { state.query }, set: { state.queryChanged($0) }),
        placeholder: state.placeholder,
        onMoveUp: { state.move(-1) },
        onMoveDown: { state.move(1) },
        onCommit: { state.commitSelected() },
        onCancel: { state.cancel() }
      )
      .frame(height: 20)
      if state.isLoading {
        ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 14, height: 14)
      }
    }
    .padding(.horizontal, 12)
    .frame(height: 34)
  }

  // MARK: Content states

  @ViewBuilder
  private var content: some View {
    if let error = state.errorText {
      message(error, symbol: "exclamationmark.triangle")
    } else if state.results.isEmpty {
      if state.query.trimmed.isEmpty {
        message(state.isGitHub ? "Type to search GitHub \(state.githubKind.shortLabel.lowercased())."
                               : "Type to search Context7 libraries.",
                symbol: "sparkle.magnifyingglass")
      } else if state.isLoading {
        message("Searching…", symbol: nil)
      } else {
        message("No results.", symbol: nil)
      }
    } else {
      resultsList
    }
  }

  private var resultsList: some View {
    VStack(spacing: 0) {
      ForEach(Array(state.results.enumerated()), id: \.element.id) { index, result in
        row(result, selected: index == state.selectedIndex)
          .onTapGesture { state.onCommit?(result) }
      }
    }
    .padding(.vertical, 5)
  }

  private func row(_ result: AppSearchResult, selected: Bool) -> some View {
    VStack(alignment: .leading, spacing: 1) {
      Text(result.title)
        .font(.system(size: 12.5, weight: .medium))
        .foregroundStyle(Theme.Palette.body)
        .lineLimit(1)
      if !result.subtitle.isEmpty {
        Text(result.subtitle)
          .font(.system(size: 10.5))
          .foregroundStyle(Theme.Palette.menuDesc)
          .lineLimit(1)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 10).padding(.vertical, 5)
    .background(
      RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
        .fill(selected ? Theme.Palette.accentFill : .clear)
        .padding(.horizontal, 5)
    )
    .contentShape(Rectangle())
  }

  private func message(_ text: String, symbol: String?) -> some View {
    HStack(spacing: 7) {
      if let symbol { Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(.tertiary) }
      Text(text).font(.system(size: 11.5)).foregroundStyle(Theme.Palette.menuDesc)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 14).padding(.vertical, 12)
  }

  private var footer: some View {
    HStack(spacing: 6) {
      keycap("↑↓"); Text("navigate").font(.system(size: 10.5)).foregroundStyle(Theme.Palette.title)
      keycap("↵"); Text("select").font(.system(size: 10.5)).foregroundStyle(Theme.Palette.title)
      keycap("esc"); Text("close").font(.system(size: 10.5)).foregroundStyle(Theme.Palette.title)
      Spacer()
    }
    .padding(.horizontal, 12)
    .frame(height: 26)
    .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1) }
  }

  private func keycap(_ text: String) -> some View {
    Text(text)
      .font(.system(size: 10, weight: .medium))
      .foregroundStyle(.secondary)
      .padding(.horizontal, 5).padding(.vertical, 1.5)
      .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.08)))
  }
}

// MARK: - Focused AppKit search field

/// An `NSTextField` that grabs first responder when it appears (SwiftUI `@FocusState`
/// is unreliable in a non-activating panel) and routes arrow/return/escape to callbacks.
struct FocusedSearchField: NSViewRepresentable {
  @Binding var text: String
  var placeholder: String
  var onMoveUp: () -> Void
  var onMoveDown: () -> Void
  var onCommit: () -> Void
  var onCancel: () -> Void

  func makeNSView(context: Context) -> NSTextField {
    let field = NSTextField()
    field.delegate = context.coordinator
    field.placeholderString = placeholder
    field.isBordered = false
    field.drawsBackground = false
    field.focusRingType = .none
    field.font = .systemFont(ofSize: 13)
    field.textColor = .labelColor
    field.cell?.usesSingleLineMode = true
    field.cell?.wraps = false
    field.cell?.isScrollable = true
    field.lineBreakMode = .byTruncatingTail
    DispatchQueue.main.async { [weak field] in
      guard let field, let window = field.window else { return }
      window.makeFirstResponder(field)
    }
    return field
  }

  func updateNSView(_ field: NSTextField, context: Context) {
    context.coordinator.parent = self
    if field.placeholderString != placeholder { field.placeholderString = placeholder }
    if field.stringValue != text { field.stringValue = text }
  }

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  final class Coordinator: NSObject, NSTextFieldDelegate {
    var parent: FocusedSearchField
    init(_ parent: FocusedSearchField) { self.parent = parent }

    func controlTextDidChange(_ notification: Notification) {
      guard let field = notification.object as? NSTextField else { return }
      parent.text = field.stringValue
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
      switch selector {
      case #selector(NSResponder.moveUp(_:)): parent.onMoveUp(); return true
      case #selector(NSResponder.moveDown(_:)): parent.onMoveDown(); return true
      case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
        parent.onCommit(); return true
      case #selector(NSResponder.cancelOperation(_:)): parent.onCancel(); return true
      default: return false
      }
    }
  }
}
