import SwiftUI

/// The floating capsule that appears above a text selection.
struct SelectionActionBar: View {
  var isWorking: Bool
  var onRefine: (HeadlessEngine) -> Void
  var onCopy: () -> Void

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
          Text("No engines enabled")
            .font(Theme.Typography.actionLabel)
            .foregroundStyle(Theme.Palette.menuDesc)
            .padding(.horizontal, 10)
            .frame(height: Theme.Size.actionBarItemHeight)
        }
        Divider().frame(height: 16).opacity(0.35)
        iconAction(icon: "doc.on.doc", help: "Copy self-contained text", run: onCopy)
      }
    }
    .padding(.horizontal, 5)
    .frame(height: Theme.Size.actionBarHeight)
    .floatingGlass(RoundedRectangle(cornerRadius: Theme.Radius.actionBar, style: .continuous))
    .scaleEffect(shown ? 1 : 0.94, anchor: .bottom)
    .opacity(shown ? 1 : 0)
    .onAppear { withAnimation(Theme.Motion.accessory) { shown = true } }
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
