# BonsAI

**A bucket for thoughts and ideas — and the shortest path from a thought to a well-formed prompt.**

<img width="3420" height="2224" alt="image" src="https://github.com/user-attachments/assets/19493af9-6f0b-4541-bbde-a432f65e5037" />


BonsAI is a small, native macOS app. It gives you one resizable canvas where you
capture half-formed ideas as cards, sketch relationships, write with Markdown,
pull in just-enough context with **connectors** (your files, open tabs, library
docs, tickets, designs, errors...), and let an in-canvas agent read or reshape
the board live. An invisible **on-device semantic linter** quietly flags the
spots that are too vague for an AI agent to act on. When a board is ready, you
can copy a self-contained prompt out or keep working directly with the agent on
the canvas.

The pillar behind every design decision: **remove friction between having a
thought and getting it into a coding agent.** If a feature makes that path
longer, it probably doesn't belong here.

---

## What you do in BonsAI

- **Write and structure ideas.** Text cards support Markdown headings, emphasis,
  code, quotes, lists, and checkboxes while preserving plain text for agents.
- **Sketch the shape of the problem.** Draw rectangles, ellipses, diamonds,
  arrows, and freehand marks; hold Shift to keep shapes proportional.
- **Ground the board with connector chips.** Use `@finder`, `@browser`,
  `@github`, `@context7`, `@linear`, `@notion`, `@sentry`, `@figma`, and `@xcode`
  to attach the context an agent would otherwise have to ask you for.

<img width="858" height="574" alt="image" src="https://github.com/user-attachments/assets/947388a8-8c77-4310-b77a-b8a426c5a73d" />
<img width="972" height="850" alt="image" src="https://github.com/user-attachments/assets/133dfa15-18c7-445a-8282-604120c6957f" />


  
- **Work with an agent on the board.** The chat agent can run through Claude,
  Codex, or OpenCode, reads the same canvas graph you see, and writes changes
  back through BonsAI's loopback-only canvas API.

<img width="2890" height="1828" alt="image" src="https://github.com/user-attachments/assets/293000c5-1802-4e5d-a6ec-8548aa993266" />

  

## Stars

[![Star History Chart](https://api.star-history.com/svg?repos=ojowwalker77/BonsAI&type=Date)](https://www.star-history.com/#ojowwalker77/BonsAI&Date)

## Requirements

- **macOS 14 (Sonoma)** or later. The board and every core feature run here.
- **macOS 26 (Tahoe)** with **Apple Intelligence** enabled unlocks the on-device
  extras — the semantic linter and screenshot cleanup — plus the Liquid Glass
  look. Below Tahoe (or without Apple Intelligence) those quietly turn themselves
  off and everything else works unchanged.

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

## Connectors

A connector earns its place when it **adds a real capability and removes steps** —
when it's faster than hand-navigating and fetching the context yourself — and it
**doesn't duplicate a broader connector**. (For the full litmus test and how to
build one, see [CONTRIBUTING.md](CONTRIBUTING.md#connectors).)

| Connector   | Injects                                              | Needs a token? |
| ----------- | ---------------------------------------------------- | -------------- |
| `@finder`   | A local file/folder, its path and contents           | No             |
| `@browser`  | An open browser tab's URL, title, and metadata       | No             |
| `@context7` | Current, version-accurate library documentation      | No             |
| `@github`   | An issue/PR's state, body, and comments (via `gh`)   | No             |
| `@linear`   | A Linear issue's description and acceptance criteria | Yes            |
| `@notion`   | A Notion page's content                              | Yes            |
| `@sentry`   | A Sentry issue's error and recent stack trace        | Yes            |
| `@figma`    | A Figma frame's dimensions, text, and screenshot     | Yes            |
| `@xcode`    | The latest Xcode build errors / test failures        | No             |

Tokens are entered in **Settings** and stored via the system keychain.

## Semantic linter

What a linter is for a programming language, this is for the *meaning* of your
prose. It runs fully on-device (Apple's Foundation Models), so it's free and
private enough to run on every typing pause, and it's tuned hard for precision.
Full write-up: [docs/semanticlinter.md](docs/semanticlinter.md).

## Agent & engines

BonsAI ships no model of its own. **Refine**, **Compile**, and the in-canvas
**chat agent** run through coding-agent CLIs you already use: Claude Code, Codex,
and OpenCode. Refine and Compile use one-shot CLI calls; the chat agent uses each
engine's streaming mode with the loopback canvas MCP server attached, so it can
read and reshape the board live as you talk.

Settings ▸ Runtime controls which engines are enabled and available. Settings ▸
Models, plus the picker on the Agent panel, choose the chat provider and model
where the underlying CLI supports it. Apple Intelligence is separate, fully
on-device, and powers the semantic linter only.

- [docs/agent-engines.md](docs/agent-engines.md) — the engines, how each is
  invoked, how one gets picked, and how to add another.
- [docs/canvas-agent.md](docs/canvas-agent.md) — the board as an agent-readable
  graph: nodes/edges, the loopback server + MCP tools, and how the agent reads
  and writes board state.

## Architecture notes

BonsAI is a normal Dock app built on AppKit + SwiftUI. In 1.3, the workspace is
one standard, resizable macOS window with floating canvas chrome: board switcher,
tools, zoom, grounding, bottom command bar, and in-canvas Agent and Settings
overlays. That composition is load-bearing and easy to "clean up" by accident,
so it's documented and guarded in [CLAUDE.md](CLAUDE.md) and [AGENTS.md](AGENTS.md).
Read those before touching window or canvas-chrome geometry.

## Contributing

Contributions are welcome — especially around UX friction, new connectors, and
the semantic-linter layer. Please read [CONTRIBUTING.md](CONTRIBUTING.md) first;
it explains the philosophy a change has to fit, and what will get a PR rejected.
Every PR records a note in [CHANGELOG.md](CHANGELOG.md).
