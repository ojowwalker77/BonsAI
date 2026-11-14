# BonsAI

**A canvas board for thinking — with a local server your coding agents can drive.**

<img width="3420" height="2224" alt="image" src="https://github.com/user-attachments/assets/19493af9-6f0b-4541-bbde-a432f65e5037" />


BonsAI is a small, native macOS app: one resizable, infinite canvas with rich
elements and fast, quiet UX. Sketch the shape of a problem, write it out, and let
Claude Code, Codex, Cursor, or any script read and reshape the same board live
over a loopback-only server.

---

## What you do in BonsAI

- **Write and structure ideas.** Text cards support Markdown headings, emphasis,
  code, quotes, lists, and checkboxes, with per-word ink colors.
- **Sketch with real elements.** Rectangles, ellipses, diamonds, bound arrows and
  lines, freehand ink, vector pen paths, LaTeX equations, function graphs,
  stickies, checklists, and tables; hold Shift to keep shapes proportional.
- **Snap a screenshot onto the board.** ⇧⌘Space (rebindable in Settings) captures
  a screen region into an image card and reads its text on-device, so agents can
  see what the screenshot says.
- **Let your agents work on the board.** BonsAI runs a server on
  `127.0.0.1:7337` (HTTP + MCP). Agents read the board as a graph of nodes and
  edges, then add, connect, tidy, and evolve cards; their edits land on screen
  instantly and are marked as agent-authored.

## Requirements

- **macOS 14 (Sonoma)** or later. The board and every core feature run here.
- **macOS 26 (Tahoe)** adds the Liquid Glass look and, with **Apple Intelligence**
  enabled, an on-device cleanup pass for snapped screenshots. Below Tahoe (or
  without Apple Intelligence) those quietly turn themselves off and everything
  else works unchanged.

There's nothing to install or configure: download `BonsAI.dmg` from
[Releases](../../releases) and drag **BonsAI** onto **Applications**. Building from source
or contributing? See [CONTRIBUTING.md](CONTRIBUTING.md).

## Installing a release

Each `vX.Y.Z` tag publishes a **Developer ID-signed and notarized** `BonsAI.dmg` to
**Releases**. Download it, open it, and drag **BonsAI** onto the **Applications** folder —
it launches with a double-click; no right-click or quarantine workaround. (A zipped
`BonsAI.app` is also attached for Sparkle's auto-update; the `.dmg` is the recommended
first install.)

BonsAI keeps itself current: it checks GitHub for new releases on launch and once a day,
then downloads, installs, and relaunches in place. You can also check any time from
**BonsAI ▸ Check for Updates…** (or **Settings ▸ About**), and turn off automatic checks
there.

Maintaining the release feed (Apple signing + the Sparkle key) is documented in
[docs/releasing.md](docs/releasing.md).

## Connecting agents

On first launch BonsAI offers to teach any coding agent it detects (Claude Code,
Codex CLI, Cursor) how to use the board. You can install or refresh those skill
docs any time from **Settings ▸ Agents**, which also shows the HTTP and MCP
endpoints.

The server is bound to `127.0.0.1` only. Every endpoint except `/health` needs a
bearer capability that BonsAI writes to an owner-only `session.json` and replaces
on every launch.

- [docs/canvas-api.md](docs/canvas-api.md) — endpoints, the authentication
  helper, and the raw ops for scripts.
- [docs/canvas-agent.md](docs/canvas-agent.md) — the board as an agent-readable
  graph: nodes/edges, the server → MCP → bridge plumbing, and the tool catalog.

## Architecture notes

BonsAI is built on AppKit + SwiftUI. The workspace is one standard, resizable
macOS window with floating canvas chrome: board switcher, export, the bottom
command bar (zoom, tools, Settings), and an in-canvas Settings overlay. That
composition is load-bearing and easy to "clean up" by accident, so it's
documented and guarded in [CLAUDE.md](CLAUDE.md). Read it before touching window
or canvas-chrome geometry.

## Stars

[![Star History Chart](https://api.star-history.com/svg?repos=ojowwalker77/BonsAI&type=Date)](https://www.star-history.com/#ojowwalker77/BonsAI&Date)

## Contributing

Contributions are welcome — especially canvas elements, UX polish, and the agent
server. Please read [CONTRIBUTING.md](CONTRIBUTING.md) first; it explains the
scope a change has to fit, and what will get a PR rejected. Every PR records a
note in [CHANGELOG.md](CHANGELOG.md).
