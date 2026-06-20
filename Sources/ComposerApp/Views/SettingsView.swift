import SwiftUI

/// Settings as a right-docked glass panel — a sibling of the agent chat, not a modal over a dimmed
/// board. It wears the same frosted `ComposerPanelBackground` as the main window and the agent dock,
/// so it reads as a second panel floating in the gutter. The hero is an honest ledger of the local
/// intelligence this Mac can actually run right now: which engines are installed, what command each
/// one runs, and where it lives on disk.
struct SettingsOverlay: View {
  /// Sized by the canvas relative to the window so the panel adapts to the display.
  var width: CGFloat
  var onClose: () -> Void

  @State private var destination: SettingsDestination = .runtime

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider().overlay(Theme.Palette.separator)
      tabStrip
      Divider().overlay(Theme.Palette.separator)
      SettingsContent(destination: destination)
        .id(destination)
        .transition(.opacity)
    }
    .frame(width: width)
    .frame(maxHeight: .infinity)
    // Identical glass to the main window and the agent dock — same frosted treatment, tint, and
    // corner radius — so Settings reads as a second panel beside the card.
    .background(ComposerPanelBackground(radius: Theme.Radius.panel))
    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
    .onExitCommand(perform: onClose)
    .animation(Theme.Motion.accessory, value: destination)
  }

  // MARK: Header

  private var header: some View {
    HStack(spacing: 10) {
      RoundedRectangle(cornerRadius: 9, style: .continuous)
        .fill(Color.accentColor.opacity(0.16))
        .frame(width: 30, height: 30)
        .overlay(
          Image(systemName: "slider.horizontal.3")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color.accentColor)
        )
      Text("Settings").font(.body.weight(.semibold)).foregroundStyle(Theme.Palette.body)
      Spacer(minLength: 8)
      Button(action: onClose) {
        Image(systemName: "xmark")
          .font(.caption.weight(.bold))
          .foregroundStyle(Theme.Palette.title)
          .frame(width: 24, height: 24)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help("Close Settings  ·  Esc")
    }
    .padding(.leading, 16).padding(.trailing, 12).frame(height: 52)
  }

  // MARK: Tabs

  private var tabStrip: some View {
    HStack(spacing: 6) {
      ForEach(SettingsDestination.allCases) { tab($0) }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
  }

  private func tab(_ item: SettingsDestination) -> some View {
    let selected = destination == item
    return Button { destination = item } label: {
      VStack(spacing: 5) {
        Image(systemName: item.symbol).font(.system(size: 15, weight: .semibold))
        Text(item.title).font(.system(size: 10.5, weight: selected ? .semibold : .medium))
      }
      .frame(maxWidth: .infinity)
      .frame(height: 48)
      .foregroundStyle(selected ? Color.accentColor : Theme.Palette.menuDesc)
      .background(
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .fill(selected ? Color.accentColor.opacity(0.14) : Color.white.opacity(0.04))
      )
      .overlay(
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .strokeBorder(selected ? Color.accentColor.opacity(0.32) : Color.white.opacity(0.05), lineWidth: 1)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(item.title)
  }
}

private enum SettingsDestination: String, CaseIterable, Identifiable {
  case runtime
  case appearance
  case connectors
  case shortcuts

  var id: String { rawValue }
  var title: String {
    switch self {
    case .runtime: "Runtime"
    case .appearance: "Appearance"
    case .connectors: "Connectors"
    case .shortcuts: "Shortcuts"
    }
  }
  var symbol: String {
    switch self {
    case .runtime: "bolt.horizontal.circle"
    case .appearance: "circle.lefthalf.filled"
    case .connectors: "at"
    case .shortcuts: "command"
    }
  }
}

private struct SettingsContent: View {
  let destination: SettingsDestination

  private let shortcuts: [(String, String)] = [
    ("Compile board", "⌘R"),
    ("New board", "⌘N"),
    ("Navigate boards", "⌘[  ⌘]"),
    ("Select all · duplicate", "⌘A  ⌘D"),
    ("Group · ungroup", "⌘G  ⇧⌘G"),
    ("Lock · unlock", "⌘L  ⇧⌘L"),
    ("Copy self-contained", "⇧⌘C"),
  ]

  @StateObject private var appIcons = AppIconStore()
  @ObservedObject private var capabilities = EngineCapabilityStore.shared
  @ObservedObject private var shortcutStore = ShortcutStore.shared
  @AppStorage(EnginePreferences.claudeEnabledKey) private var claudeEnabled = true
  @AppStorage(ComposerPreferences.panelTransparencyKey) private var panelTransparency = ComposerPreferences.defaultPanelTransparency

  var body: some View {
    ScrollView {
      page.padding(16)
    }
    .scrollIndicators(.never)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  @ViewBuilder
  private var page: some View {
    switch destination {
    case .runtime: runtimePage
    case .appearance: appearancePage
    case .connectors: connectorsPage
    case .shortcuts: shortcutsPage
    }
  }

  // MARK: Runtime

  private var runtimePage: some View {
    let states = [
      capabilities.status(for: .claude),
      capabilities.appleIntelligence,
    ]
    let ready = states.filter { $0.isAvailable }.count

    return VStack(alignment: .leading, spacing: 16) {
      // Hero — the honest readout.
      VStack(alignment: .leading, spacing: 8) {
        Text("RUNTIME").pageEyebrow()
        Text("Local intelligence, honestly represented")
          .font(.title3.weight(.semibold))
          .foregroundStyle(Theme.Palette.body)
          .fixedSize(horizontal: false, vertical: true)
        Text("Composer only offers engines that are installed and answering on this Mac.")
          .font(.callout)
          .foregroundStyle(Theme.Palette.menuDesc)
          .fixedSize(horizontal: false, vertical: true)

        HStack(spacing: 8) {
          readout(ready: ready, total: states.count)
          Spacer(minLength: 8)
          Button(action: capabilities.refresh) {
            Label("Recheck", systemImage: "arrow.clockwise")
              .font(.caption.weight(.semibold))
              .padding(.horizontal, 11)
              .frame(height: 28)
          }
          .buttonStyle(SettingsPillButtonStyle())
          .foregroundStyle(Color.accentColor)
          .help("Re-scan this Mac for installed engines")
        }
        .padding(.top, 2)
      }

      // The ledger.
      VStack(alignment: .leading, spacing: 8) {
        Text("ENGINES").sectionLabel()
        engineRow(
          name: HeadlessEngine.claude.title,
          command: HeadlessEngine.claude.commandLabel,
          availability: capabilities.status(for: .claude),
          toggle: $claudeEnabled
        ) { EngineLogo(engine: .claude).frame(width: 18, height: 18) }

        engineRow(
          name: "Apple Intelligence",
          command: "semantic lint",
          availability: capabilities.appleIntelligence,
          toggle: nil
        ) {
          Image(systemName: "apple.intelligence")
            .font(.system(size: 19, weight: .medium))
            .foregroundStyle(AngularGradient(
              gradient: Gradient(colors: [.orange, .red, .purple, .blue, .cyan, .orange]),
              center: .center))
        }
      }

      Label("CLI prompts stay on your configured Claude account. Apple Intelligence runs the on-device lint and never sends a draft off your Mac.", systemImage: "lock.fill")
        .font(.caption)
        .foregroundStyle(Theme.Palette.count)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, 2)
    }
  }

  /// A live count of what's ready, in the mono "instrument" voice.
  private func readout(ready: Int, total: Int) -> some View {
    HStack(spacing: 6) {
      Circle()
        .fill(ready > 0 ? Color.green : Theme.Palette.count)
        .frame(width: 6, height: 6)
      Text("\(ready) of \(total) ready")
        .font(.caption.monospaced().weight(.semibold))
        .foregroundStyle(Theme.Palette.body)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 5)
    .background(Capsule().fill(Theme.Palette.segmentedFill))
  }

  private func engineRow<Icon: View>(
    name: String,
    command: String,
    availability: RuntimeAvailability,
    toggle: Binding<Bool>?,
    @ViewBuilder icon: () -> Icon
  ) -> some View {
    let available = availability.isAvailable
    let lit = available && (toggle?.wrappedValue ?? true)

    return HStack(spacing: 12) {
      // Tile lights with the accent when the engine is enabled and answering.
      icon()
        .frame(width: 42, height: 42)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Theme.Palette.tagFill))
        .overlay(
          RoundedRectangle(cornerRadius: 11, style: .continuous)
            .strokeBorder(lit ? Color.accentColor.opacity(0.55) : Color.white.opacity(0.06),
                          lineWidth: lit ? 1.4 : 1)
        )
        .shadow(color: lit ? Color.accentColor.opacity(0.30) : .clear, radius: lit ? 8 : 0)
        .opacity(available ? 1 : 0.4)
        .saturation(available ? 1 : 0.15)

      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 7) {
          Text(name).font(.callout.weight(.semibold)).foregroundStyle(Theme.Palette.body)
          statusBadge(availability)
        }
        HStack(spacing: 6) {
          Text(command)
            .font(.system(size: 10.5).monospaced())
            .foregroundStyle(Theme.Palette.menuDesc)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Theme.Palette.segmentedFill))
            .fixedSize()
          detailText(availability)
        }
      }

      Spacer(minLength: 8)

      trailingControl(availability: availability, toggle: toggle)
    }
    .padding(.horizontal, 13)
    .padding(.vertical, 12)
    .frame(minHeight: 72)
    .settingsCard()
    .opacity(available ? 1 : 0.72)
  }

  @ViewBuilder
  private func trailingControl(availability: RuntimeAvailability, toggle: Binding<Bool>?) -> some View {
    if let toggle {
      Toggle("", isOn: toggle)
        .labelsHidden()
        .toggleStyle(.switch)
        .controlSize(.small)
        .disabled(!availability.isAvailable)
        .opacity(availability.isAvailable ? 1 : 0.4)
    } else if availability.isAvailable {
      Image(systemName: "checkmark.seal.fill")
        .font(.body)
        .foregroundStyle(.green)
        .help("On-device — always local")
    } else {
      Image(systemName: "bolt.slash")
        .font(.body)
        .foregroundStyle(Theme.Palette.count)
    }
  }

  @ViewBuilder
  private func detailText(_ availability: RuntimeAvailability) -> some View {
    switch availability {
    case let .available(path, _):
      Text(path)
        .font(.system(size: 10.5).monospaced())
        .foregroundStyle(Theme.Palette.count)
        .lineLimit(1)
        .truncationMode(.middle)
    case .checking:
      Text("Checking this Mac…")
        .font(.caption2)
        .foregroundStyle(Theme.Palette.count)
    case let .unavailable(reason):
      Text(reason)
        .font(.caption2)
        .foregroundStyle(Theme.Palette.count)
        .lineLimit(1)
    }
  }

  private func statusBadge(_ availability: RuntimeAvailability) -> some View {
    let color: Color
    let word: String
    switch availability {
    case .available: color = .green; word = "Ready"
    case .checking: color = .orange; word = "Checking"
    case .unavailable: color = Theme.Palette.count; word = "Off"
    }
    return HStack(spacing: 4) {
      Circle().fill(color).frame(width: 5, height: 5)
      Text(word)
    }
    .font(.system(size: 10, weight: .semibold))
    .foregroundStyle(color)
    .padding(.horizontal, 6)
    .padding(.vertical, 2)
    .background(Capsule().fill(color.opacity(0.12)))
  }

  // MARK: Appearance

  private var appearancePage: some View {
    VStack(alignment: .leading, spacing: 16) {
      VStack(alignment: .leading, spacing: 6) {
        Text("APPEARANCE").pageEyebrow()
        Text("Set the panel’s presence")
          .font(.title3.weight(.semibold))
          .foregroundStyle(Theme.Palette.body)
        Text("Let more of the desktop through the glass without losing the contrast that keeps long drafts readable.")
          .font(.callout)
          .foregroundStyle(Theme.Palette.menuDesc)
          .fixedSize(horizontal: false, vertical: true)
      }

      VStack(alignment: .leading, spacing: 12) {
        Text("PANEL GLASS").sectionLabel()

        // A live preview of the panel at the chosen transparency.
        glassPreview
          .frame(height: 64)
          .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

        VStack(spacing: 12) {
          HStack(alignment: .firstTextBaseline) {
            Text("Background transparency").font(.callout.weight(.semibold)).foregroundStyle(Theme.Palette.body)
            Spacer(minLength: 12)
            Text("\(transparencyPercent)%")
              .font(.callout.monospacedDigit().weight(.semibold))
              .foregroundStyle(Color.accentColor)
          }
          Slider(value: $panelTransparency, in: 0...ComposerPreferences.maxPanelTransparency)
            .tint(Color.accentColor)
          HStack {
            Text("Opaque")
            Spacer()
            Text("Glass")
          }
          .font(.caption2)
          .foregroundStyle(Theme.Palette.count)
        }
        .padding(14)
        .settingsCard()
      }
    }
  }

  private var glassPreview: some View {
    let glass = ComposerPreferences.clampedPanelTransparency(panelTransparency) / ComposerPreferences.maxPanelTransparency
    let tint = 0.80 - 0.58 * glass
    return ZStack {
      VisualEffectBackground(material: .hudWindow, blending: .behindWindow, state: .active)
      Color.black.opacity(tint)
      HStack {
        Text("The quick brown fox")
          .font(.callout.weight(.medium))
          .foregroundStyle(.white.opacity(0.92))
        Spacer()
      }
      .padding(.horizontal, 14)
    }
    .overlay(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
    )
  }

  private var transparencyPercent: Int {
    Int((ComposerPreferences.clampedPanelTransparency(panelTransparency) / ComposerPreferences.maxPanelTransparency) * 100)
  }

  // MARK: Connectors

  private var connectorsPage: some View {
    VStack(alignment: .leading, spacing: 16) {
      VStack(alignment: .leading, spacing: 6) {
        Text("CONNECTORS").pageEyebrow()
        Text("Context that travels with your draft")
          .font(.title3.weight(.semibold))
          .foregroundStyle(Theme.Palette.body)
        Text("Type @ in a card to attach live context. Copied drafts become self-contained text — the source is resolved at copy time.")
          .font(.callout)
          .foregroundStyle(Theme.Palette.menuDesc)
          .fixedSize(horizontal: false, vertical: true)
      }

      ForEach(MentionCatalog.appsByCategory, id: \.category) { group in
        VStack(alignment: .leading, spacing: 8) {
          Text(group.category.title.uppercased()).sectionLabel()
          VStack(spacing: 0) {
            ForEach(Array(group.items.enumerated()), id: \.element.id) { index, app in
              if index > 0 { Divider().overlay(Theme.Palette.separator) }
              connectorRow(app)
            }
          }
          .padding(.horizontal, 13)
          .settingsCard()
        }
      }
    }
  }

  private func connectorRow(_ app: MentionItem) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 11) {
        appIcon(app)
          .frame(width: 24, height: 24)
        VStack(alignment: .leading, spacing: 2) {
          Text(app.label).font(.callout.weight(.medium)).foregroundStyle(Theme.Palette.body)
          Text(app.subtitle).font(.caption).foregroundStyle(Theme.Palette.menuDesc)
        }
        Spacer(minLength: 8)
        Text(app.id)
          .font(.caption.monospaced().weight(.medium))
          .foregroundStyle(Theme.Palette.menuDesc)
          .padding(.horizontal, 7)
          .padding(.vertical, 3)
          .background(Capsule().fill(Theme.Palette.segmentedFill))
      }
      .padding(.vertical, 11)

      if case let .apiToken(label, hint, createURL) = AppConnectorRegistry.connector(for: app.id)?.auth ?? .none {
        ConnectorTokenField(connectorID: app.id, label: label, hint: hint, createURL: createURL)
          .padding(.leading, 35)
          .padding(.bottom, 11)
      }
    }
  }

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
        .foregroundStyle(Theme.Palette.menuDesc)
    }
  }

  // MARK: Shortcuts

  private var shortcutsPage: some View {
    VStack(alignment: .leading, spacing: 16) {
      VStack(alignment: .leading, spacing: 6) {
        Text("SHORTCUTS").pageEyebrow()
        Text("Keep the canvas under your fingers")
          .font(.title3.weight(.semibold))
          .foregroundStyle(Theme.Palette.body)
        Text("The essentials for writing, arranging, and exporting without breaking flow.")
          .font(.callout)
          .foregroundStyle(Theme.Palette.menuDesc)
          .fixedSize(horizontal: false, vertical: true)
      }

      VStack(spacing: 7) {
        // The summon hotkey is user-configurable (records into ShortcutStore, which HotKeyManager
        // re-binds); the rest are fixed in-app commands shown for reference.
        HStack(spacing: 10) {
          Text("Summon Composer")
            .font(.callout.weight(.medium))
            .foregroundStyle(Theme.Palette.body)
            .lineLimit(1)
          Spacer(minLength: 8)
          ShortcutRecorder(store: shortcutStore)
        }
        .padding(.horizontal, 13)
        .frame(minHeight: 46)
        .settingsCard()

        ForEach(shortcuts, id: \.0) { title, key in
          HStack(spacing: 10) {
            Text(title)
              .font(.callout.weight(.medium))
              .foregroundStyle(Theme.Palette.body)
              .lineLimit(1)
            Spacer(minLength: 8)
            Text(key)
              .font(.caption.monospaced().weight(.semibold))
              .foregroundStyle(Theme.Palette.body)
              .padding(.horizontal, 7)
              .padding(.vertical, 4)
              .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                  .fill(Theme.Palette.keycapFill)
                  .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.06), lineWidth: 1))
              )
          }
          .padding(.horizontal, 13)
          .frame(minHeight: 46)
          .settingsCard()
        }
      }
    }
  }
}

// MARK: - Connector token field

/// Paste/save/clear a connector's API token. Reads and writes `ConnectorSecretStore` imperatively;
/// the stored secret is never loaded back into the field — only its presence (Connected) is shown.
private struct ConnectorTokenField: View {
  let connectorID: String
  let label: String
  let hint: String
  let createURL: String?

  @State private var draft: String = ""
  /// Bumped on save/clear so the imperative `ConnectorSecretStore` reads re-evaluate in `body`.
  @State private var revision = 0

  private var connected: Bool { _ = revision; return ConnectorSecretStore.hasToken(for: connectorID) }

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      HStack(spacing: 8) {
        SecureField(connected ? "Replace token…" : label, text: $draft)
          .textFieldStyle(.plain)
          .font(.caption)
          .foregroundStyle(Theme.Palette.body)
          .padding(.horizontal, 9).padding(.vertical, 6)
          .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.Palette.segmentedFill))
          .onSubmit(save)
        Button("Save", action: save)
          .buttonStyle(.plain)
          .font(.caption.weight(.semibold))
          .foregroundStyle(draft.trimmed.isEmpty ? Theme.Palette.menuDesc : Color.accentColor)
          .disabled(draft.trimmed.isEmpty)
        if connected {
          Button("Clear", action: clear)
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(Theme.Palette.menuDesc)
        }
      }
      HStack(spacing: 6) {
        Circle()
          .fill(connected ? Color.green.opacity(0.9) : Theme.Palette.menuDesc.opacity(0.5))
          .frame(width: 6, height: 6)
        Text(connected ? "Connected" : hint)
          .font(.caption2)
          .foregroundStyle(Theme.Palette.menuDesc)
        if let createURL, let url = URL(string: createURL) {
          Spacer(minLength: 8)
          Link("Get a token ↗", destination: url)
            .font(.caption2.weight(.medium))
            .foregroundStyle(Color.accentColor)
        }
      }
    }
  }

  private func save() {
    let value = draft.trimmed
    guard !value.isEmpty else { return }
    ConnectorSecretStore.setToken(value, for: connectorID)
    draft = ""
    revision += 1
  }

  private func clear() {
    ConnectorSecretStore.setToken(nil, for: connectorID)
    draft = ""
    revision += 1
  }
}

// MARK: - Styling helpers

private struct SettingsPillButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .background(
        Capsule().fill(configuration.isPressed ? Color.accentColor.opacity(0.22) : Color.accentColor.opacity(0.12))
      )
      .scaleEffect(configuration.isPressed ? 0.97 : 1)
      .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
  }
}

private extension View {
  /// Subtle raised tile for the rows and cards inside the panel, over the frosted glass.
  func settingsCard(radius: CGFloat = 13) -> some View {
    self.background {
      RoundedRectangle(cornerRadius: radius, style: .continuous)
        .fill(Theme.Palette.rowFill)
        .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
          .strokeBorder(Color.white.opacity(0.06), lineWidth: 1))
    }
  }

  func sectionLabel() -> some View {
    self.font(.caption2.weight(.bold))
      .tracking(0.6)
      .foregroundStyle(Theme.Palette.count)
  }

  func pageEyebrow() -> some View {
    self.font(.caption2.weight(.bold))
      .tracking(1.2)
      .foregroundStyle(Color.accentColor)
  }
}

// MARK: - Icon store

/// Bridges the AppKit favicon cache into SwiftUI, republishing when an icon lands.
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
