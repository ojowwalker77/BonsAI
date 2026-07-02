import SwiftUI
import AppKit

/// The agent chat panel floating over the canvas. Modern chat layout: a slim identity header,
/// the transcript, and one input container that carries the composer plus its context controls
/// (model, grounding) on a bottom row — like every current chat app, instead of a pill-crowded
/// header.
struct AgentDock: View {
  @ObservedObject var agent: CanvasAgent
  /// Sized by the canvas relative to the window so the dock adapts to the display.
  var width: CGFloat
  var onClose: () -> Void
  @State private var draft = ""
  @FocusState private var inputFocused: Bool
  /// The Claude model the agent runs on when the chat is on Claude. Shares its key with the Settings ▸
  /// Runtime picker, so the two always read back the same value (see [[ModelPreferences]]); Codex and
  /// OpenCode use their own picks below. `CanvasAgent` reads it at send.
  @AppStorage(ModelPreferences.chatModelKey) private var chatModel: ClaudeModel = ModelPreferences.defaultChatModel
  /// Which engine the streaming chat runs on. Empty ⇒ auto (preference order). Mirrored by
  /// `CanvasAgent.resolvedEngine()` and the leading `AgentEngineIcon`.
  @AppStorage(EnginePreferences.chatEngineKey) private var chatEngineRaw = ""
  /// Per-engine model picks (empty ⇒ that engine's own default). Same keys `CanvasChatEngine` reads.
  @AppStorage("model.chat.codex") private var codexModelRaw = ""
  @AppStorage("model.chat.opencode") private var opencodeModelRaw = ""
  @ObservedObject private var capabilities = EngineCapabilityStore.shared
  @ObservedObject private var modelCatalog = ChatModelCatalog.shared

  /// Keep the grounding chip compact: at most 12 characters, then an ellipsis.
  static func trimmed(_ name: String) -> String {
    name.count > 12 ? String(name.prefix(12)) + "\u{2026}" : name
  }

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider().overlay(Theme.Palette.separator)
      // The message list observes the transcript directly, so a streamed token re-renders only it —
      // not this dock's header/input, and never the canvas (which observes the agent's coarse state).
      AgentTranscriptView(
        transcript: agent.transcript,
        isRunning: agent.isRunning,
        onSuggest: { agent.send($0) }
      )
      inputArea
    }
    .frame(width: width)
    .frame(maxHeight: .infinity)
    // Liquid Glass floating over the canvas; its own drop shadow grounds it.
    .dockPanelSurface()
  }

  // MARK: Header — identity only; context controls live with the composer below.

  private var header: some View {
    HStack(spacing: 9) {
      AgentEngineIcon(size: 16)
      Text("Agent").font(.callout.weight(.semibold)).foregroundStyle(Theme.Palette.body)
      if agent.isRunning { ProgressView().controlSize(.small).scaleEffect(0.55) }
      Spacer(minLength: 8)
      iconButton("arrow.counterclockwise", help: "New conversation") { agent.reset(); draft = "" }
      iconButton("xmark", help: "Close  ⌘J", action: onClose)
    }
    .padding(.leading, 14).padding(.trailing, 10).frame(height: 46)
  }

  // MARK: Input — one container: composer on top, context chips + send below.

  private var inputArea: some View {
    VStack(alignment: .leading, spacing: 9) {
      TextField("Message the agent…", text: $draft, axis: .vertical)
        .textFieldStyle(.plain)
        .lineLimit(1...6)
        .font(.callout)
        .foregroundStyle(Theme.Palette.body)
        .focused($inputFocused)
        // Enter sends; Shift+Enter inserts a newline at the caret — the standard chat convention
        // (Slack, Discord, Linear). We must handle BOTH keys ourselves. Returning `.ignored` for
        // Shift+Return (the previous fix) let the event fall through to the field editor, which on a
        // Return selected all the text instead of breaking the line. So for Shift+Return we insert the
        // line break directly into the focused field editor — while editing, the key window's first
        // responder is the NSTextView backing this TextField (the panel relies on the same fact, see
        // FloatingPanel.performKeyEquivalent). The insert routes through the normal text-change path,
        // so `draft` updates and the field auto-grows. See https://github.com/ojowwalker77/BonsAI/issues/27.
        .onKeyPress(.return, phases: .down) { keyPress in
          guard keyPress.modifiers.contains(.shift) else { submit(); return .handled }
          if let editor = NSApp.keyWindow?.firstResponder as? NSTextView {
            editor.insertNewlineIgnoringFieldEditor(nil)
          } else {
            draft.append("\n")   // fallback: no field editor in reach — append rather than drop the break
          }
          return .handled
        }

      HStack(spacing: 6) {
        engineChip
        modelChip
        groundingChip
        Spacer(minLength: 8)
        sendButton
      }
    }
    .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 8)
    .background(RoundedRectangle(cornerRadius: WindowChrome.radius, style: .continuous).fill(Theme.Palette.rowFill))
    .overlay(RoundedRectangle(cornerRadius: WindowChrome.radius, style: .continuous).strokeBorder(Theme.Palette.panelHairline, lineWidth: 1))
    .padding(12)
    .onAppear {
      inputFocused = true
      // Prefetch OpenCode's model list so its picker is populated before it's opened (a Menu's own
      // onAppear is unreliable). Cheap and cached.
      modelCatalog.loadOpenCodeModelsIfNeeded()
    }
  }

  /// The engines the chat can run on right now: enabled in Settings *and* installed on this Mac.
  private var availableEngines: [HeadlessEngine] {
    HeadlessEngine.allCases.filter { EnginePreferences.isEnabled($0) && capabilities.isAvailable($0) }
  }

  /// A quiet capsule menu — same idiom as the model chip — to switch which coding-agent CLI backs the
  /// chat. Only shown when there's a real choice (2+ engines ready); with one engine the header's
  /// brand mark already says which. Picking writes the shared `engine.chat.selected` preference.
  @ViewBuilder
  private var engineChip: some View {
    let engines = availableEngines
    if engines.count >= 2, let active = CanvasAgent.resolvedEngine() {
      Menu {
        Picker("Engine", selection: Binding(get: { active }, set: { chatEngineRaw = $0.rawValue })) {
          ForEach(engines, id: \.self) { engine in Text(engine.title).tag(engine) }
        }
      } label: {
        HStack(spacing: 4) {
          EngineLogo(engine: active)
          Text(active.title).font(.caption.weight(.medium)).lineLimit(1).fixedSize()
          Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold))
        }
        .foregroundStyle(Theme.Palette.menuDesc)
        .padding(.horizontal, 9).frame(height: 22)
        .background(Capsule().fill(Theme.Palette.keycapFill))
        .contentShape(Capsule())
      }
      .menuStyle(.button)
      .buttonStyle(.plain)
      .menuIndicator(.hidden)
      .fixedSize()
      .help("Engine for the agent chat — Claude, Codex, or OpenCode")
    }
  }

  /// The model chip for whichever engine is active: Claude keeps its Opus/Sonnet/Haiku tiers; Codex
  /// and OpenCode get a provider/model picker (`opencode models`; the Codex config model).
  @ViewBuilder
  private var modelChip: some View {
    switch CanvasAgent.resolvedEngine() {
    case .claude, .none: claudeModelChip
    case .codex: engineModelChip(.codex, selection: $codexModelRaw)
    case .opencode: engineModelChip(.opencode, selection: $opencodeModelRaw)
    }
  }

  /// Quiet Claude model selector chip: the current tier + a chevron, checkmarked menu on click.
  private var claudeModelChip: some View {
    Menu {
      Picker("Model", selection: $chatModel) {
        ForEach(ClaudeModel.allCases) { model in
          Text(model.title).tag(model)
        }
      }
    } label: {
      chipLabel { Text(chatModel.title).font(.caption.weight(.medium)).lineLimit(1).fixedSize() }
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .menuIndicator(.hidden)
    .fixedSize()
    .help("Model for the agent chat — mirrors Settings ▸ Runtime")
  }

  /// A provider/model chip for Codex / OpenCode, styled like the Claude chip. "Default" leaves the
  /// engine on its own default; OpenCode's list comes from `opencode models`.
  @ViewBuilder
  private func engineModelChip(_ engine: HeadlessEngine, selection raw: Binding<String>) -> some View {
    let label = raw.wrappedValue.isEmpty ? "Default" : Self.shortModel(raw.wrappedValue)
    Menu {
      Picker("Model", selection: raw) {
        Text("Default").tag("")
        ForEach(modelCatalog.models(for: engine), id: \.self) { Text(Self.shortModel($0)).tag($0) }
      }
    } label: {
      chipLabel { Text(label).font(.caption.weight(.medium)).lineLimit(1).fixedSize() }
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .menuIndicator(.hidden)
    .fixedSize()
    .help("Model for \(engine.title) — from its provider list")
    .onAppear { if engine == .opencode { modelCatalog.loadOpenCodeModelsIfNeeded() } }
  }

  /// The shared chip shell: content + chevron in a keycap capsule, matching the grounding chip.
  private func chipLabel<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    HStack(spacing: 4) {
      content()
      Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold))
    }
    .foregroundStyle(Theme.Palette.menuDesc)
    .padding(.horizontal, 9).frame(height: 22)
    .background(Capsule().fill(Theme.Palette.keycapFill))
    .contentShape(Capsule())
  }

  /// Compact model label: the id's last path component, clamped. `opencode/big-pickle` → `big-pickle`.
  private static func shortModel(_ id: String) -> String {
    let name = id.split(separator: "/").last.map(String.init) ?? id
    return name.count > 16 ? String(name.prefix(16)) + "\u{2026}" : name
  }

  /// Grounding chip: folder name (click to change) + ✕ to un-ground; a quiet add-chip when unset.
  @ViewBuilder
  private var groundingChip: some View {
    if let dir = agent.groundingDirectory {
      HStack(spacing: 6) {
        Button { agent.chooseDirectory() } label: {
          HStack(spacing: 4) {
            Image(systemName: "folder.fill").font(.system(size: 9.5))
            Text(Self.trimmed(dir.lastPathComponent)).font(.caption.weight(.medium)).lineLimit(1).fixedSize()
          }
          .foregroundStyle(Theme.Palette.menuDesc)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Grounded in \(dir.path) — click to change")

        Button { agent.setGroundingDirectory(nil) } label: {
          Image(systemName: "xmark")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(Theme.Palette.title)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Remove grounding — back to canvas-only")
      }
      .padding(.horizontal, 9).frame(height: 22)
      .background(Capsule().fill(Theme.Palette.keycapFill))
    } else {
      Button { agent.chooseDirectory() } label: {
        HStack(spacing: 4) {
          Image(systemName: "folder.badge.plus").font(.system(size: 9.5))
          Text("Ground").font(.caption.weight(.medium))
        }
        .foregroundStyle(Theme.Palette.menuDesc)
        .padding(.horizontal, 9).frame(height: 22)
        .background(Capsule().fill(Theme.Palette.keycapFill))
        .contentShape(Capsule())
      }
      .buttonStyle(.plain)
      .help("Ground the agent in a folder it can read")
    }
  }

  /// Modern send affordance: an accent-filled circle that reads as THE action; morphs into a
  /// stop control while the agent runs.
  private var sendButton: some View {
    Group {
      if agent.isRunning {
        Button(action: agent.stop) {
          Image(systemName: "stop.fill")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(Theme.Palette.body)
            .frame(width: 26, height: 26)
            .background(Circle().fill(Theme.Palette.keycapFill))
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Stop")
      } else {
        Button(action: submit) {
          Image(systemName: "arrow.up")
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(canSend ? Color.white : Theme.Palette.chromeGlyphDim)
            .frame(width: 26, height: 26)
            .background(Circle().fill(canSend ? Theme.Palette.accent : Theme.Palette.keycapFill))
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!canSend)
        .help("Send  ·  ⇧↩ for a new line")
      }
    }
    .animation(.easeOut(duration: 0.12), value: canSend)
  }

  private var canSend: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

  private func submit() {
    let text = draft
    draft = ""
    agent.send(text)
    inputFocused = true
  }

  private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: symbol).font(.caption.weight(.medium))
        .foregroundStyle(Theme.Palette.title).frame(width: 24, height: 24).contentShape(Rectangle())
    }
    .buttonStyle(.plain).help(help)
  }
}

// MARK: - Transcript

/// The scrolling message list. Split into its own view that observes only the `AgentTranscript`,
/// so the high-frequency streaming updates re-render just this list — not the dock chrome around it,
/// and never the canvas (which observes the agent only for coarse `isRunning`/grounding state).
private struct AgentTranscriptView: View {
  @ObservedObject var transcript: AgentTranscript
  let isRunning: Bool
  /// Empty-state suggestion chips send their prompt straight to the agent.
  var onSuggest: (String) -> Void

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 11) {
          if transcript.messages.isEmpty { emptyState }
          ForEach(transcript.messages) { bubble($0).id($0.id) }
          if isRunning { thinkingRow.id("thinking") }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .scrollIndicators(.never)
      .onChange(of: transcript.messages.count) { _, _ in scrollToEnd(proxy) }
      .onChange(of: isRunning) { _, running in if running { scrollToEnd(proxy) } }
    }
  }

  private func scrollToEnd(_ proxy: ScrollViewProxy) {
    withAnimation(.easeOut(duration: 0.18)) {
      if isRunning { proxy.scrollTo("thinking", anchor: .bottom) }
      else { proxy.scrollTo(transcript.messages.last?.id, anchor: .bottom) }
    }
  }

  private var emptyState: some View {
    VStack(alignment: .leading, spacing: 14) {
      VStack(alignment: .leading, spacing: 5) {
        Text("Think out loud").font(.body.weight(.semibold)).foregroundStyle(Theme.Palette.body)
        Text("The agent reads your board and edits it as you talk — adding, sharpening, and connecting cards.")
          .font(.caption).foregroundStyle(Theme.Palette.menuDesc)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      VStack(alignment: .leading, spacing: 6) {
        SuggestionChip(text: "Read my board and tell me what's missing", onSuggest: onSuggest)
        SuggestionChip(text: "Tidy the board and group related cards", onSuggest: onSuggest)
        SuggestionChip(text: "Turn my notes into a build plan", onSuggest: onSuggest)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, 8)
  }

  @ViewBuilder
  private func bubble(_ message: AgentMessage) -> some View {
    switch message.role {
    case .user:
      Text(message.text)
        .font(.callout).foregroundStyle(Theme.Palette.body)
        .padding(.horizontal, 11).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Theme.Palette.accent.opacity(0.20)))
        .frame(maxWidth: .infinity, alignment: .trailing)
    case .assistant:
      Text(Self.markdown(message.text))
        .font(.callout).foregroundStyle(Theme.Palette.body).textSelection(.enabled)
        .lineSpacing(2.5)
        .tint(Theme.Palette.accent)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    case .tool:
      // One compact line per tool call: the summary never wraps — it truncates with an ellipsis,
      // and the full text is available on hover.
      HStack(spacing: 7) {
        Image(systemName: "wand.and.sparkles", fallback: "wand.and.stars").font(.system(size: 10))
        Text(message.text).font(.caption).lineLimit(1).truncationMode(.tail)
        Spacer(minLength: 0)
      }
      .foregroundStyle(Theme.Palette.title)
      .padding(.horizontal, 9).padding(.vertical, 5)
      .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.Palette.rowFill))
      .frame(maxWidth: .infinity, alignment: .leading)
      .help(message.text)
    case .error:
      Text(message.text)
        .font(.caption).foregroundStyle(.orange)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private var thinkingRow: some View {
    HStack(spacing: 7) {
      ProgressView().controlSize(.small).scaleEffect(0.6)
      Text("thinking…").font(.caption).foregroundStyle(Theme.Palette.menuDesc)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  /// Render inline markdown (**bold**, `code`, _italic_, links) while keeping newlines.
  private static func markdown(_ text: String) -> AttributedString {
    (try? AttributedString(
      markdown: text,
      options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
  }
}

/// One tappable starter prompt on the empty state. Hover feedback is the trackpad tick — the
/// chip's quiet row fill never changes.
private struct SuggestionChip: View {
  let text: String
  var onSuggest: (String) -> Void

  var body: some View {
    Button { onSuggest(text) } label: {
      HStack(spacing: 7) {
        Image(systemName: "arrow.up.right")
          .font(.system(size: 9, weight: .semibold))
          .foregroundStyle(Theme.Palette.accent)
        Text(text).font(.caption).foregroundStyle(Theme.Palette.body).lineLimit(1)
      }
      .padding(.horizontal, 10).frame(height: 28)
      .background(Capsule().fill(Theme.Palette.rowFill))
      .overlay(Capsule().strokeBorder(Theme.Palette.panelHairline, lineWidth: 1))
      .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .onHover { if $0 { Haptics.hover() } }
  }
}
