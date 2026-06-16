import SwiftUI

struct SettingsView: View {
  private let shortcuts: [(String, String)] = [
    ("Summon / hide Composer", "⌃⌥Space"),
    ("Refine selection", "select text → Claude / Codex"),
    ("Insert a connector", "type @"),
    ("Copy self-contained text", "⇧⌘C"),
    ("Dismiss", "Esc"),
  ]

  /// Republished whenever a brand icon/color lands so the Apps list redraws.
  @StateObject private var appIcons = AppIconStore()

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Composer").font(.system(size: 15, weight: .semibold))
        Text("A menu-bar scratchpad for drafting prompts.")
          .font(.system(size: 11)).foregroundStyle(.secondary)
      }

      appsSection

      shortcutsSection

      Text("Type @ in the composer to drop a connector. Apps expand into self-contained context when you copy.")
        .font(.system(size: 11)).foregroundStyle(.tertiary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(22)
    .frame(width: 400)
  }

  // MARK: - Apps

  private var appsSection: some View {
    VStack(alignment: .leading, spacing: 9) {
      sectionHeader("APPS")
      VStack(spacing: 0) {
        ForEach(Array(MentionCatalog.apps.enumerated()), id: \.element.id) { index, app in
          if index > 0 { Divider().opacity(0.4) }
          appRow(app)
        }
      }
    }
    .padding(14)
    .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor).opacity(0.5)))
  }

  private func appRow(_ app: MentionItem) -> some View {
    HStack(spacing: 11) {
      appIcon(app)
        .frame(width: 22, height: 22)
      VStack(alignment: .leading, spacing: 1) {
        Text(app.label).font(.system(size: 12.5, weight: .medium))
        Text(app.subtitle).font(.system(size: 10.5)).foregroundStyle(.secondary)
      }
      Spacer(minLength: 12)
      Text(app.id)
        .font(.system(size: 11, weight: .medium, design: .monospaced))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 7).padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.06)))
    }
    .padding(.vertical, 7)
  }

  /// Brand favicon/octocat from the style cache, falling back to the SF Symbol until it loads.
  @ViewBuilder
  private func appIcon(_ app: MentionItem) -> some View {
    if let image = appIcons.image(for: app.id) {
      Image(nsImage: image)
        .resizable()
        .interpolation(.high)
        .aspectRatio(contentMode: .fit)
    } else {
      Image(systemName: app.symbol)
        .font(.system(size: 13))
        .foregroundStyle(.secondary)
    }
  }

  // MARK: - Shortcuts

  private var shortcutsSection: some View {
    VStack(alignment: .leading, spacing: 9) {
      sectionHeader("SHORTCUTS")
      ForEach(shortcuts, id: \.0) { item in
        HStack {
          Text(item.0).font(.system(size: 12))
          Spacer(minLength: 16)
          Text(item.1)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.06)))
        }
      }
    }
    .padding(14)
    .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor).opacity(0.5)))
  }

  private func sectionHeader(_ text: String) -> some View {
    Text(text).font(.system(size: 10, weight: .semibold)).tracking(0.6).foregroundStyle(.tertiary)
  }
}

// MARK: - Icon store

/// Bridges the AppKit `MentionStyleCache` into SwiftUI, republishing when a brand icon lands.
@MainActor
private final class AppIconStore: ObservableObject {
  private var observer: NSObjectProtocol?

  init() {
    observer = NotificationCenter.default.addObserver(
      forName: .composerStyleCacheUpdated, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.objectWillChange.send() }
    }
  }

  deinit {
    if let observer { NotificationCenter.default.removeObserver(observer) }
  }

  func image(for id: String) -> NSImage? { MentionStyleCache.shared.image(for: id) }
}
