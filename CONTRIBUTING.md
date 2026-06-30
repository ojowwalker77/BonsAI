# Contributing to BonsAI

People are genuinely welcome to contribute. Before you open a PR, please
understand the one idea everything here is measured against:

> **BonsAI is a bucket for thoughts and ideas.** Its job is to remove friction
> and shrink the time from *having a thought* to *that thought being an entry in
> a coding agent*. That is a pillar, not a slogan.

So the bar for any change is simple: **does it reduce friction, or does it add
bloat?** Thoughtful contributions that sharpen the core loop are exactly what
this project wants. Features that pull BonsAI toward being a heavier, do-it-all
app — however clever — will be rejected. That's a promise to everyone who relies
on it staying fast and quiet, not a judgment of your work.

A few areas where PRs are especially welcome:

## Improve user experience

This is the heart of it. BonsAI is designed to be a bucket for thoughts and
ideas, and **removing friction — speeding the time from a thought to an entry in
BonsAI — is one of our pillars.** Anything that makes capture faster, more
fluid, or more obvious is on-mission: fewer steps, less waiting, less reaching
for the mouse, less thinking about the tool instead of the idea. If you can shave
a second or a decision off the path from *brain → board*, that's a great PR.

## Connectors

More connectors are welcome. The connector philosophy is simple:

> **A connector should inject genuinely useful context for an idea.**

But there's a catch worth being precise about, and it's clearest by example:
*why does a **Context7** connector make sense, while an **Obsidian** connector
does not?* Two things earn a connector its place:

> **1. It adds a real capability and removes steps** — it's faster and easier
> than navigating and fetching that context by hand.
> **2. It doesn't duplicate a broader connector we already have.**

- **Context7 earns its place.** It gives you a purpose-built path to current,
  version-accurate library docs straight from the card — no opening a browser,
  searching, finding the right page, and copy-pasting. That's a real capability
  and real time saved on something you'd otherwise do by hand. (Plenty of context
  is straightforward enough not to need a connector; this isn't.)
- **Obsidian does not.** Obsidian notes are just local files, and the broader
  **@Finder** connector already serves any local file or folder. A dedicated
  Obsidian connector would duplicate a general capability we already have — more
  surface area, nothing new. The same logic rules out, say, a Wikipedia
  connector: a web page is already reachable through **@Browser**, and opening
  one is straightforward.

So when you propose a connector, ask two things: *does it add a capability and
save real steps versus doing it by hand, and is it already covered by a broader
connector?* If it doesn't add capability, or a general connector (**@Finder**,
**@Browser**) already handles it, it'll be declined — that's how the set stays
small and sharp.

**How connectors are built.** A connector conforms to `ComposerAppConnector`
(`Sources/ComposerApp/Support/AppConnectors.swift`) and is registered in
`AppConnectorRegistry.all`. It owns its own API/CLI details, declares whether it
needs a secret (`ConnectorAuth` → rendered in Settings, stored via
`ConnectorSecretStore`), and provides:

- `search(_:context:)` — find candidates for the chip picker, and
- `render(selection:)` — produce the context block that goes into the prompt,
  which **must degrade gracefully** to a plain reference line on network/CLI
  failure (never crash, never block the main actor).

The `@token` serialization is the source of truth for chips, so new connectors
get round-trip tests alongside the others in `ConnectorTokenTests`.

## Semantic linter layer

This is a newer, more experimental concept, and we'll be honest: we're **not
fully happy with it yet** — there's a lot of room to improve. The idea is simple,
though. **What a linter is for a programming language, this is for the meaning of
your prose.** We lean on Apple Intelligence and on-device Foundation Models to
*lint semantics* — to quietly flag the phrases in a draft that are too ambiguous
or underspecified for an AI agent to act on without guessing.

If you want to push on this, read [docs/semanticlinter.md](docs/semanticlinter.md)
for the full context — the on-device/privacy constraints, the precision bias (a
wrong squiggle is worse than a missed one), the kinds of ambiguity it flags, and
where the prompt that drives it lives. This is a great area to experiment in.

## Agent & engine layer

The AI surfaces never ship a model — they shell out to a coding-agent CLI you
already use (`claude -p`) for Refine and Compile, and spawn `claude` in streaming
mode with a loopback MCP server for the in-canvas chat agent. Two write-ups cover
the whole layer:

- [docs/agent-engines.md](docs/agent-engines.md) — the engines (Claude +
  on-device Apple Intelligence), the one-shot vs streaming execution paths, how an
  engine is selected, and the `PATH` gotcha for a GUI-launched app. Read this
  before touching engine selection or adding a CLI integration.
- [docs/canvas-agent.md](docs/canvas-agent.md) — the board as an agent-readable
  graph (`CanvasGraph` nodes/edges, reading order, authorship), the loopback
  server → MCP → bridge plumbing, and the tool catalog. Read this before changing
  how the agent reads or writes the board.

**A PR adding another engine is welcome.** Today there's one CLI engine (Claude),
but `HeadlessEngine` and the selection machinery around it are built to take more
— support for **Codex**, **OpenCode**, **Pi**, or another agent CLI is a
well-scoped contribution. The
[Adding an engine](docs/agent-engines.md#adding-an-engine) section lists every
touch point. One-shot Refine/Compile is the easy win; wiring a non-Claude engine
into the streaming chat agent is a larger lift.

## Beyond these areas

These are, in our view, the main areas of improvement — but please feel free to
bring your own ideas in a broader sense too. We just kindly ask, and warn up
front: **anything that bloats BonsAI or doesn't follow the philosophy above will
be rejected.** Smaller and sharper beats bigger and busier, every time.

---

## Development

```bash
./script/build_and_run.sh        # build (release), stage, and launch
./script/build_and_run.sh bundle # build + stage only, no launch
swift test                       # run the test suite
```

A **Swift 6.2+ toolchain (Xcode 26)** on macOS 26 is all you need; the one external
dependency — [Sparkle](https://sparkle-project.org) (auto-update) — is fetched by
SwiftPM and bundled into the `.app` by `build_and_run.sh`. See the
[README](README.md) for the full set of requirements.

Releases are fully automated — pushing a `v*` tag builds and publishes the app with a
Sparkle auto-update feed. Contributors never touch the release flow; it's documented
for maintainers in [docs/releasing.md](docs/releasing.md).

## Opening a pull request

- **Keep it focused and small.** One idea per PR. It's easier to review, and
  easier to say yes to.
- **Target the release branch.** Open contributor and agent branches against the
  active release branch, not directly against `main`. If there is no active
  release branch yet, create one from the latest `main` named
  `release-[next_release_number]` (for example, `release-1.0.6`), then open the
  PR from your branch into that release branch. When the release branch is ready,
  maintainers merge it into `main`.
- **Add a CHANGELOG entry.** Every non-doc app change adds a note under
  `## [Unreleased]` in [CHANGELOG.md](CHANGELOG.md), so the release branch has
  complete notes before it merges to `main`. For changes that genuinely aren't
  user-facing (refactors, CI tweaks), apply the `skip-changelog` label instead.
- **Cover pure logic with tests.** Codecs, parsing, and other deterministic
  logic should get tests like those in `Tests/ComposerAppTests`.
- **Don't disturb the board + dock composition.** The separate board / dock /
  toolbar windows and their screen-relative geometry are deliberate and
  load-bearing. If your change touches panel layout, read [CLAUDE.md](CLAUDE.md)
  and [AGENTS.md](AGENTS.md) first, and launch the app to verify both Settings
  and Agent open beside a shrunken board with aligned edges.
- **Make CI green.** `swift build -c release` and `swift test` must pass.

If you're unsure whether an idea fits the philosophy, open an issue and ask
before building it — it's the fastest way to find out, and we're happy to talk it
through.
