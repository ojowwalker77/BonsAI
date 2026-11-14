# Contributing to BonsAI

People are genuinely welcome to contribute. Before you open a PR, please
understand what BonsAI is, because everything here is measured against it:

> **BonsAI is a canvas board with great elements and UX, exposed over a local
> server so your coding agents can read and shape it.** You think on the board;
> Claude Code, Codex, Cursor, or a script works on the same board through
> `127.0.0.1:7337`.

So the bar for any change is simple: **does it make the board better to think
on, or better for agents to use?** Thoughtful contributions that sharpen either
side are exactly what this project wants. Features that pull BonsAI toward being
a heavier, do-it-all app — an in-app chat, context connectors, a prompt
compiler — will be declined; they were tried and removed on purpose.

A few areas where PRs are especially welcome:

## Canvas elements and UX

This is the heart of it. Better shapes, arrows, ink, equations, graphs, stickies,
checklists, and tables; smoother selection, snapping, and editing; fewer steps,
less waiting, less reaching for the mouse. If you can shave a second or a
decision off thinking on the board, that's a great PR.

New elements fit when an agent can use them too: a new `CanvasElementKind`
should round-trip through `CanvasGraph` and, where it makes sense, get a canvas
op and an MCP tool.

## The agent server

The loopback server is how agents see and change the board. Read
[docs/canvas-agent.md](docs/canvas-agent.md) (the graph, the server → MCP →
bridge plumbing, the tool catalog) and [docs/canvas-api.md](docs/canvas-api.md)
(endpoints and authentication) before changing it. Keep it loopback-only and
capability-gated, keep ops tiny and explicit, and keep the bundled skill docs in
`Sources/ComposerApp/Resources/AgentSkills/` in sync with any tool you add.

## Beyond these areas

These are, in our view, the main areas of improvement — but please feel free to
bring your own ideas in a broader sense too. We just kindly ask, and warn up
front: **anything that bloats BonsAI or doesn't follow the philosophy above will
be rejected.** Smaller and sharper beats bigger and busier, every time.

---

## Development

```bash
./script/bootstrap               # resolve the SwiftPM dependency graph
./script/run                     # build, stage, and launch BonsAI
./script/check                   # release build plus the complete test suite
./script/verify                  # stage and inspect the distributable app bundle
./script/release-preflight 1.2.3 # validate metadata before tagging a release
```

A **Swift 6.2+ toolchain (Xcode 26)** is all you need to build — the Tahoe SDK is
required to compile the gated Apple Intelligence / Liquid Glass paths. The app itself
deploys to **macOS 14 (Sonoma)** and up: those Tahoe-only features are weak-linked and
guarded behind `#available(macOS 26, *)`, so the build runs unchanged on 14. The one
external dependency — [Sparkle](https://sparkle-project.org) (auto-update) — is fetched
by SwiftPM and bundled into the `.app` by `build_and_run.sh`. See the
[README](README.md) for the full set of requirements.

Releases are fully automated — pushing a `vX.Y.Z` tag builds and publishes the app with a
Sparkle auto-update feed. Contributors never touch the release flow; it's documented
for maintainers in [docs/releasing.md](docs/releasing.md).

## Opening a pull request

- **Keep it focused and small.** One idea per PR. It's easier to review, and
  easier to say yes to.
- **Target `main`.** Use a short-lived branch and open the pull request directly
  against `main`. Releases are immutable `vX.Y.Z` tags created from a commit that
  already passed the required `Quality` check on `main`.
- **Add a CHANGELOG entry.** Every non-doc app change adds a note under
  `## [Unreleased]` in [CHANGELOG.md](CHANGELOG.md), so `main` has complete notes
  before its next release tag. For changes that genuinely aren't
  user-facing (refactors, CI tweaks), apply the `skip-changelog` label instead.
- **Cover pure logic with tests.** Codecs, parsing, and other deterministic
  logic should get tests like those in `Tests/ComposerAppTests`.
- **Don't disturb the window + floating chrome composition.** One standard
  window with Liquid Glass pills floating over the canvas is deliberate and
  load-bearing. If your change touches chrome or window layout, read
  [CLAUDE.md](CLAUDE.md) first and launch the app to verify the solid canvas,
  the single bottom command bar, and the top pills aligned on the traffic-light
  centerline in every theme.
- **Make CI green.** Run `./script/check` for the fast gate and `./script/verify`
  when packaging, resources, the updater, or release behavior changes.

If you're unsure whether an idea fits the philosophy, open an issue and ask
before building it — it's the fastest way to find out, and we're happy to talk it
through.
