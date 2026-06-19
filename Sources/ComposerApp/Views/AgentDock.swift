import SwiftUI

/// The in-canvas chat with the agent that lives on the board. You talk; it edits the canvas as it
/// goes (via the canvas MCP). Right-docked, dark glass, matches the panel aesthetic.
struct AgentDock: View {
  @ObservedObject var agent: CanvasAgent
  var onClose: () -> Void
  @State private var draft = ""
  @FocusState private var inputFocused: Bool

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider().overlay(Theme.Palette.separator)
      transcript
      inputBar
    }
    .frame(width: 360)
    .frame(maxHeight: .infinity)
    .background {
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .fill(Color.black.opacity(0.5))
        .background(VisualEffectBackground(material: .hudWindow, blending: .withinWindow, state: .active))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
        .shadow(color: .black.opacity(0.4), radius: 24, y: 10)
    }
  }

  // MARK: Header

  private var header: some View {
    HStack(spacing: 8) {
      AgentEngineIcon(size: 16)
      Text("Agent").font(.body.weight(.semibold)).foregroundStyle(Theme.Palette.body)
      if agent.isRunning { ProgressView().controlSize(.small).scaleEffect(0.65) }
      Spacer(minLength: 6)
      groundingControl
      iconButton("arrow.counterclockwise", help: "New conversation") { agent.reset(); draft = "" }
      iconButton("xmark", help: "Close  ⌘J", action: onClose)
    }
    .padding(.horizontal, 14).frame(height: 48)
  }

  @ViewBuilder
  private var groundingControl: some View {
    if let dir = agent.groundingDirectory {
      Button { agent.chooseDirectory() } label: {
        HStack(spacing: 4) {
          Image(systemName: "folder.fill").font(.system(size: 10))
          Text(dir.lastPathComponent).font(.caption).lineLimit(1).truncationMode(.middle)
            .frame(maxWidth: 96, alignment: .leading)
        }
        .foregroundStyle(Color.accentColor)
        .padding(.horizontal, 8).frame(height: 22)
        .background(Capsule().fill(Color.accentColor.opacity(0.16)))
        .contentShape(Capsule())
      }
      .buttonStyle(.plain)
      .help("Grounded in \(dir.path) — click to change")
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
      HStack(spacing: 7) {
        Image(systemName: "wand.and.sparkles").font(.system(size: 10))
        Text(message.text).font(.caption)
        Spacer(minLength: 0)
      }
      .foregroundStyle(Theme.Palette.title)
      .padding(.horizontal, 9).padding(.vertical, 5)
      .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.045)))
      .frame(maxWidth: .infinity, alignment: .leading)
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
