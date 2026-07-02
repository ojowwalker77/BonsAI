import SwiftUI

/// The floating capsule that appears above a text selection.
struct SelectionActionBar: View {
  var isWorking: Bool
  var onRefine: (HeadlessEngine) -> Void
  /// The editing card's current tint slot; picking a swatch re-inks the whole card.
  var currentTint: Int?
  var onTint: (Int?) -> Void

  @AppStorage(EnginePreferences.claudeEnabledKey) private var claudeEnabled = true
  @AppStorage(EnginePreferences.codexEnabledKey) private var codexEnabled = true
  @ObservedObject private var capabilities = EngineCapabilityStore.shared
  @State private var shown = false

  private var enabledEngines: [HeadlessEngine] {
    HeadlessEngine.allCases.filter { engine in
      let enabled = switch engine {
      case .claude: claudeEnabled
      case .codex: codexEnabled
      }
      return enabled && capabilities.isAvailable(engine)
    }
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

        // Text ink: the default plus the theme's tint slots. Stored as a slot index, so the
        // color re-resolves when the theme changes.
        tintSwatch(nil)
        ForEach(Theme.flavor.tints.indices, id: \.self) { slot in
          tintSwatch(slot)
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
      if !claudeEnabled && !codexEnabled {
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

  private func tintSwatch(_ slot: Int?) -> some View {
    let color = Theme.tintColor(slot).map { Color(nsColor: $0) } ?? Theme.Palette.body
    let selected = currentTint == slot
    return Button(action: { Haptics.tap(); onTint(slot) }) {
      Circle()
        .fill(color)
        .frame(width: 13, height: 13)
        .overlay(Circle().strokeBorder(Theme.Palette.panelHairline, lineWidth: 1))
        .overlay(
          Circle()
            .strokeBorder(selected ? Theme.Palette.accent : Color.clear, lineWidth: 1.5)
            .frame(width: 19, height: 19)
        )
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
