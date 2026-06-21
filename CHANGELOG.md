# Changelog

All notable changes to **BonsAI** are recorded here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project aims to follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Every pull request to `main` adds at least one note under **Unreleased** (the
`Changelog` workflow enforces this). On release, the Unreleased notes move down
under the new version heading.

## [Unreleased]

## [1.0.0] - 2026-06-20

### Added
- **In-app auto-update (Sparkle)** — BonsAI checks GitHub for new releases on launch
  and once a day, then downloads, installs, and relaunches in place. **Check for
  Updates…** is in the app menu and **Settings → About** (with a toggle for automatic
  checks). Each release ships an EdDSA-signed `appcast.xml`. The app isn't notarized,
  so the first launch still needs the one-time quarantine step — every update after
  that is seamless.
- **App connectors** — `@figma`, `@linear`, `@notion`, `@sentry`, and `@xcode`:
  resolve a reference and drop a live chip into a prompt. Personal tokens are
  stored in the Keychain.
- Settings sections for connectors and on-device intelligence (live model
  availability with a recheck).
- A **configurable summon shortcut** — record your own global hotkey in
  Settings → Shortcuts (⌃⌥Space stays the default).
- A two-window workspace: the board with a companion dock that share a bottom edge.
- GitHub Actions workflows: CI (release build + tests), tagged releases that
  publish a zipped `BonsAI.app`, and a changelog-entry check on every PR to `main`.
- Project docs: `README`, `CONTRIBUTING` (contribution focus areas + the
  connector philosophy), a `SPLUS.md` review contract, and `docs/semanticlinter.md`.
- Agent & engine docs: `docs/agent-engines.md` (how `claude -p` and Apple
  Intelligence are invoked and selected, plus how to add an engine) and
  `docs/canvas-agent.md` (the board as an agent-readable graph + the loopback
  server/MCP plumbing).

### Changed
- **BonsAI is now a regular Dock app** (real Dock icon + Cmd-Tab presence) instead
  of a menu-bar utility. Summon the board with the global hotkey or by clicking the
  Dock icon; `Cmd-,` still opens settings.
- Renamed the app to **BonsAI** (`dev.jow.BonsAI`) with a baked Dock icon, and made
  optimized Release the default build.
- Builds now target macOS 26 (swift-tools 6.2).
- **Settings refined to the app's quiet visual language** — neutral header and
  segmented tabs, with the accent glows, colored status badges, and marketing-voice
  headings removed so the panel matches the rails and the agent dock. Brand marks
  and the live model availability readout stay.
- **The agent and its grounding folder moved to the left rail**, grouped with the
  board-session actions (New · History — Agent · Folder — Settings); the top toolbar
  is now the canvas tools, zoom, and Tidy.

### Removed
- The menu-bar item (`MenuBarExtra` / `LSUIElement`).
- The Codex (`codex exec`) engine integration — it couldn't be tested, so it was
  dropped. `HeadlessEngine` stays the extension point; a PR re-adding Codex (or
  OpenCode, Pi, …) is welcome — see `docs/agent-engines.md`.

<!--
Add a bullet under the matching heading for every user-facing change. Create a
heading only when you have an entry for it; delete this comment when you do.

### Added     — new capabilities
### Changed   — behavior or UX that changed
### Fixed     — bug fixes
### Removed    — things taken out
-->
