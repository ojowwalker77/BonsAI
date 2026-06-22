import SwiftUI

/// The companion chat window for the canvas. You talk; it edits the board via the canvas MCP while
/// remaining a distinct, right-docked glass panel.
struct AgentDock: View {
  @ObservedObject var agent: CanvasAgent
  /// Sized by the canvas relative to the window so the dock adapts to the display.
  var width: CGFloat
  var onClose: () -> Void
  @State private var draft = ""
  @FocusState private var inputFocused: Bool

  /// Keep the grounding pill compact: at most 8 characters, then an ellipsis.
  static func trimmed(_ name: String) -> String {
    name.count > 8 ? String(name.prefix(8)) + "\u{2026}" : name
  }

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider().overlay(Theme.Palette.separator)
      transcript
      inputBar
    }
    .frame(width: width)
    .frame(maxHeight: .infinity)
    // Identical glass to the main window — same frosted treatment, tint, and corner radius — so the
    // dock reads as a second panel floating beside the card. The panel's own drop shadow grounds it.
    .background(ComposerPanelBackground(radius: Theme.Radius.panel))
    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
  }

  // MARK: Header

  private var header: some View {
    HStack(spacing: 10) {
      AgentEngineIcon(size: 17)
      Text("Agent").font(.body.weight(.semibold)).foregroundStyle(Theme.Palette.body)
      if agent.isRunning { ProgressView().controlSize(.small).scaleEffect(0.62) }
      Spacer(minLength: 8)
      groundingControl
      HStack(spacing: 2) {
        iconButton("arrow.counterclockwise", help: "New conversation") { agent.reset(); draft = "" }
        iconButton("xmark", help: "Close  ⌘J", action: onClose)
      }
    }
    .padding(.leading, 16).padding(.trailing, 12).frame(height: 52)
  }

  @ViewBuilder
  private var groundingControl: some View {
    if let dir = agent.groundingDirectory {
      // One capsule, two targets: the name changes the folder; the trailing ✕ un-grounds the
      // board back to canvas-only. (Before, there was no way to remove a grounding once set.)
      HStack(spacing: 6) {
        Button { agent.chooseDirectory() } label: {
          HStack(spacing: 5) {
            Image(systemName: "folder.fill").font(.system(size: 10.5))
            Text(Self.trimmed(dir.lastPathComponent)).font(.caption.weight(.medium)).lineLimit(1).fixedSize()
          }
          .foregroundStyle(Theme.Palette.body)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Grounded in \(dir.path) — click to change")

        Button { agent.setGroundingDirectory(nil) } label: {
          Image(systemName: "xmark")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(Theme.Palette.title)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Remove grounding — back to canvas-only")
      }
      .padding(.horizontal, 9).frame(height: 24)
      .background(Capsule().fill(Color.white.opacity(0.08)))
      .overlay(Capsule().strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
    } else {
      iconButton("folder.badge.plus", help: "Ground the agent in a folder it can read") { agent.chooseDirectory() }
    }
  }

  // MARK: Transcript

  private var transcript: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 11) {
          if agent.messages.isEmpty { emptyState }
          ForEach(agent.messages) { bubble($0).id($0.id) }
          if agent.isRunning { thinkingRow.id("thinking") }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .scrollIndicators(.never)
      .onChange(of: agent.messages.count) { _, _ in scrollToEnd(proxy) }
      .onChange(of: agent.isRunning) { _, running in if running { scrollToEnd(proxy) } }
    }
  }

  private func scrollToEnd(_ proxy: ScrollViewProxy) {
    withAnimation(.easeOut(duration: 0.18)) {
      if agent.isRunning { proxy.scrollTo("thinking", anchor: .bottom) }
      else { proxy.scrollTo(agent.messages.last?.id, anchor: .bottom) }
    }
  }

  private var emptyState: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Think out loud.").font(.body.weight(.medium)).foregroundStyle(Theme.Palette.body)
      Text("The agent reads your board and edits it as you talk — adding, sharpening, and connecting cards. Try “read my board and tell me what's missing.”")
        .font(.caption).foregroundStyle(Theme.Palette.menuDesc)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
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
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.accentColor.opacity(0.20)))
        .frame(maxWidth: .infinity, alignment: .trailing)
    case .assistant:
      Text(Self.markdown(message.text))
        .font(.callout).foregroundStyle(Theme.Palette.body).textSelection(.enabled)
        .lineSpacing(2.5)
        .tint(Color.accentColor)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    case .tool:
      // One compact line per tool call: the summary never wraps — it truncates with an ellipsis,
      // and the full text is available on hover.
      HStack(spacing: 7) {
        Image(systemName: "wand.and.sparkles").font(.system(size: 10))
        Text(message.text).font(.caption).lineLimit(1).truncationMode(.tail)
        Spacer(minLength: 0)
      }
      .foregroundStyle(Theme.Palette.title)
      .padding(.horizontal, 9).padding(.vertical, 5)
      .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.045)))
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

  // MARK: Input

  private var inputBar: some View {
    HStack(alignment: .bottom, spacing: 8) {
      TextField("Message the agent…", text: $draft, axis: .vertical)
        .textFieldStyle(.plain)
        .lineLimit(1...6)
        .font(.callout)
        .foregroundStyle(Theme.Palette.body)
        .focused($inputFocused)
        .onSubmit(submit)
      if agent.isRunning {
        Button(action: agent.stop) {
          Image(systemName: "stop.circle.fill").font(.title3).foregroundStyle(Theme.Palette.title)
        }.buttonStyle(.plain).help("Stop")
      } else {
        Button(action: submit) {
          Image(systemName: "arrow.up.circle.fill")
            .font(.title3)
            .foregroundStyle(canSend ? Color.accentColor : Theme.Palette.title.opacity(0.6))
        }.buttonStyle(.plain).disabled(!canSend)
      }
    }
    .padding(.leading, 14).padding(.trailing, 10).padding(.vertical, 9)
    .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Color.white.opacity(0.06)))
    .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(Color.white.opacity(0.09), lineWidth: 1))
    .padding(12)
    .onAppear { inputFocused = true }
  }

  private var canSend: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

  private func submit() {
    let text = draft
    draft = ""
    agent.send(text)
    inputFocused = true
  }

  /// Render inline markdown (**bold**, `code`, _italic_, links) while keeping newlines.
  private static func markdown(_ text: String) -> AttributedString {
    (try? AttributedString(
      markdown: text,
      options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
  }

  private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: symbol).font(.caption.weight(.medium))
        .foregroundStyle(Theme.Palette.title).frame(width: 24, height: 24).contentShape(Rectangle())
    }
    .buttonStyle(.plain).help(help)
  }
}
