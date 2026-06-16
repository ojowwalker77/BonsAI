import SwiftUI

/// The entire app surface: a chromeless free-write note with contextual actions.
struct ComposerCanvas: View {
  @State private var text = NotePersistence.load()
  @State private var count = NotePersistence.load().count
  @State private var selection = EditorSelection()
  @State private var isWorking = false
  @State private var toast: Toast?

  @StateObject private var mentions = MentionState()
  @StateObject private var appSearch = AppSearchState()
  @StateObject private var controller = EditorController()

  private let service = HeadlessPromptService()

  var body: some View {
    ZStack(alignment: .topLeading) {
      ComposerPanelBackground()

      VStack(spacing: 0) {
        Text(noteTitle)
          .font(Theme.Typography.title)
          .tracking(0.2)
          .foregroundStyle(Theme.Palette.title)
          .lineLimit(1)
          .padding(.horizontal, Theme.Inset.horizontal)
          .padding(.top, Theme.Inset.titleTop)

        FreeWriteEditor(
          text: $text,
          onCountChange: { count = $0 },
          onSelectionChange: { selection = $0 },
          onEscape: { NotificationCenter.default.post(name: .composerDismiss, object: nil) },
          mentions: mentions,
          appSearch: appSearch,
          controller: controller
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, Theme.Inset.horizontal)
        .padding(.top, Theme.Inset.editorTop)

        Text(countLabel)
          .font(Theme.Typography.count)
          .monospacedDigit()
          .foregroundStyle(Theme.Palette.count)
          .padding(.bottom, Theme.Inset.countBottom)
      }

      selectionBar
      mentionMenu
      appSearchPanel
      toastView
    }
    .animation(Theme.Motion.accessory, value: selection)
    .animation(Theme.Motion.accessory, value: mentions.isOpen)
    .animation(Theme.Motion.accessory, value: appSearch.isOpen)
    .animation(Theme.Motion.accessory, value: isWorking)
    .onChange(of: text) { _, _ in NotePersistence.scheduleSave(controller.plainText) }
    .onReceive(NotificationCenter.default.publisher(for: .composerCopy)) { _ in copySelfContained() }
  }

  // MARK: Overlays

  @ViewBuilder
  private var selectionBar: some View {
    if !selection.isEmpty, !mentions.isOpen, !appSearch.isOpen, let rect = selection.rectInView {
      SelectionActionBar(
        isWorking: isWorking,
        onRefine: refine,
        onCopy: copySelfContained
      )
      .fixedSize()
      .position(x: clampX(rect.midX), y: max(rect.minY - 22, 30))
      .transition(.opacity)
    }
  }

  @ViewBuilder
  private var mentionMenu: some View {
    if mentions.isOpen, let anchor = mentions.anchorInView {
      MentionMenu(mentions: mentions)
        .fixedSize()
        .offset(x: clampMenuX(anchor.x), y: anchor.y + 5)
        .transition(.opacity)
    }
  }

  @ViewBuilder
  private var appSearchPanel: some View {
    if appSearch.isOpen, let anchor = appSearch.anchorInView {
      AppSearchPanel(state: appSearch)
        .fixedSize()
        .offset(x: clampMenuX(anchor.x), y: anchor.y + 5)
        .transition(.opacity)
    }
  }

  @ViewBuilder
  private var toastView: some View {
    if let toast {
      VStack {
        Spacer()
        HStack(spacing: 8) {
          Image(systemName: toast.symbol).foregroundStyle(toast.tint)
          Text(toast.text).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.Palette.body)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(
          Capsule(style: .continuous)
            .fill(.black.opacity(0.35))
            .background(VisualEffectBackground(material: .popover, blending: .withinWindow, forceDark: true).clipShape(Capsule()))
        )
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
        .shadow(color: .black.opacity(0.25), radius: 14, y: 6)
        .padding(.bottom, 40)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .transition(.move(edge: .bottom).combined(with: .opacity))
      .allowsHitTesting(false)
    }
  }

  // MARK: Labels

  private var countLabel: String { count == 1 ? "1 character" : "\(count) characters" }

  private var noteTitle: String {
    let firstLine = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init)?.trimmed ?? ""
    return firstLine.isEmpty ? "Untitled" : String(firstLine.prefix(60))
  }

  // MARK: Actions

  private func refine(_ engine: HeadlessEngine) {
    let snapshot = selection
    guard !snapshot.isEmpty, !isWorking else { return }
    let whole = controller.plainText
    isWorking = true
    Task {
      do {
        let result = try await service.refineSelection(whole: whole, selection: snapshot.text, engine: engine)
        controller.replace(range: snapshot.range, with: result)
        show(Toast(text: "Refined with \(engine.title)", symbol: "checkmark.circle.fill", tint: .green))
      } catch {
        show(Toast(text: error.localizedDescription, symbol: "exclamationmark.triangle.fill", tint: .orange))
      }
      isWorking = false
    }
  }

  private func copySelfContained() {
    let plain = controller.plainText
    guard !plain.trimmed.isEmpty else { return }
    let resolving = AppToken.scan(plain).contains { $0.selection != nil }
    if resolving { show(Toast(text: "Resolving connectors…", symbol: "arrow.triangle.2.circlepath", tint: .accentColor)) }
    Task {
      let rendered = await SelfContainedRenderer.render(plain)
      guard !rendered.trimmed.isEmpty else { return }
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(rendered, forType: .string)
      show(Toast(text: "Copied self-contained text", symbol: "doc.on.doc.fill", tint: .accentColor))
    }
  }

  // MARK: Toast

  private func show(_ value: Toast) {
    toast = value
    let id = value.id
    Task {
      try? await Task.sleep(nanoseconds: 1_900_000_000)
      if toast?.id == id { toast = nil }
    }
  }

  // MARK: Geometry clamps (keep overlays inside the panel)

  private func clampX(_ x: CGFloat) -> CGFloat { max(120, x) }
  private func clampMenuX(_ x: CGFloat) -> CGFloat { max(8, x) }
}

private struct Toast: Identifiable, Equatable {
  let id = UUID()
  let text: String
  let symbol: String
  let tint: Color
}
