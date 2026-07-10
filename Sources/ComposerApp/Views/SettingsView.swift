import SwiftUI

/// Settings as a centered glass sheet over the board — the System Settings shape (a sidebar of
/// sections, a pane of inset grouped rows) translated into BonsAI's language: one floating Liquid
/// Glass panel inside the canvas, never an auxiliary window. A faint scrim catches click-away, and
/// the sheet follows the same quiet-by-default voice as the rails — neutral surfaces, accent
/// reserved as a single signal (the selected section), brand marks for identity.
struct SettingsOverlay: View {
  /// The canvas size, so the sheet can size itself against the window.
  var canvasSize: CGSize
  var onClose: () -> Void

  /// Stored, not `@State`: theme/font switches rebuild the whole canvas (PanelController.applyTheme),
  /// which would reset transient state and bounce the sheet back to Runtime mid-click. Persisting the
  /// section also reopens Settings where you left it, the System Settings way.
  @AppStorage("settings.destination") private var destination: SettingsDestination = .runtime

  var body: some View {
    ZStack {
      // Click-away scrim — same weight as the ⌘K palette's.
      Color.black.opacity(0.12)
        .contentShape(Rectangle())
        .onTapGesture(perform: onClose)

      sheet
        .shadow(color: Theme.Shadow.panel.color, radius: Theme.Shadow.panel.radius, y: Theme.Shadow.panel.y)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var sheet: some View {
    HStack(spacing: 0) {
      sidebar
      Divider().overlay(Theme.Palette.separator)
      detail
    }
    .frame(width: sheetWidth, height: sheetHeight)
    .dockPanelSurface()
    .onExitCommand(perform: onClose)
  }

  private var sheetWidth: CGFloat {
    min(720, max(480, canvasSize.width - WindowChrome.edgeInset * 2 - 48))
  }

  private var sheetHeight: CGFloat {
    // Clear the top pills and the bottom command bar with room to spare.
    min(560, max(360, canvasSize.height - 140))
  }

  // MARK: Sidebar

  private var sidebar: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text("Settings".localizedUI)
        .font(.body.weight(.semibold))
        .foregroundStyle(Theme.Palette.body)
        .padding(.horizontal, 18)
        .frame(height: 52)

      VStack(spacing: 2) {
        ForEach(SettingsDestination.allCases) { item in
          SettingsSidebarRow(item: item, selected: destination == item) {
            destination = item
          }
        }
      }
      .padding(.horizontal, 10)

      Spacer(minLength: 8)

      // Identity footer in the mono "instrument" voice the rails use.
      Text("BonsAI \(Self.appVersion)")
        .font(.caption2.monospaced())
        .foregroundStyle(Theme.Palette.count)
        .padding(.horizontal, 18)
        .padding(.bottom, 14)
    }
    .frame(width: 178)
  }

  private static var appVersion: String {
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
  }

  // MARK: Detail

  private var detail: some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        Text(destination.title)
          .font(.title3.weight(.semibold))
          .foregroundStyle(Theme.Palette.body)
        Spacer(minLength: 8)
        Button(action: onClose) {
          Image(systemName: "xmark")
            .font(.caption.weight(.medium))
            .foregroundStyle(Theme.Palette.title)
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Close Settings  ·  Esc".localizedUI)
      }
      .padding(.leading, 20).padding(.trailing, 14)
      .frame(height: 52)

      Divider().overlay(Theme.Palette.separator)

      SettingsContent(destination: destination)
        .id(destination)
        .transition(.opacity)
    }
    .animation(Theme.Motion.accessory, value: destination)
  }
}

/// One sidebar section row — a neutral icon tile and a label, the System Settings rhythm in the
/// quiet idiom: the selected row carries a filled wash and an accent glyph; the rest brighten on
/// hover.
private struct SettingsSidebarRow: View {
  let item: SettingsDestination
  let selected: Bool
  var action: () -> Void
  @State private var hovering = false

  var body: some View {
    Button(action: action) {
      HStack(spacing: 9) {
        Image(systemName: item.symbol)
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(selected ? AnyShapeStyle(Theme.Palette.accent) : AnyShapeStyle(Theme.Palette.menuDesc))
          .frame(width: 24, height: 24)
          .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.Palette.tagFill)
          )
          .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
              .strokeBorder(Theme.Palette.panelInnerLine, lineWidth: 1)
          )
        Text(item.title)
          .font(.system(size: 13, weight: .medium))
          .foregroundStyle(selected || hovering ? Theme.Palette.body : Theme.Palette.menuDesc)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 8)
      .frame(height: 38)
      .background(
        RoundedRectangle(cornerRadius: 9, style: .continuous)
          .fill(selected ? Theme.Palette.keycapFill : (hovering ? Theme.Palette.hoverWash : Color.clear))
      )
      .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
    .help(item.title)
    .animation(.easeOut(duration: 0.12), value: hovering)
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
    case .runtime: "Runtime".localizedUI
    case .appearance: "Appearance".localizedUI
    case .connectors: "Connectors".localizedUI
    case .shortcuts: "Shortcuts".localizedUI
    case .about: "About".localizedUI
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
    ("Compile board".localizedUI, "⌘R"),
    ("New board".localizedUI, "⌘N"),
    ("Navigate boards".localizedUI, "⌘[  ⌘]"),
    ("Select all / duplicate".localizedUI, "⌘A  ⌘D"),
    ("Group / ungroup".localizedUI, "⌘G  ⇧⌘G"),
    ("Lock / unlock".localizedUI, "⌘L  ⇧⌘L"),
    ("App font: San Francisco".localizedUI, "⌃⌘1"),
    ("App font: Nohemi".localizedUI, "⌃⌘2"),
    ("App font: Satoshi".localizedUI, "⌃⌘3"),
  ]

  @StateObject private var appIcons = AppIconStore()
  @ObservedObject private var capabilities = EngineCapabilityStore.shared
  @ObservedObject private var shortcutStore = ShortcutStore.shared
  @ObservedObject private var updater = UpdaterController.shared
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
  @AppStorage(ComposerPreferences.appFontFamilyKey) private var appFontRaw = ComposerFontFamily.system.rawValue
  @AppStorage(ComposerPreferences.languageKey) private var languageRaw = AppLanguage.system.rawValue
  @AppStorage(ComposerPreferences.canvasTransparencyKey) private var canvasTransparency = 0.0
  @AppStorage(ComposerPreferences.followSystemAppearanceKey) private var followSystemAppearance = false
  /// The raw text-size preference. Written directly by the stepper; the change notification is
  /// posted from `.onChange` — AFTER the SwiftUI update transaction — because the observer
  /// rebuilds the whole canvas, and doing that synchronously from inside a binding setter tears
  /// down the very view committing the value (the stepper ate its own click).
  @AppStorage(ComposerPreferences.editorFontSizeKey) private var editorFontSize
    = Double(ComposerPreferences.defaultEditorFontSize)
  /// Whether the agent has standing "Always Allow" tool grants - drives the reset control's
  /// visibility. Refreshed in `onAppear`; flipped false the moment the user resets.
  @State private var agentHasGrants = false
  /// Bumped after an agent-skills install so `AgentSkillTarget.isInstalled` (a filesystem check,
  /// not a published property) re-reads and the row badges refresh.
  @State private var agentSkillsRevision = 0
  @State private var agentSkillsError: String?

  var body: some View {
    ScrollView {
      page
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
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

  /// A quiet sub-section intro inside a page: a plain heading and a single line of guidance.
  private func pageHeader(_ title: String, _ subtitle: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title.localizedUI).font(.headline).foregroundStyle(Theme.Palette.body)
      Text(subtitle.localizedUI)
        .font(.caption)
        .foregroundStyle(Theme.Palette.menuDesc)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  /// The inset divider between rows of one grouped card.
  private var rowDivider: some View {
    Divider().overlay(Theme.Palette.separator)
  }

  /// A group's explanatory footer, slightly inset like the System Settings idiom.
  private func groupFooter(_ text: String) -> some View {
    Text(text.localizedUI)
      .font(.caption)
      .foregroundStyle(Theme.Palette.count)
      .fixedSize(horizontal: false, vertical: true)
      .padding(.horizontal, 2)
  }

  // MARK: Runtime

  private var runtimePage: some View {
    let states = HeadlessEngine.allCases.map { capabilities.status(for: $0) } + [capabilities.appleIntelligence]
    let ready = states.filter { $0.isAvailable }.count

    return VStack(alignment: .leading, spacing: 22) {
      // Engines — one grouped card, the readout and recheck riding the section label row.
      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 8) {
          Text("ENGINES".localizedUI).sectionLabel()
          Spacer(minLength: 8)
          readout(ready: ready, total: states.count)
          Button(action: capabilities.refresh) {
            Label("Recheck".localizedUI, systemImage: "arrow.clockwise")
              .font(.caption.weight(.semibold))
              .foregroundStyle(Theme.Palette.body)
              .padding(.horizontal, 11)
              .frame(height: 26)
          }
          .buttonStyle(SettingsPillButtonStyle())
          .help("Re-scan this Mac for installed engines".localizedUI)
        }

        VStack(spacing: 0) {
          engineRow(
            name: HeadlessEngine.claude.title,
            command: HeadlessEngine.claude.commandLabel,
            availability: capabilities.status(for: .claude),
            toggle: $claudeEnabled
          ) { EngineLogo(engine: .claude).frame(width: 16, height: 16) }
          rowDivider
          engineRow(
            name: HeadlessEngine.codex.title,
            command: HeadlessEngine.codex.commandLabel,
            availability: capabilities.status(for: .codex),
            toggle: $codexEnabled
          ) { EngineLogo(engine: .codex).frame(width: 16, height: 16) }
          rowDivider
          engineRow(
            name: HeadlessEngine.opencode.title,
            command: HeadlessEngine.opencode.commandLabel,
            availability: capabilities.status(for: .opencode),
            toggle: $opencodeEnabled
          ) { EngineLogo(engine: .opencode).frame(width: 16, height: 16) }
          rowDivider
          engineRow(
            name: "Apple Intelligence".localizedUI,
            command: "semantic lint".localizedUI,
            availability: capabilities.appleIntelligence,
            toggle: nil
          ) {
            // The genuine Apple Intelligence mark — brand identity, the same rainbow the agent icon
            // uses — not decorative color. `apple.intelligence` is macOS 15+, so below the app's
            // 14 floor it falls back to `sparkles` rather than showing a missing-glyph box.
            Image(systemName: "apple.intelligence", fallback: "sparkles")
              .font(.system(size: 16, weight: .medium))
              .foregroundStyle(AngularGradient(
                gradient: Gradient(colors: [.orange, .red, .purple, .blue, .cyan, .orange]),
                center: .center))
          }
        }
        .padding(.horizontal, 13)
        .settingsCard()

        groupFooter("Only engines installed and answering on this Mac are offered. CLI prompts stay on your configured agent accounts; Apple Intelligence runs its lint on-device and never sends a draft off your Mac.")
      }

      modelsCard

      // Only appears once the agent has standing "Always Allow" grants - lets a user revoke them
      // without editing defaults by hand.
      if agentHasGrants {
        VStack(alignment: .leading, spacing: 8) {
          Text("PERMISSIONS".localizedUI).sectionLabel()
          HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
              Text("Agent tool permissions".localizedUI)
                .font(.callout.weight(.semibold)).foregroundStyle(Theme.Palette.body)
              Text("Tools you chose \"Always Allow\" for run without asking again.".localizedUI)
                .font(.caption).foregroundStyle(Theme.Palette.menuDesc)
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button {
              AgentPermissionBroker.resetRememberedGrants()
              agentHasGrants = false
            } label: {
              Label("Reset".localizedUI, systemImage: "arrow.counterclockwise")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.Palette.body)
                .padding(.horizontal, 11)
                .frame(height: 28)
            }
            .buttonStyle(SettingsPillButtonStyle())
            .help("Ask again next time the agent uses one of these tools".localizedUI)
          }
          .padding(.horizontal, 13)
          .padding(.vertical, 12)
          .settingsCard()
        }
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
      Text("MODELS".localizedUI).sectionLabel()
      VStack(spacing: 0) {
        surfaceRow(
          title: "Chat Agent".localizedUI,
          subtitle: "The agent you talk to in the canvas. Also switchable live in the Agent panel.".localizedUI,
          engineRaw: $chatEngineRaw,
          claudeModel: $chatModel, codexModel: $codexChatModel, opencodeModel: $opencodeChatModel)
      }
      .padding(.horizontal, 13)
      .settingsCard()
      if availableEngines.isEmpty {
        Text("No engine is enabled and installed. Enable one in Engines above.".localizedUI)
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
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .center, spacing: 14) {
        surfaceCopy(title: title, subtitle: subtitle)
          .frame(minWidth: 190, maxWidth: .infinity, alignment: .leading)
          .layoutPriority(1)
        if let engine {
          surfacePickers(engine: engine, engineRaw: engineRaw, claudeModel: claudeModel, codexModel: codexModel, opencodeModel: opencodeModel)
            .fixedSize()
        }
      }

      VStack(alignment: .leading, spacing: 12) {
        surfaceCopy(title: title, subtitle: subtitle)
        if let engine {
          surfacePickers(engine: engine, engineRaw: engineRaw, claudeModel: claudeModel, codexModel: codexModel, opencodeModel: opencodeModel)
        }
      }
    }
    .padding(.vertical, 11)
  }

  private func surfaceCopy(title: String, subtitle: String) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(title.localizedUI)
        .font(.callout.weight(.medium))
        .foregroundStyle(Theme.Palette.body)
        .lineLimit(2)
      Text(subtitle.localizedUI)
        .font(.caption)
        .foregroundStyle(Theme.Palette.menuDesc)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func surfacePickers(
    engine: HeadlessEngine,
    engineRaw: Binding<String>,
    claudeModel: Binding<ClaudeModel>,
    codexModel: Binding<String>,
    opencodeModel: Binding<String>
  ) -> some View {
    HStack(spacing: 10) {
      providerPicker(engineRaw, resolved: engine)
      modelPicker(for: engine, claudeModel: claudeModel, codexModel: codexModel, opencodeModel: opencodeModel)
    }
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
      Text("Default".localizedUI).tag("")
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
      Text("%d of %d ready".localizedUI(ready, total))
        .font(.caption.monospaced().weight(.semibold))
        .foregroundStyle(Theme.Palette.body)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 5)
    .background(Capsule().fill(Theme.Palette.segmentedFill))
  }

  /// One engine row of the grouped card: a neutral brand tile, name + status dot, the command in
  /// mono, and the enable switch. The logo is the color; the tile never lights up.
  private func engineRow<Icon: View>(
    name: String,
    command: String,
    availability: RuntimeAvailability,
    toggle: Binding<Bool>?,
    @ViewBuilder icon: () -> Icon
  ) -> some View {
    let available = availability.isAvailable

    return HStack(spacing: 11) {
      icon()
        .frame(width: 32, height: 32)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.Palette.tagFill))
        .overlay(
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(Theme.Palette.panelInnerLine, lineWidth: 1)
        )
        .opacity(available ? 1 : 0.4)
        .saturation(available ? 1 : 0.2)

      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 7) {
          Text(name).font(.callout.weight(.medium)).foregroundStyle(Theme.Palette.body)
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
    .padding(.vertical, 11)
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
        .help("On-device - never leaves your Mac".localizedUI)
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
      Text("Checking this Mac...".localizedUI)
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
    VStack(alignment: .leading, spacing: 22) {
      languageCard
      themeCard
      fontCard
      canvasGlassCard
    }
  }

  /// App language override. "System" uses macOS language preferences; explicit picks re-resolve
  /// BonsAI's bundled localizations immediately.
  private var languageCard: some View {
    VStack(alignment: .leading, spacing: 8) {
      pageHeader("Language", "Choose the language BonsAI uses. System follows macOS Language & Region.")
      HStack(spacing: 12) {
        Text("App language".localizedUI)
          .font(.callout.weight(.semibold))
          .foregroundStyle(Theme.Palette.body)
        Spacer(minLength: 12)
        Picker("", selection: $languageRaw) {
          ForEach(AppLanguage.allCases) { language in
            Text(language.title).tag(language.rawValue)
          }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .fixedSize()
        .tint(Theme.Palette.body)
      }
      .padding(14)
      .settingsCard()
    }
    .onChange(of: languageRaw) { _, _ in
      NotificationCenter.default.post(name: .composerLanguageChanged, object: nil)
    }
  }

  /// The app-font gallery: one specimen card per family, each "Aa" drawn in the family it selects,
  /// so the choice previews itself. Switching posts `composerFontFamilyChanged`, which rebuilds the
  /// canvas so every measurement cache and chrome label re-resolves.
  private var fontCard: some View {
    VStack(alignment: .leading, spacing: 8) {
      pageHeader("Font", "Pick the body font for cards, chrome, and the editor.")
      LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
        ForEach(ComposerFontFamily.allCases) { family in
          FontPreviewCard(family: family, selected: appFontRaw == family.rawValue) {
            Haptics.level()
            appFontRaw = family.rawValue
          }
        }
      }
      // The app-wide text size. This moved here from the ⌘+/⌘− shortcut, which now zooms the
      // canvas (as documented) instead of silently resizing every text card at once (#72).
      HStack(spacing: 12) {
        Text("Text size".localizedUI)
          .font(.callout.weight(.semibold))
          .foregroundStyle(Theme.Palette.body)
        Spacer(minLength: 12)
        Text("\(Int(editorFontSize)) pt")
          .font(.callout.monospacedDigit().weight(.semibold))
          .foregroundStyle(Theme.Palette.body)
        Stepper("", value: $editorFontSize,
                in: Double(ComposerPreferences.minEditorFontSize)...Double(ComposerPreferences.maxEditorFontSize),
                step: Double(ComposerPreferences.fontSizeStep))
          .labelsHidden()
      }
      .padding(14)
      .settingsCard()
    }
    .onChange(of: appFontRaw) { _, _ in
      NotificationCenter.default.post(name: .composerFontFamilyChanged, object: nil)
    }
    .onChange(of: editorFontSize) { _, _ in
      NotificationCenter.default.post(name: .composerFontSizeChanged, object: nil)
    }
  }

  /// Canvas background transparency — solid by default; the board behind this sheet updates live
  /// as the slider moves, so it is its own preview.
  private var canvasGlassCard: some View {
    VStack(alignment: .leading, spacing: 8) {
      pageHeader("Canvas",
                 "Let the desktop blur through the board surface. Solid keeps the flat canvas.")
      VStack(spacing: 12) {
        HStack(alignment: .firstTextBaseline) {
          Text("Background transparency".localizedUI).font(.callout.weight(.semibold)).foregroundStyle(Theme.Palette.body)
          Spacer(minLength: 12)
          Text("\(canvasTransparencyPercent)%")
            .font(.callout.monospacedDigit().weight(.semibold))
            .foregroundStyle(Theme.Palette.body)
        }
        Slider(value: $canvasTransparency, in: 0...ComposerPreferences.maxCanvasTransparency)
          .tint(Theme.Palette.accent)
        HStack {
          Text("Solid".localizedUI)
          Spacer()
          Text("Glass".localizedUI)
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
  /// Below it, "Match macOS appearance" swaps the pick for its light/dark sibling as the system
  /// switches — the gallery keeps showing the stored pick (the family), not the swap result.
  private var themeCard: some View {
    VStack(alignment: .leading, spacing: 8) {
      pageHeader("Theme", "Pick the palette for the whole app.")
      LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
        ForEach(ComposerTheme.allCases) { theme in
          ThemePreviewCard(theme: theme, selected: themeRaw == theme.rawValue) {
            themeRaw = theme.rawValue
          }
        }
      }
      HStack(spacing: 12) {
        VStack(alignment: .leading, spacing: 2) {
          Text("Match macOS appearance".localizedUI)
            .font(.callout.weight(.semibold))
            .foregroundStyle(Theme.Palette.body)
          Text("Swap to your theme's light or dark sibling when the system switches.".localizedUI)
            .font(.caption)
            .foregroundStyle(Theme.Palette.menuDesc)
        }
        Spacer(minLength: 12)
        Toggle("", isOn: $followSystemAppearance)
          .labelsHidden()
          .toggleStyle(.switch)
          .tint(Theme.Palette.accent)
      }
      .padding(14)
      .settingsCard()
    }
    .onChange(of: themeRaw) { _, _ in
      NotificationCenter.default.post(name: .composerThemeChanged, object: nil)
    }
    .onChange(of: followSystemAppearance) { _, _ in
      NotificationCenter.default.post(name: .composerThemeChanged, object: nil)
    }
  }

  // MARK: Connectors

  private var connectorsPage: some View {
    VStack(alignment: .leading, spacing: 22) {
      groupFooter("Type @ in a card to attach live context. Copied drafts become self-contained text - the source is resolved at copy time.")

      agentSkillsCard

      ForEach(MentionCatalog.appsByCategory, id: \.category) { group in
        VStack(alignment: .leading, spacing: 8) {
          Text(group.category.title.uppercased()).sectionLabel()
          VStack(spacing: 0) {
            ForEach(Array(group.items.enumerated()), id: \.element.id) { index, app in
              if index > 0 { rowDivider }
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
      Text("AGENT SKILLS".localizedUI).sectionLabel()
      VStack(spacing: 0) {
        ForEach(Array(AgentSkillTarget.allCases.enumerated()), id: \.element.id) { index, target in
          if index > 0 { rowDivider }
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
        Text(target.isDetected ? (installed ? "Skill installed".localizedUI : "Detected on this Mac".localizedUI) : "Not detected".localizedUI)
          .font(.caption).foregroundStyle(Theme.Palette.menuDesc)
      }
      Spacer(minLength: 8)
      Button(action: { installAgentSkill(target) }) {
        Text(installed ? "Reinstall".localizedUI : "Install".localizedUI)
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
      agentSkillsError = "%@: %@".localizedUI(target.displayName, error.localizedDescription)
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
    VStack(alignment: .leading, spacing: 22) {
      VStack(alignment: .leading, spacing: 8) {
        Text("SUMMON".localizedUI).sectionLabel()
        VStack(spacing: 0) {
          // The summon hotkey is user-configurable (records into ShortcutStore, which HotKeyManager
          // re-binds); the rest are fixed in-app commands shown for reference.
          HStack(spacing: 10) {
            Text("Summon Composer".localizedUI)
              .font(.callout.weight(.medium))
              .foregroundStyle(Theme.Palette.body)
              .lineLimit(1)
            Spacer(minLength: 8)
            ShortcutRecorder(shortcut: $shortcutStore.shortcut, defaultValue: .default)
          }
          .padding(.vertical, 11)

          rowDivider

          HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
              Text("Snap to board".localizedUI)
                .font(.callout.weight(.medium))
                .foregroundStyle(Theme.Palette.body)
                .lineLimit(1)
              Text("Capture a screen region - read on-device into an agent-ready card.".localizedUI)
                .font(.caption)
                .foregroundStyle(Theme.Palette.menuDesc)
                .lineLimit(1)
            }
            Spacer(minLength: 8)
            ShortcutRecorder(shortcut: $shortcutStore.captureShortcut, defaultValue: .defaultCapture)
          }
          .padding(.vertical, 11)
        }
        .padding(.horizontal, 13)
        .settingsCard()
      }

      VStack(alignment: .leading, spacing: 8) {
        Text("ON THE BOARD".localizedUI).sectionLabel()
        VStack(spacing: 0) {
          ForEach(Array(shortcuts.enumerated()), id: \.element.0) { index, pair in
            if index > 0 { rowDivider }
            HStack(spacing: 10) {
              Text(pair.0)
                .font(.callout.weight(.medium))
                .foregroundStyle(Theme.Palette.body)
                .lineLimit(1)
              Spacer(minLength: 8)
              Text(pair.1)
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
            .frame(minHeight: 42)
          }
        }
        .padding(.horizontal, 13)
        .settingsCard()
        groupFooter("The essentials for writing, arranging, and exporting without breaking flow.")
      }
    }
  }

  // MARK: About

  private var aboutPage: some View {
    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    let available = updater.availableUpdateVersion
    return VStack(alignment: .leading, spacing: 22) {
      VStack(alignment: .leading, spacing: 8) {
        Text("UPDATES".localizedUI).sectionLabel()
        VStack(spacing: 0) {
          // Identity + manual check — the version readout in the mono "instrument" voice the rails
          // use. When a scheduled check has an update waiting, the row flips to the accent signal
          // and the button becomes the install path (it opens Sparkle's update flow in focus).
          HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
              Text("BonsAI").font(.callout.weight(.semibold)).foregroundStyle(Theme.Palette.body)
              if let available {
                Text("Version %@ -> %@ available".localizedUI(version, available))
                  .font(.system(size: 10.5).monospaced())
                  .foregroundStyle(Theme.Palette.accent)
              } else {
                Text("Version %@".localizedUI(version))
                  .font(.system(size: 10.5).monospaced())
                  .foregroundStyle(Theme.Palette.menuDesc)
              }
            }
            Spacer(minLength: 8)
            Button(action: { updater.checkForUpdates() }) {
              Label(available == nil ? "Check for Updates".localizedUI : "Install Update".localizedUI,
                    systemImage: available == nil ? "arrow.triangle.2.circlepath" : "arrow.down.circle")
                .font(.caption.weight(.semibold))
                .foregroundStyle(available == nil ? Theme.Palette.body : Theme.Palette.accent)
                .padding(.horizontal, 11)
                .frame(height: 28)
            }
            .buttonStyle(SettingsPillButtonStyle())
            .help(available == nil
                  ? "Check GitHub for a newer BonsAI now".localizedUI
                  : "Install BonsAI %@".localizedUI(available ?? ""))
          }
          .padding(.vertical, 12)

          rowDivider

          // Automatic-check toggle, bound straight to Sparkle's scheduled-update preference.
          HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
              Text("Check automatically".localizedUI).font(.callout.weight(.medium)).foregroundStyle(Theme.Palette.body)
              Text("Look for updates daily in the background".localizedUI)
                .font(.caption2).foregroundStyle(Theme.Palette.menuDesc)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: Binding(
              get: { updater.automaticallyChecksForUpdates },
              set: { updater.automaticallyChecksForUpdates = $0 }))
              .labelsHidden()
              .toggleStyle(.switch)
              .controlSize(.small)
          }
          .padding(.vertical, 12)

          rowDivider

          // Automatic-install toggle — Sparkle downloads a found update on its own and finishes the
          // install on quit/relaunch. Meaningless without scheduled checks, so it dims with them.
          HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
              Text("Install automatically".localizedUI).font(.callout.weight(.medium)).foregroundStyle(Theme.Palette.body)
              Text("Download updates in the background and install on relaunch".localizedUI)
                .font(.caption2).foregroundStyle(Theme.Palette.menuDesc)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: Binding(
              get: { updater.automaticallyDownloadsUpdates },
              set: { updater.automaticallyDownloadsUpdates = $0 }))
              .labelsHidden()
              .toggleStyle(.switch)
              .controlSize(.small)
          }
          .disabled(!updater.automaticallyChecksForUpdates)
          .opacity(updater.automaticallyChecksForUpdates ? 1 : 0.5)
          .padding(.vertical, 12)
        }
        .padding(.horizontal, 13)
        .settingsCard()
        groupFooter("BonsAI checks GitHub for new releases automatically, then downloads and installs them in place.")
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
        SecureField(connected ? "Replace token...".localizedUI : label.localizedUI, text: $draft)
          .textFieldStyle(.plain)
          .font(.caption)
          .foregroundStyle(Theme.Palette.body)
          .padding(.horizontal, 9).padding(.vertical, 6)
          .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.Palette.segmentedFill))
          .onSubmit(save)
        Button("Save".localizedUI, action: save)
          .buttonStyle(.plain)
          .font(.caption.weight(.semibold))
          .foregroundStyle(draft.trimmed.isEmpty ? Theme.Palette.menuDesc : Theme.Palette.accent)
          .disabled(draft.trimmed.isEmpty)
        if connected {
          Button("Clear".localizedUI, action: clear)
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(Theme.Palette.menuDesc)
        }
      }
      HStack(spacing: 6) {
        Circle()
          .fill(connected ? Color.green.opacity(0.9) : Theme.Palette.menuDesc.opacity(0.5))
          .frame(width: 6, height: 6)
        Text(connected ? "Connected".localizedUI : hint.localizedUI)
          .font(.caption2)
          .foregroundStyle(Theme.Palette.menuDesc)
        if let createURL, let url = URL(string: createURL) {
          Spacer(minLength: 8)
          Link("Get a token".localizedUI, destination: url)
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
          Text(theme.title.localizedUI)
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
    .help(theme.title.localizedUI)
    .animation(.easeOut(duration: 0.12), value: hovering)
    .animation(.easeOut(duration: 0.12), value: selected)
  }
}

/// One app-font specimen card, mirroring `ThemePreviewCard`'s selection language (accent stroke on
/// select, hairline otherwise; a checkmark on the name row). The large "Aa" is drawn in the option's
/// own face so each card previews exactly the font it selects.
private struct FontPreviewCard: View {
  let family: ComposerFontFamily
  let selected: Bool
  var action: () -> Void
  @State private var hovering = false

  var body: some View {
    Button(action: action) {
      VStack(spacing: 0) {
        ZStack {
          Color(nsColor: Theme.flavor.mantle)
          Text("Aa")
            .font(ComposerPreferences.previewFont(for: family, size: 28, weight: .medium))
            .foregroundStyle(Theme.Palette.body)
        }
        .frame(height: 82)

        HStack(spacing: 6) {
          Text(family.title.localizedUI)
            .font(WindowChrome.labelFont)
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
    .help(family.title.localizedUI)
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
  /// Subtle raised tile for the grouped cards inside the pane, over the frosted glass.
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
