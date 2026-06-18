import SwiftUI

/// Settings as a full-card overlay inside the panel — never a separate window.
struct SettingsOverlay: View {
  var onClose: () -> Void

  var body: some View {
    ZStack(alignment: .topLeading) {
      // Same frosted-glass material as the card, dark enough to cover the editor — so
      // Settings reads as part of the panel, not a flat sheet pasted on top.
      ZStack {
        VisualEffectBackground(material: .hudWindow, blending: .behindWindow, state: .active)
        Color.black.opacity(0.9)
      }
      .contentShape(Rectangle())

      VStack(spacing: 0) {
        HStack {
          Text("Settings")
            .font(.title2.weight(.semibold))
            .foregroundStyle(Theme.Palette.body)
          Spacer()
          Button(action: onClose) {
            Image(systemName: "xmark")
              .font(.body.weight(.semibold))
              .foregroundStyle(Theme.Palette.title)
              .frame(width: 32, height: 32)
              .background(Circle().fill(Color.white.opacity(0.06)))
              .contentShape(Circle())
          }
          .buttonStyle(.plain)
          .help("Close  Esc")
        }
        .padding(.horizontal, 28)
        .padding(.top, 24)
        .padding(.bottom, 12)

        ScrollView {
          SettingsContent()
            .padding(.horizontal, 28)
            .padding(.bottom, 28)
        }
        .scrollIndicators(.never)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
  }
}

struct SettingsContent: View {
  private let shortcuts: [(String, String)] = [
    ("Summon / hide Composer", "⌃⌥Space"),
    ("Refine selection", "select text → Claude / Codex"),
    ("Compile board to a draft", "⌘R"),
    ("New board", "⌘N"),
    ("Flip through past boards", "⌘[ / ⌘]"),
    ("Insert a connector", "type @"),
    ("Pan the canvas", "hold Space + drag"),
    ("Select all · duplicate", "⌘A · ⌘D"),
    ("Group · ungroup", "⌘G · ⇧⌘G"),
    ("Lock · unlock", "⌘L · ⇧⌘L"),
    ("Copy self-contained text", "⇧⌘C"),
    ("Increase / decrease font size", "⌘+ / ⌘−"),
    ("Dismiss", "Esc"),
  ]

  /// Republished whenever a brand icon/color lands so the Apps list redraws.
  @StateObject private var appIcons = AppIconStore()
  @AppStorage(EnginePreferences.claudeEnabledKey) private var claudeEnabled = true
  @AppStorage(EnginePreferences.codexEnabledKey) private var codexEnabled = true
  @AppStorage(ComposerPreferences.panelTransparencyKey) private var panelTransparency = ComposerPreferences.defaultPanelTransparency

  private var transparencyPercent: Int {
    Int((ComposerPreferences.clampedPanelTransparency(panelTransparency) / ComposerPreferences.maxPanelTransparency) * 100)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      enginesSection
      appearanceSection
      appsSection
      shortcutsSection

      Text("Type @ in the composer to drop a connector. Apps expand into self-contained context when you copy.")
        .font(.caption).foregroundStyle(.tertiary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  // MARK: - Engines

  private var enginesSection: some View {
    VStack(alignment: .leading, spacing: 9) {
      sectionHeader("ENGINES")
      engineToggle(.claude, isOn: $claudeEnabled)
      Divider().opacity(0.4)
      engineToggle(.codex, isOn: $codexEnabled)
    }
    .padding(16)
    .background(RoundedRectangle(cornerRadius: Theme.Radius.menu, style: .continuous).fill(Color.white.opacity(0.05)))
  }

  private func engineToggle(_ engine: HeadlessEngine, isOn: Binding<Bool>) -> some View {
    Toggle(isOn: isOn) {
      HStack(spacing: 11) {
        EngineLogo(engine: engine)
          .frame(width: 22, height: 22)
        VStack(alignment: .leading, spacing: 1) {
          Text(engine.title).font(.body.weight(.medium))
          Text(engine.commandLabel).font(.caption).foregroundStyle(.secondary)
        }
      }
    }
    .toggleStyle(.switch)
  }

  // MARK: - Appearance

  private var appearanceSection: some View {
    VStack(alignment: .leading, spacing: 11) {
      sectionHeader("APPEARANCE")
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 2) {
          Text("Background transparency").font(.body.weight(.medium))
          Text("How much of the desktop frosts through the panel.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer(minLength: 16)
        Text("\(transparencyPercent)%")
          .font(.caption.monospacedDigit().weight(.medium))
          .foregroundStyle(.secondary)
      }
      Slider(value: $panelTransparency, in: 0...ComposerPreferences.maxPanelTransparency)
      HStack {
        Text("Opaque")
        Spacer()
        Text("Glass")
      }
      .font(.caption2)
      .foregroundStyle(.tertiary)
    }
    .padding(16)
    .background(RoundedRectangle(cornerRadius: Theme.Radius.menu, style: .continuous).fill(Color.white.opacity(0.05)))
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
    .padding(16)
    .background(RoundedRectangle(cornerRadius: Theme.Radius.menu, style: .continuous).fill(Color.white.opacity(0.05)))
  }

  private func appRow(_ app: MentionItem) -> some View {
    HStack(spacing: 11) {
      appIcon(app)
        .frame(width: 22, height: 22)
      VStack(alignment: .leading, spacing: 1) {
        Text(app.label).font(.body.weight(.medium))
        Text(app.subtitle).font(.caption).foregroundStyle(.secondary)
      }
      Spacer(minLength: 12)
      Text(app.id)
        .font(.caption.monospaced().weight(.medium))
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
        .font(.body)
        .foregroundStyle(.secondary)
    }
  }

  // MARK: - Shortcuts

  private var shortcutsSection: some View {
    VStack(alignment: .leading, spacing: 9) {
      sectionHeader("SHORTCUTS")
      ForEach(shortcuts, id: \.0) { item in
        HStack {
          Text(item.0).font(.body)
          Spacer(minLength: 16)
          Text(item.1)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.06)))
        }
      }
    }
    .padding(16)
    .background(RoundedRectangle(cornerRadius: Theme.Radius.menu, style: .continuous).fill(Color.white.opacity(0.05)))
  }

  private func sectionHeader(_ text: String) -> some View {
    Text(text).font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
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
