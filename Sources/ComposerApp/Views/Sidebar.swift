import SwiftUI

/// The floating liquid-glass rail on the left edge — the always-visible home for the
/// board/session actions. Grouped top→bottom: board lifecycle (new, history), the agent and the
/// folder it's grounded in, then settings pinned below. The canvas tools + zoom live in the top
/// `CanvasToolbar`. Quiet by default, lights up on hover.
struct Sidebar: View {
  @ObservedObject var store: DumpStore
  /// The grounded directory's display name, or nil when the agent is canvas-only.
  var groundedFolder: String?
  var agentOpen: Bool
  var onNew: () -> Void
  var onHistory: () -> Void
  var onAgent: () -> Void
  var onFolder: () -> Void
  var onClearFolder: () -> Void
  var onSettings: () -> Void

  var body: some View {
    VStack(spacing: 9) {
      SidebarButton(symbol: "square.and.pencil", help: "New board  ⌘N", action: onNew)
      SidebarButton(symbol: "clock.arrow.circlepath", help: "Past boards  ⌘[ ⌘]",
                    active: store.isHistoryOpen, action: onHistory)

      divider

      // The agent and its grounding context. The agent wears its engine's brand mark; the folder
      // is icon-only here (a vertical rail can't carry the expanding name pill) and tints to the
      // accent once grounded.
      SidebarAgentButton(active: agentOpen, action: onAgent)
      SidebarButton(symbol: groundedFolder == nil ? "folder.badge.plus" : "folder.fill",
                    help: folderHelp, active: groundedFolder != nil, action: onFolder)
        .contextMenu {
          if groundedFolder == nil {
            Button("Ground in Folder\u{2026}", action: onFolder)
          } else {
            Button("Change Folder\u{2026}", action: onFolder)
            Button("Remove Grounding", role: .destructive, action: onClearFolder)
          }
        }

      divider

      SidebarButton(symbol: "gearshape", help: "Settings  ⌘,", action: onSettings)
    }
    .padding(.vertical, 12)
    .padding(.horizontal, 7)
    .railSurface()
  }

  private var divider: some View {
    Rectangle().fill(Theme.Palette.separator).frame(width: 16, height: 1).padding(.vertical, 1)
  }

  private var folderHelp: String {
    groundedFolder.map { "Agent grounded in \($0)  ·  click to change" }
      ?? "Ground the agent in a folder it can read"
  }
}

struct SidebarButton: View {
  let symbol: String
  let help: String
  var active = false
  var disabled = false
  var action: () -> Void
  @State private var hovering = false

  var body: some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: 17, weight: .medium))
        .foregroundStyle(foreground)
        .frame(width: 38, height: 38)
        .background(
          // Active reads through the accent-tinted icon (below) — no blue fill, just a neutral
          // hover wash so the control still feels live.
          Circle().fill(hovering && !disabled ? Color.white.opacity(0.12) : Color.clear)
        )
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .disabled(disabled)
    .onHover { hovering = $0 }
    .help(help)
    .animation(.easeOut(duration: 0.12), value: hovering)
  }

  // Icons sit on the dark rail, so they're keyed to white — bright enough to read at rest.
  private var foreground: AnyShapeStyle {
    if disabled { return AnyShapeStyle(Color.white.opacity(0.26)) }
    if active { return AnyShapeStyle(Color.accentColor) }
    return AnyShapeStyle(Color.white.opacity(hovering ? 0.95 : 0.62))
  }
}

/// The agent toggle on the rail — shows the active engine's brand mark. Like its old home in the
/// toolbar, there's no active ring or fill; open/closed reads from the dock itself, and the mark
/// just brightens on hover or when the dock is open.
private struct SidebarAgentButton: View {
  var active: Bool
  var action: () -> Void
  @State private var hovering = false

  var body: some View {
    Button(action: action) {
      AgentEngineIcon(size: 18)
        .frame(width: 38, height: 38)
        .opacity(active ? 1 : (hovering ? 0.95 : 0.78))
        .background(Circle().fill(hovering ? Color.white.opacity(0.12) : Color.clear))
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
    .help("Chat with the agent on this board  ⌘J")
    .animation(.easeOut(duration: 0.12), value: hovering)
  }
}
