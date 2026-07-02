import SwiftUI

/// Settings as a right-docked glass panel — a sibling of the agent chat, not a modal over a dimmed
/// board. It wears the same frosted `ComposerPanelBackground` as the main window and the agent dock,
/// so it reads as a second panel floating in the gutter. It follows the same quiet-by-default
/// language as the rails: neutral surfaces, accent reserved as a single signal (the selected tab),
/// brand marks for identity — no decorative color, glows, or status confetti.
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
    // Liquid Glass floating over the canvas.
    .dockPanelSurface()
    .onExitCommand(perform: onClose)
    .animation(Theme.Motion.accessory, value: destination)
  }

  // MARK: Header

  /// Mirrors the agent dock's header rhythm: a single quiet glyph, the title, and a plain close
  /// button — no tinted tile.
  private var header: some View {
    HStack(spacing: 10) {
      Image(systemName: "slider.horizontal.3")
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(Theme.Palette.body)
        .frame(width: 18)
      Text("Settings").font(.body.weight(.semibold)).foregroundStyle(Theme.Palette.body)
      Spacer(minLength: 8)
      Button(action: onClose) {
        Image(systemName: "xmark")
          .font(.caption.weight(.medium))
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

  /// Modern chip nav: inline icon + label capsules in a horizontal row. Selection is a filled
  /// chip; everything else stays quiet until hover.
  private var tabStrip: some View {
    ScrollView(.horizontal) {
      HStack(spacing: 5) {
        ForEach(SettingsDestination.allCases) { item in
          SettingsTab(item: item, selected: destination == item) {
            Haptics.tap()
            destination = item
          }
        }
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 9)
    }
    .scrollIndicators(.never)
  }
}

/// One chip of the settings nav — icon + label inline in a capsule. The selected chip carries a
/// quiet filled background with accent-tinted content; the rest light up on hover.
private struct SettingsTab: View {
  let item: SettingsDestination
  let selected: Bool
  var action: () -> Void
  @State private var hovering = false

  var body: some View {
    Button(action: action) {
      HStack(spacing: 5) {
        Image(systemName: item.symbol).font(.system(size: 11.5, weight: .medium))
        Text(item.title).font(.system(size: 11.5, weight: .medium)).fixedSize()
      }
      .foregroundStyle(foreground)
      .padding(.horizontal, 10)
      .frame(height: 26)
      .background(
        Capsule().fill(selected ? Theme.Palette.keycapFill : (hovering ? Theme.Palette.rowFill : Color.clear))
      )
      .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
    .help(item.title)
    .animation(.easeOut(duration: 0.12), value: hovering)
  }

  private var foreground: AnyShapeStyle {
    if selected { return AnyShapeStyle(Theme.Palette.accent) }
    return AnyShapeStyle(hovering ? Theme.Palette.body : Theme.Palette.menuDesc)
  }
}

private enum SettingsDestination: String, CaseIterable, Identifiable {
  case runtime
  case appearance
  case connectors
  case shortcuts
  case about

  var id: String { rawValue }
  var title: String {
    switch self {
    case .runtime: "Runtime"
    case .appearance: "Appearance"
    case .connectors: "Connectors"
    case .shortcuts: "Shortcuts"
    case .about: "About"
    }
  }
  var symbol: String {
    switch self {
    case .runtime: "bolt.horizontal.circle"
    case .appearance: "circle.lefthalf.filled"
    case .connectors: "at"
    case .shortcuts: "command"
    case .about: "info.circle"
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
  ]

  @StateObject private var appIcons = AppIconStore()
  @ObservedObject private var capabilities = EngineCapabilityStore.shared
  @ObservedObject private var shortcutStore = ShortcutStore.shared
  @AppStorage(EnginePreferences.claudeEnabledKey) private var claudeEnabled = true
  @AppStorage(EnginePreferences.codexEnabledKey) private var codexEnabled = true
  @AppStorage(EnginePreferences.opencodeEnabledKey) private var opencodeEnabled = true
  // The chat surface's provider pick + per-engine model. These keys are shared with the Agent dock,
  // so the two controls mirror each other live.
  @AppStorage(EnginePreferences.chatEngineKey) private var chatEngineRaw = ""
  @AppStorage("model.chat.codex") private var codexChatModel = ""
  @AppStorage("model.chat.opencode") private var opencodeChatModel = ""
  @ObservedObject private var modelCatalog = ChatModelCatalog.shared
  // Both keys are shared with their in-canvas pickers (the Agent dock for chat), so the controls
  // mirror each other live. See [[ModelPreferences]].
  @AppStorage(ModelPreferences.chatModelKey) private var chatModel: ClaudeModel = ModelPreferences.defaultChatModel
  @AppStorage(ComposerPreferences.themeKey) private var themeRaw = ComposerTheme.bonsaiDark.rawValue
  @AppStorage(ComposerPreferences.canvasTransparencyKey) private var canvasTransparency = 0.0
  /// Whether the agent has standing "Always Allow" tool grants - drives the reset control's
  /// visibility. Refreshed in `onAppear`; flipped false the moment the user resets.
  @State private var agentHasGrants = false
  /// Bumped after an agent-skills install so `AgentSkillTarget.isInstalled` (a filesystem check,
  /// not a published property) re-reads and the row badges refresh.
  @State private var agentSkillsRevision = 0
  @State private var agentSkillsError: String?

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
    case .about: aboutPage
    }
  }

  /// A quiet page intro: a plain heading and a single line of guidance. No accent eyebrow, no hero —
  /// the selected tab is the title; this just orients.
  private func pageHeader(_ title: String, _ subtitle: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title).font(.headline).foregroundStyle(Theme.Palette.body)
      Text(subtitle)
        .font(.caption)
        .foregroundStyle(Theme.Palette.menuDesc)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  // MARK: Runtime

  private var runtimePage: some View {
    let states = HeadlessEngine.allCases.map { capabilities.status(for: $0) } + [capabilities.appleIntelligence]
    let ready = states.filter { $0.isAvailable }.count

    return VStack(alignment: .leading, spacing: 16) {
      VStack(alignment: .leading, spacing: 10) {
        pageHeader("Local intelligence",
                   "Only engines installed and answering on this Mac are offered.")
        HStack(spacing: 8) {
          readout(ready: ready, total: states.count)
          Spacer(minLength: 8)
          Button(action: capabilities.refresh) {
            Label("Recheck", systemImage: "arrow.clockwise")
              .font(.caption.weight(.semibold))
              .foregroundStyle(Theme.Palette.body)
              .padding(.horizontal, 11)
              .frame(height: 28)
          }
          .buttonStyle(SettingsPillButtonStyle())
          .help("Re-scan this Mac for installed engines")
        }
      }

      VStack(spacing: 8) {
        engineRow(
          name: HeadlessEngine.claude.title,
          command: HeadlessEngine.claude.commandLabel,
          availability: capabilities.status(for: .claude),
          toggle: $claudeEnabled
        ) { EngineLogo(engine: .claude).frame(width: 18, height: 18) }
        engineRow(
          name: HeadlessEngine.codex.title,
          command: HeadlessEngine.codex.commandLabel,
          availability: capabilities.status(for: .codex),
          toggle: $codexEnabled
        ) { EngineLogo(engine: .codex).frame(width: 18, height: 18) }
        engineRow(
          name: HeadlessEngine.opencode.title,
          command: HeadlessEngine.opencode.commandLabel,
          availability: capabilities.status(for: .opencode),
          toggle: $opencodeEnabled
        ) { EngineLogo(engine: .opencode).frame(width: 18, height: 18) }

        engineRow(
          name: "Apple Intelligence",
          command: "semantic lint",
          availability: capabilities.appleIntelligence,
          toggle: nil
        ) {
          // The genuine Apple Intelligence mark — brand identity, the same rainbow the agent icon
          // uses — not decorative color.
          Image(systemName: "apple.intelligence")
            .font(.system(size: 19, weight: .medium))
            .foregroundStyle(AngularGradient(
              gradient: Gradient(colors: [.orange, .red, .purple, .blue, .cyan, .orange]),
              center: .center))
        }
      }

      modelsCard

      Label("CLI prompts stay on your configured agent accounts. Apple Intelligence runs the on-device lint and never sends a draft off your Mac.", systemImage: "lock.fill")
        .font(.caption)
        .foregroundStyle(Theme.Palette.count)
        .fixedSize(horizontal: false, vertical: true)

      // Only appears once the agent has standing "Always Allow" grants - lets a user revoke them
      // without editing defaults by hand.
      if agentHasGrants {
        HStack(spacing: 8) {
          VStack(alignment: .leading, spacing: 2) {
            Text("Agent tool permissions")
              .font(.callout.weight(.semibold)).foregroundStyle(Theme.Palette.body)
            Text("Tools you chose \"Always Allow\" for run without asking again.")
              .font(.caption).foregroundStyle(Theme.Palette.menuDesc)
              .fixedSize(horizontal: false, vertical: true)
          }
          Spacer(minLength: 8)
          Button {
            AgentPermissionBroker.resetRememberedGrants()
            agentHasGrants = false
          } label: {
            Label("Reset", systemImage: "arrow.counterclockwise")
              .font(.caption.weight(.semibold))
              .foregroundStyle(Theme.Palette.body)
              .padding(.horizontal, 11)
              .frame(height: 28)
          }
          .buttonStyle(SettingsPillButtonStyle())
          .help("Ask again next time the agent uses one of these tools")
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 12)
        .settingsCard()
      }
    }
    .onAppear {
      agentHasGrants = AgentPermissionBroker.hasRememberedGrants
      modelCatalog.loadOpenCodeModelsIfNeeded()
    }
  }

  /// Pick a provider (engine), then a model for it — the same shape as the Agent panel's per-session
  /// picker, kept in sync via the shared keys. Refine/Compile aren't listed: they stay on the CLI
  /// default deliberately.
  private var modelsCard: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("MODELS").sectionLabel()
      VStack(spacing: 0) {
        surfaceRow(
          title: "Chat Agent",
          subtitle: "The agent you talk to in the canvas. Also switchable live in the Agent panel.",
          engineRaw: $chatEngineRaw,
          claudeModel: $chatModel, codexModel: $codexChatModel, opencodeModel: $opencodeChatModel)
      }
      .padding(.horizontal, 13)
      .settingsCard()
      if availableEngines.isEmpty {
        Text("No engine is enabled and installed. Enable one in Runtime above.")
          .font(.caption).foregroundStyle(.orange)
      }
    }
  }

  /// Engines that can run a surface right now — enabled in Runtime *and* installed.
  private var availableEngines: [HeadlessEngine] {
    HeadlessEngine.allCases.filter { EnginePreferences.isEnabled($0) && capabilities.isAvailable($0) }
  }

  /// The engine a `engine.<surface>.selected` string resolves to: the pick when it's ready, else the
  /// first available engine.
  private func resolvedEngine(_ raw: String) -> HeadlessEngine? {
    if let engine = HeadlessEngine(rawValue: raw),
       EnginePreferences.isEnabled(engine), capabilities.isAvailable(engine) { return engine }
    return availableEngines.first
  }

  /// One "surface → provider → model" row: a title, a provider menu, and a model menu whose options
  /// follow the chosen provider (Claude tiers, or the Codex/OpenCode `provider/model` list).
  @ViewBuilder
  private func surfaceRow(
    title: String, subtitle: String, engineRaw: Binding<String>,
    claudeModel: Binding<ClaudeModel>, codexModel: Binding<String>, opencodeModel: Binding<String>
  ) -> some View {
    let engine = resolvedEngine(engineRaw.wrappedValue)
    HStack(spacing: 10) {
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.callout.weight(.medium)).foregroundStyle(Theme.Palette.body)
        Text(subtitle)
          .font(.caption).foregroundStyle(Theme.Palette.menuDesc)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 8)
      if let engine {
        providerPicker(engineRaw, resolved: engine)
        modelPicker(for: engine, claudeModel: claudeModel, codexModel: codexModel, opencodeModel: opencodeModel)
      }
    }
    .padding(.vertical, 11)
  }

  /// Provider (engine) menu, listing every ready engine.
  private func providerPicker(_ engineRaw: Binding<String>, resolved: HeadlessEngine) -> some View {
    Picker("", selection: Binding(get: { resolved }, set: { engineRaw.wrappedValue = $0.rawValue })) {
      ForEach(availableEngines) { Text($0.title).tag($0) }
    }
    .labelsHidden().pickerStyle(.menu).fixedSize().tint(Theme.Palette.body)
  }

  /// Model menu for the chosen provider: Claude tiers, or a "Default" + `provider/model` list.
  @ViewBuilder
  private func modelPicker(
    for engine: HeadlessEngine,
    claudeModel: Binding<ClaudeModel>, codexModel: Binding<String>, opencodeModel: Binding<String>
  ) -> some View {
    switch engine {
    case .claude:
      Picker("", selection: claudeModel) {
        ForEach(ClaudeModel.allCases) { Text($0.title).tag($0) }
      }
      .labelsHidden().pickerStyle(.menu).fixedSize().tint(Theme.Palette.body)
    case .codex:
      stringModelPicker(codexModel, models: modelCatalog.models(for: .codex))
    case .opencode:
      stringModelPicker(opencodeModel, models: modelCatalog.opencodeModels)
    }
  }

  /// A `provider/model` menu (Codex / OpenCode). "Default" leaves the engine on its own default.
  private func stringModelPicker(_ selection: Binding<String>, models: [String]) -> some View {
    Picker("", selection: selection) {
      Text("Default").tag("")
      ForEach(models, id: \.self) { Text(Self.shortModel($0)).tag($0) }
    }
    .labelsHidden().pickerStyle(.menu).fixedSize().tint(Theme.Palette.body)
  }

  /// Compact model label: the id's last path component. `opencode/big-pickle` → `big-pickle`.
  private static func shortModel(_ id: String) -> String {
    id.split(separator: "/").last.map(String.init) ?? id
  }

  /// A live count of what's ready, in the mono "instrument" voice. One status dot, neutral capsule.
  private func readout(ready: Int, total: Int) -> some View {
    HStack(spacing: 6) {
      Circle()
        .fill(ready > 0 ? Color.green.opacity(0.9) : Theme.Palette.count)
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

    return HStack(spacing: 12) {
      // A neutral tile holds the brand mark — the logo is the color; the tile never lights up.
      icon()
        .frame(width: 42, height: 42)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Theme.Palette.tagFill))
        .overlay(
          RoundedRectangle(cornerRadius: 11, style: .continuous)
            .strokeBorder(Theme.Palette.panelInnerLine, lineWidth: 1)
        )
        .opacity(available ? 1 : 0.4)
        .saturation(available ? 1 : 0.2)

      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 7) {
          Text(name).font(.callout.weight(.semibold)).foregroundStyle(Theme.Palette.body)
          statusDot(availability)
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
    .opacity(available ? 1 : 0.78)
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
      Image(systemName: "lock.fill")
        .font(.callout)
        .foregroundStyle(Theme.Palette.count)
        .help("On-device — never leaves your Mac")
    } else {
      Image(systemName: "bolt.slash")
        .font(.callout)
        .foregroundStyle(Theme.Palette.count)
    }
  }

  /// The lone status signal on a row: a single dot, green only when the engine is answering.
  private func statusDot(_ availability: RuntimeAvailability) -> some View {
    Circle()
      .fill(availability.isAvailable ? Color.green.opacity(0.9) : Theme.Palette.count)
      .frame(width: 6, height: 6)
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

  // MARK: Appearance

  private var appearancePage: some View {
    VStack(alignment: .leading, spacing: 20) {
      themeCard
      canvasGlassCard
    }
  }

  /// Canvas background transparency — solid by default; the board behind this panel updates live
  /// as the slider moves, so it is its own preview.
  private var canvasGlassCard: some View {
    VStack(alignment: .leading, spacing: 8) {
      pageHeader("Canvas",
                 "Let the desktop blur through the board surface. Solid keeps the flat canvas.")
      VStack(spacing: 12) {
        HStack(alignment: .firstTextBaseline) {
          Text("Background transparency").font(.callout.weight(.semibold)).foregroundStyle(Theme.Palette.body)
          Spacer(minLength: 12)
          Text("\(canvasTransparencyPercent)%")
            .font(.callout.monospacedDigit().weight(.semibold))
            .foregroundStyle(Theme.Palette.body)
        }
        Slider(value: $canvasTransparency, in: 0...ComposerPreferences.maxCanvasTransparency)
          .tint(Theme.Palette.accent)
        HStack {
          Text("Solid")
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

  private var canvasTransparencyPercent: Int {
    Int((ComposerPreferences.clampedCanvasTransparency(canvasTransparency) / ComposerPreferences.maxCanvasTransparency) * 100)
  }

  /// The theme gallery: one live-preview card per flavor, painted from that flavor's own palette
  /// (not the current one), so every option shows exactly what it looks like before you commit.
  private var themeCard: some View {
    VStack(alignment: .leading, spacing: 8) {
      pageHeader("Theme", "Pick the palette for the whole app.")
      LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
        ForEach(ComposerTheme.allCases) { theme in
          ThemePreviewCard(theme: theme, selected: themeRaw == theme.rawValue) {
            Haptics.level()
            themeRaw = theme.rawValue
          }
        }
      }
    }
    .onChange(of: themeRaw) { _, _ in
      NotificationCenter.default.post(name: .composerThemeChanged, object: nil)
    }
  }

  // MARK: Connectors

  private var connectorsPage: some View {
    VStack(alignment: .leading, spacing: 16) {
      pageHeader("Connectors",
                 "Type @ in a card to attach live context. Copied drafts become self-contained text — the source is resolved at copy time.")

      agentSkillsCard

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

  /// Lets coding agents (Claude Code, Codex CLI, Cursor) drive the board over the local canvas API.
  /// Each row reflects a live filesystem check, not a stored preference — `agentSkillsRevision`
  /// forces a re-read after install since SwiftUI has no other reason to invalidate this view.
  private var agentSkillsCard: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("AGENT SKILLS").sectionLabel()
      VStack(spacing: 0) {
        ForEach(Array(AgentSkillTarget.allCases.enumerated()), id: \.element.id) { index, target in
          if index > 0 { Divider().overlay(Theme.Palette.separator) }
          agentSkillRow(target)
        }
      }
      .padding(.horizontal, 13)
      .settingsCard()
      if let agentSkillsError {
        Text(agentSkillsError)
          .font(.caption)
          .foregroundStyle(.orange)
      }
    }
  }

  private func agentSkillRow(_ target: AgentSkillTarget) -> some View {
    let installed = { _ = agentSkillsRevision; return target.isInstalled }()
    return HStack(spacing: 11) {
      Image(systemName: target.symbol)
        .font(.system(size: 15, weight: .medium))
        .foregroundStyle(Theme.Palette.body)
        .frame(width: 24, height: 24)
      VStack(alignment: .leading, spacing: 2) {
        Text(target.displayName).font(.callout.weight(.medium)).foregroundStyle(Theme.Palette.body)
        Text(target.isDetected ? (installed ? "Skill installed" : "Detected on this Mac") : "Not detected")
          .font(.caption).foregroundStyle(Theme.Palette.menuDesc)
      }
      Spacer(minLength: 8)
      Button(action: { installAgentSkill(target) }) {
        Text(installed ? "Reinstall" : "Install")
          .font(.caption.weight(.semibold))
          .foregroundStyle(Theme.Palette.body)
          .padding(.horizontal, 11)
          .frame(height: 26)
      }
      .buttonStyle(SettingsPillButtonStyle())
    }
    .padding(.vertical, 11)
  }

  private func installAgentSkill(_ target: AgentSkillTarget) {
    do {
      try AgentSkillsInstaller.install(target)
      agentSkillsError = nil
    } catch {
      agentSkillsError = "\(target.displayName): \(error.localizedDescription)"
    }
    agentSkillsRevision += 1
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
      pageHeader("Keyboard",
                 "The essentials for writing, arranging, and exporting without breaking flow.")

      VStack(spacing: 7) {
        // The summon hotkey is user-configurable (records into ShortcutStore, which HotKeyManager
        // re-binds); the rest are fixed in-app commands shown for reference.
        HStack(spacing: 10) {
          Text("Summon Composer")
            .font(.callout.weight(.medium))
            .foregroundStyle(Theme.Palette.body)
            .lineLimit(1)
          Spacer(minLength: 8)
          ShortcutRecorder(shortcut: $shortcutStore.shortcut, defaultValue: .default)
        }
        .padding(.horizontal, 13)
        .frame(minHeight: 46)
        .settingsCard()

        HStack(spacing: 10) {
          VStack(alignment: .leading, spacing: 2) {
            Text("Snap to board")
              .font(.callout.weight(.medium))
              .foregroundStyle(Theme.Palette.body)
              .lineLimit(1)
            Text("Capture a screen region — read on-device into an agent-ready card.")
              .font(.caption)
              .foregroundStyle(Theme.Palette.menuDesc)
              .lineLimit(1)
          }
          Spacer(minLength: 8)
          ShortcutRecorder(shortcut: $shortcutStore.captureShortcut, defaultValue: .defaultCapture)
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
                    .strokeBorder(Theme.Palette.panelInnerLine, lineWidth: 1))
              )
          }
          .padding(.horizontal, 13)
          .frame(minHeight: 46)
          .settingsCard()
        }
      }
    }
  }

  // MARK: About

  private var aboutPage: some View {
    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    return VStack(alignment: .leading, spacing: 16) {
      pageHeader("Updates",
                 "BonsAI checks GitHub for new releases automatically, then downloads and installs them in place.")

      VStack(spacing: 8) {
        // Identity + manual check — the version readout in the mono "instrument" voice the rails use.
        HStack(spacing: 12) {
          VStack(alignment: .leading, spacing: 4) {
            Text("BonsAI").font(.callout.weight(.semibold)).foregroundStyle(Theme.Palette.body)
            Text("Version \(version)")
              .font(.system(size: 10.5).monospaced())
              .foregroundStyle(Theme.Palette.menuDesc)
          }
          Spacer(minLength: 8)
          Button(action: { UpdaterController.shared.checkForUpdates() }) {
            Label("Check for Updates", systemImage: "arrow.triangle.2.circlepath")
              .font(.caption.weight(.semibold))
              .foregroundStyle(Theme.Palette.body)
              .padding(.horizontal, 11)
              .frame(height: 28)
          }
          .buttonStyle(SettingsPillButtonStyle())
          .help("Check GitHub for a newer BonsAI now")
        }
        .padding(.horizontal, 13)
        .frame(minHeight: 56)
        .settingsCard()

        // Automatic-check toggle, bound straight to Sparkle's scheduled-update preference.
        HStack(spacing: 10) {
          VStack(alignment: .leading, spacing: 2) {
            Text("Check automatically").font(.callout.weight(.medium)).foregroundStyle(Theme.Palette.body)
            Text("Look for updates daily in the background")
              .font(.caption2).foregroundStyle(Theme.Palette.menuDesc)
          }
          Spacer(minLength: 8)
          Toggle("", isOn: Binding(
            get: { UpdaterController.shared.automaticallyChecksForUpdates },
            set: { UpdaterController.shared.automaticallyChecksForUpdates = $0 }))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
        }
        .padding(.horizontal, 13)
        .frame(minHeight: 52)
        .settingsCard()
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
          .foregroundStyle(draft.trimmed.isEmpty ? Theme.Palette.menuDesc : Theme.Palette.accent)
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
            .foregroundStyle(Theme.Palette.accent)
        }
      }
    }
  }

  private func save() {
    let value = draft.trimmed
    guard !value.isEmpty else { return }
    if ConnectorSecretStore.setToken(value, for: connectorID) {
      draft = ""
      revision += 1
    }
  }

  private func clear() {
    if ConnectorSecretStore.setToken(nil, for: connectorID) {
      draft = ""
      revision += 1
    }
  }
}

// MARK: - Theme preview

/// A miniature of the app painted from a flavor's own palette: canvas, a floating pill with an
/// accent dot, and ink lines at three strengths. Selection rings in the flavor's accent.
private struct ThemePreviewCard: View {
  let theme: ComposerTheme
  let selected: Bool
  var action: () -> Void
  @State private var hovering = false

  var body: some View {
    let flavor = theme.flavor
    Button(action: action) {
      VStack(spacing: 0) {
        ZStack(alignment: .topLeading) {
          Color(nsColor: flavor.base)
          VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
              Circle().fill(Color(nsColor: flavor.accent)).frame(width: 6, height: 6)
              Capsule().fill(Color(nsColor: flavor.surface1)).frame(width: 30, height: 7)
            }
            .padding(.horizontal, 7).padding(.vertical, 5)
            .background(Capsule().fill(Color(nsColor: flavor.mantle)))
            .overlay(Capsule().strokeBorder(Color(nsColor: flavor.surface2).opacity(0.6), lineWidth: 0.5))

            VStack(alignment: .leading, spacing: 4) {
              RoundedRectangle(cornerRadius: 2).fill(Color(nsColor: flavor.text)).frame(width: 56, height: 5)
              RoundedRectangle(cornerRadius: 2).fill(Color(nsColor: flavor.subtext0)).frame(width: 40, height: 5)
              RoundedRectangle(cornerRadius: 2).fill(Color(nsColor: flavor.overlay0)).frame(width: 47, height: 5)
            }
            .padding(.leading, 3)
          }
          .padding(9)
        }
        .frame(height: 82)

        HStack(spacing: 6) {
          Text(theme.title)
            .font(.caption.weight(.medium))
            .foregroundStyle(Theme.Palette.body)
            .lineLimit(1)
          Spacer(minLength: 0)
          if selected {
            Image(systemName: "checkmark.circle.fill")
              .font(.system(size: 12))
              .foregroundStyle(Theme.Palette.accent)
          }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(Theme.Palette.rowFill)
      }
      .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .strokeBorder(
            selected ? Theme.Palette.accent : (hovering ? Theme.Palette.panelInnerLine : Theme.Palette.panelHairline),
            lineWidth: selected ? 2 : 1
          )
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
    .help(theme.title)
    .animation(.easeOut(duration: 0.12), value: hovering)
    .animation(.easeOut(duration: 0.12), value: selected)
  }
}

// MARK: - Styling helpers

/// A quiet neutral pill — the rail/dock idiom (white-on-glass wash, hairline rim), not an accent
/// chip. Used for secondary actions inside the panel.
private struct SettingsPillButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .background(
        Capsule().fill(configuration.isPressed ? Theme.Palette.buttonHover : Theme.Palette.keycapFill)
      )
      .overlay(Capsule().strokeBorder(Theme.Palette.panelHairline, lineWidth: 1))
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
          .strokeBorder(Theme.Palette.panelInnerLine, lineWidth: 1))
    }
  }

  /// Quiet categorical label above a group of rows. Dim, never accent.
  func sectionLabel() -> some View {
    self.font(.caption2.weight(.bold))
      .tracking(0.6)
      .foregroundStyle(Theme.Palette.count)
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
