# BonsAI

**A bucket for thoughts and ideas — and the shortest path from a thought to a well-formed prompt.**

BonsAI is a small, native macOS app. It gives you a board of cards where you
capture half-formed ideas, pull in just-enough context with **connectors**
(your files, open tabs, library docs, tickets, designs, errors…), and an
invisible **on-device semantic linter** quietly flags the spots that are too
vague for an AI agent to act on. When a card is ready, you copy it out into
whatever AI tool you drive next.

The pillar behind every design decision: **remove friction between having a
thought and getting it into a coding agent.** If a feature makes that path
longer, it probably doesn't belong here.

---

## Requirements

- **macOS 26 (Tahoe)** or later.
- **Apple Intelligence** enabled, for the semantic linter — without it, the
  linter quietly turns itself off and everything else works.

There's nothing to install or configure: download `BonsAI.app` from
[Releases](../../releases) and open it. Building from source or contributing?
See [CONTRIBUTING.md](CONTRIBUTING.md).

## Installing a release

Each `v*` tag publishes a zipped `BonsAI.app` to **Releases**. Until builds are
signed, macOS will warn you on first launch — either right-click the app and
choose **Open**, or clear the quarantine flag:

```bash
xattr -dr com.apple.quarantine /Applications/BonsAI.app
```

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

## Architecture notes

BonsAI is a normal Dock app built on AppKit + SwiftUI. The board, the
Agent/Settings dock, and the toolbar are **deliberately separate, coordinated
windows** with a **screen-relative** layout — not a single stacked view. That
composition is load-bearing and easy to "clean up" by accident, so it's
documented and guarded in [CLAUDE.md](CLAUDE.md) and [AGENTS.md](AGENTS.md).
Read those before touching panel geometry.

## Contributing

Contributions are welcome — especially around UX friction, new connectors, and
the semantic-linter layer. Please read [CONTRIBUTING.md](CONTRIBUTING.md) first;
it explains the philosophy a change has to fit, and what will get a PR rejected.
Every PR records a note in [CHANGELOG.md](CHANGELOG.md).

## License

To be decided before the repository is opened up publicly.
