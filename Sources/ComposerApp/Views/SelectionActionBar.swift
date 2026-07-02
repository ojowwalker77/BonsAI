import SwiftUI

/// The floating capsule that appears above a text selection.
struct SelectionActionBar: View {
  var isWorking: Bool
  var onRefine: (HeadlessEngine) -> Void
  /// Markdown formatting for the selection (heading/bold/italic/code/quote).
  var onFormat: (MarkdownStyle.Action) -> Void
  /// The editing card's current tint slot; picking a swatch re-inks the whole card.
  var currentTint: Int?
  var onTint: (Int?) -> Void

  /// The color picker rides collapsed (one swatch) and expands in place on click.
  @State private var tintExpanded = false

  @AppStorage(EnginePreferences.claudeEnabledKey) private var claudeEnabled = true
  @AppStorage(EnginePreferences.codexEnabledKey) private var codexEnabled = true
  @AppStorage(EnginePreferences.opencodeEnabledKey) private var opencodeEnabled = true
  @ObservedObject private var capabilities = EngineCapabilityStore.shared
  @State private var shown = false

  /// Read through the observed `@AppStorage` toggles (not `EnginePreferences.isEnabled`) so the bar
  /// re-renders the moment a toggle flips in Settings.
  private func isEnabled(_ engine: HeadlessEngine) -> Bool {
    switch engine {
    case .claude: claudeEnabled
    case .codex: codexEnabled
    case .opencode: opencodeEnabled
    }
  }

  private var enabledEngines: [HeadlessEngine] {
    HeadlessEngine.allCases.filter { isEnabled($0) && capabilities.isAvailable($0) }
  }

  var body: some View {
    HStack(spacing: 2) {
      if isWorking {
        HStack(spacing: 7) {
          ProgressView().controlSize(.small).scaleEffect(0.7)
          Text("Refining\u{2026}").font(Theme.Typography.actionLabel)
        }
        .padding(.horizontal, 12)
        .frame(height: Theme.Size.actionBarItemHeight)
        .foregroundStyle(Theme.Palette.body)
      } else {
        ForEach(enabledEngines) { engine in
          action(engine: engine) { onRefine(engine) }
        }
        if enabledEngines.isEmpty {
          Text(unavailableEngineMessage)
            .font(Theme.Typography.actionLabel)
            .foregroundStyle(Theme.Palette.menuDesc)
            .padding(.horizontal, 10)
            .frame(height: Theme.Size.actionBarItemHeight)
        }
        Divider().frame(height: 16).opacity(0.35)

        // Markdown formatting — literal syntax in the plain text, styled live.
        iconAction(icon: "textformat.size", help: "Heading  ·  cycles # / ## / ###") { onFormat(.heading) }
        iconAction(icon: "bold", help: "Bold  ·  **text**") { onFormat(.bold) }
        iconAction(icon: "italic", help: "Italic  ·  *text*") { onFormat(.italic) }
        iconAction(icon: "chevron.left.forwardslash.chevron.right", help: "Code  ·  `text`") { onFormat(.code) }
        iconAction(icon: "text.quote", help: "Quote  ·  > line") { onFormat(.quote) }

        Divider().frame(height: 16).opacity(0.35)

        // Text ink: collapsed to the current swatch; expands to the theme's slots on click.
        if tintExpanded {
          tintSwatch(nil)
          ForEach(Theme.flavor.tints.indices, id: \.self) { slot in
            tintSwatch(slot)
          }
        } else {
          Button(action: { Haptics.tap(); withAnimation(.easeOut(duration: 0.14)) { tintExpanded = true } }) {
            swatchCircle(for: currentTint, selected: false)
              .frame(width: 26, height: Theme.Size.actionBarItemHeight)
              .contentShape(Rectangle())
          }
          .buttonStyle(HoverButtonStyle())
          .help("Text color")
        }
      }
    }
    .padding(.horizontal, 5)
    .frame(height: Theme.Size.actionBarHeight)
    .floatingGlass(RoundedRectangle(cornerRadius: Theme.Radius.actionBar, style: .continuous))
    .scaleEffect(shown ? 1 : 0.94, anchor: .bottom)
    .opacity(shown ? 1 : 0)
    .onAppear { withAnimation(Theme.Motion.accessory) { shown = true } }
  }

  private var unavailableEngineMessage: String {
    if enabledEngines.isEmpty {
      if HeadlessEngine.allCases.allSatisfy({ !isEnabled($0) }) {
        return "All engines disabled in Settings → Runtime"
      }
      return "No engines ready — open Settings → Runtime → Recheck"
    }
    return "No engines ready"
  }

  @ViewBuilder
  private func action(engine: HeadlessEngine, run: @escaping () -> Void) -> some View {
    Button(action: run) {
      HStack(spacing: 6) {
        EngineLogo(engine: engine)
        Text(engine.title).font(Theme.Typography.actionLabel)
      }
      .padding(.horizontal, 10)
      .frame(height: Theme.Size.actionBarItemHeight)
      .contentShape(Rectangle())
    }
    .buttonStyle(HoverButtonStyle())
    .foregroundStyle(Theme.Palette.body)
  }

  private func swatchCircle(for slot: Int?, selected: Bool) -> some View {
    let color = Theme.tintColor(slot).map { Color(nsColor: $0) } ?? Theme.Palette.body
    return Circle()
      .fill(color)
      .frame(width: 13, height: 13)
      .overlay(Circle().strokeBorder(Theme.Palette.panelHairline, lineWidth: 1))
      .overlay(
        Circle()
          .strokeBorder(selected ? Theme.Palette.accent : Color.clear, lineWidth: 1.5)
          .frame(width: 19, height: 19)
      )
  }

  private func tintSwatch(_ slot: Int?) -> some View {
    Button(action: {
      Haptics.tap()
      onTint(slot)
      withAnimation(.easeOut(duration: 0.14)) { tintExpanded = false }
    }) {
      swatchCircle(for: slot, selected: currentTint == slot)
        .frame(width: 22, height: Theme.Size.actionBarItemHeight)
        .contentShape(Rectangle())
    }
    .buttonStyle(HoverButtonStyle())
    .help(slot == nil ? "Default ink" : "Theme color \((slot ?? 0) + 1)")
  }

  @ViewBuilder
  private func iconAction(icon: String, help: String, run: @escaping () -> Void) -> some View {
    Button(action: run) {
      Image(systemName: icon)
        .font(Theme.Typography.actionIcon)
        .frame(width: 30, height: Theme.Size.actionBarItemHeight)
        .contentShape(Rectangle())
    }
    .buttonStyle(HoverButtonStyle())
    .foregroundStyle(Theme.Palette.body)
    .help(help)
  }
}

/// A soft hover wash for the bar's buttons.
struct HoverButtonStyle: ButtonStyle {
  @State private var hovering = false
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .background(
        RoundedRectangle(cornerRadius: 7, style: .continuous)
          .fill(hovering || configuration.isPressed ? Theme.Palette.buttonHover : Color.clear)
      )
      .onHover { hovering = $0 }
      .animation(.easeOut(duration: 0.12), value: hovering)
  }
}
