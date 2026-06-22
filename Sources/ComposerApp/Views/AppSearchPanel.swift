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
  @Published var hasSearched = false
  @Published var errorText: String?
  @Published var anchorInView: CGPoint?

  /// Chip range to replace on commit; set by the coordinator when opening.
  var targetRange: NSRange?
  var onCommit: ((AppSearchResult) -> Void)?
  var onCancel: (() -> Void)?

  private var searchTask: Task<Void, Never>?

  var app: MentionItem? { MentionCatalog.all.first { $0.id == appID } }
  var connector: (any ComposerAppConnector)? { AppConnectorRegistry.connector(for: appID) }
  var context: AppSearchContext { AppSearchContext(githubKind: githubKind) }
  var isGitHub: Bool { connector?.supportsGitHubKindToggle == true }
  var placeholder: String { connector?.placeholder(context: context) ?? "Search…" }
  var idleMessage: String { connector?.idleMessage(context: context) ?? "Type to search." }
  var noResultsMessage: String { connector?.noResultsMessage(query: query.trimmed, context: context) ?? "No results." }

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

  func reload() {
    scheduleSearch(debounce: false)
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

  private func scheduleSearch(debounce: Bool = true) {
    searchTask?.cancel()
    let q = query.trimmed, app = appID, kind = githubKind, context = AppSearchContext(githubKind: githubKind)
    guard let connector = AppConnectorRegistry.connector(for: app) else {
      results = []; isLoading = false; hasSearched = false; errorText = "Unknown app connector."
      return
    }
    guard q.count >= connector.minimumQueryLength else {
      results = []; isLoading = false; hasSearched = false; errorText = nil
      return
    }
    isLoading = true; hasSearched = false; errorText = nil
    searchTask = Task { [weak self] in
      if debounce { try? await Task.sleep(nanoseconds: 220_000_000) }   // debounce keystrokes
      guard let self, !Task.isCancelled else { return }
      do {
        let found = try await connector.search(q, context: context)
        guard !Task.isCancelled, self.query.trimmed == q, self.appID == app, self.githubKind == kind else { return }
        self.results = found
        self.selectedIndex = 0
        self.isLoading = false
        self.hasSearched = true
      } catch {
        guard !Task.isCancelled, self.query.trimmed == q, self.appID == app else { return }
        self.results = []
        self.isLoading = false
        self.hasSearched = true
        self.errorText = UserFacingError.message(for: error, while: "\(self.app?.title ?? "Connector") search")
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
      searchRow
      Rectangle().fill(Theme.Palette.separator).frame(height: 1)
      content
        // A stable floor so idle / loading / no-results never collapse to a thin sliver, and the
        // panel resize between states animates instead of snapping. Every connector feels the same.
        .frame(minHeight: 60, alignment: .top)
      footer
    }
    .frame(width: 360)
    .animation(Theme.Motion.accessory, value: state.results.isEmpty)
    .composerPopupSurface()
  }

  @ViewBuilder
  private var appGlyph: some View {
    if let image = MentionStyleCache.shared.image(for: state.appID) {
      Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
    } else {
      Image(systemName: state.app?.symbol ?? "app").font(.body).foregroundStyle(.secondary)
    }
  }

  private var kindToggle: some View {
    HStack(spacing: 2) {
      ForEach(GitHubItemKind.allCases, id: \.self) { kind in
        let on = state.githubKind == kind
        Text(kind.shortLabel)
          .font(.caption.weight(.medium))
          .foregroundStyle(on ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
          .padding(.horizontal, 8).padding(.vertical, 3)
          .background(RoundedRectangle(cornerRadius: 5).fill(on ? Theme.Palette.accentFill : .clear))
          .contentShape(Rectangle())
          .onTapGesture { state.setKind(kind) }
      }
    }
    .padding(2)
    .background(RoundedRectangle(cornerRadius: 7).fill(Theme.Palette.segmentedFill))
  }

  // MARK: Search row (brand icon leads the field; identity without a title band)

  private var searchRow: some View {
    HStack(spacing: 9) {
      appGlyph.frame(width: 17, height: 17)
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
      if state.isGitHub { kindToggle }
    }
    .padding(.horizontal, 13)
    .frame(height: 42)
  }

  // MARK: Content states

  @ViewBuilder
  private var content: some View {
    if let error = state.errorText {
      message(error, symbol: "exclamationmark.triangle")
    } else if state.results.isEmpty {
      if state.isLoading {
        message("Searching…", symbol: nil)
      } else if state.hasSearched {
        message(state.noResultsMessage, symbol: nil)
      } else {
        message(state.idleMessage, symbol: "sparkle.magnifyingglass")
      }
    } else {
      resultsList
    }
  }

  private var resultsList: some View {
    ScrollViewReader { proxy in
      ScrollView(.vertical) {
        VStack(spacing: 0) {
          ForEach(Array(state.results.enumerated()), id: \.element.id) { index, result in
            row(result, selected: index == state.selectedIndex)
              .id(index)
              .onTapGesture { state.onCommit?(result) }
          }
        }
        .padding(.vertical, 5)
      }
      .scrollIndicators(.never)
      .frame(maxHeight: resultsMaxHeight)
      .onChange(of: state.selectedIndex) { _, index in
        withAnimation(Theme.Motion.accessory) { proxy.scrollTo(index, anchor: .center) }
      }
      .onAppear { proxy.scrollTo(state.selectedIndex, anchor: .center) }
    }
  }

  private var resultsMaxHeight: CGFloat {
    let rows = min(CGFloat(max(state.results.count, 1)), Theme.Size.menuMaxVisibleRows)
    return rows * 46 + 10
  }

  private func row(_ result: AppSearchResult, selected: Bool) -> some View {
    VStack(alignment: .leading, spacing: 1) {
      Text(result.title)
        .font(.body.weight(.medium))
        .foregroundStyle(Theme.Palette.body)
        .lineLimit(1)
      if !result.subtitle.isEmpty {
        Text(result.subtitle)
          .font(.caption)
          .foregroundStyle(Theme.Palette.menuDesc)
          .lineLimit(1)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 12).padding(.vertical, 6)
    .background(
      RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
        .fill(selected ? Theme.Palette.selectedRowFill : Color.clear)
        .padding(.horizontal, 6)
    )
    .contentShape(Rectangle())
  }

  private func message(_ text: String, symbol: String?) -> some View {
    HStack(spacing: 7) {
      if let symbol { Image(systemName: symbol).font(.caption).foregroundStyle(.tertiary) }
      Text(text).font(.caption).foregroundStyle(Theme.Palette.menuDesc)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 14).padding(.vertical, 12)
  }

  private var footer: some View {
    HStack(spacing: 6) {
      keycap("↑↓"); Text("navigate").font(.caption2).foregroundStyle(Theme.Palette.title)
      keycap("↵"); Text("select").font(.caption2).foregroundStyle(Theme.Palette.title)
      keycap("esc"); Text("close").font(.caption2).foregroundStyle(Theme.Palette.title)
      Spacer()
    }
    .padding(.horizontal, 12)
    .frame(height: 26)
    .overlay(alignment: .top) { Rectangle().fill(Theme.Palette.separator).frame(height: 1) }
  }

  private func keycap(_ text: String) -> some View {
    Text(text)
      .font(.caption2.weight(.medium))
      .foregroundStyle(.secondary)
      .padding(.horizontal, 5).padding(.vertical, 1.5)
      .background(RoundedRectangle(cornerRadius: 4).fill(Theme.Palette.keycapFill))
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
    field.font = Theme.Typography.body
    field.textColor = Theme.nsBodyText
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
    field.font = Theme.Typography.body
    field.textColor = Theme.nsBodyText
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
