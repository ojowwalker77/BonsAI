# Changelog

All notable changes to **BonsAI** are recorded here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project aims to follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Every pull request to `main` adds at least one note under **Unreleased** (the
`Changelog` workflow enforces this). On release, the Unreleased notes move down
under the new version heading.

## [Unreleased]

<!--
Add a bullet under the matching heading for every user-facing change. Create a
heading only when you have an entry for it; delete this comment when you do.

### Added     — new capabilities
### Changed   — behavior or UX that changed
### Fixed     — bug fixes
### Removed    — things taken out
-->

## [1.0.3] - 2026-06-22

### Added
- **Rename a board.** Hover a board in the history list for a pencil (or right-click →
  **Rename**) and edit its name in place — Enter or click-away saves, Esc cancels. A
  custom name overrides the auto-derived title and survives later card edits.
- **Remove a board's grounding.** Once a folder was picked there was no way to un-ground;
  now a ✕ on the Agent dock's grounding chip and a **Remove Grounding** item in the
  sidebar folder's context menu clear it back to canvas-only.

### Fixed
- **Actionable failure messages.** Composer now preserves CLI, connector, storage,
  clipboard, attachment, and canvas-service diagnostics instead of reducing failures
  to generic errors or silently omitting failed context. Claude authentication failures
  now identify the API rejection and point to `claude auth login`.
- **The Settings gear now toggles.** Clicking the sidebar gear a second time while
  Settings was open did nothing; it now closes the panel (matching the Agent toggle).
- **Drawing tools no longer grab existing elements.** A drag that started over a card
  used to select/move that card instead of drawing on top. Selecting, moving, and
  resizing are now exclusive to the Select tool (⌘1); in any drawing tool a drag always
  draws a new element.

## [1.0.2] - 2026-06-21

### Fixed
- **Downloaded builds crashed instantly on launch.** The signed release staged the
  SwiftPM resource bundle into `Contents/Resources`, but the generated `Bundle.module`
  accessor only looks at the app root, so the first brand-logo render hit a `fatalError`
  ("could not load resource bundle") and the app quit unexpectedly. Resources are now
  resolved through a crash-proof `Bundle.appResources` lookup that searches every sane
  location and degrades to a placeholder instead of trapping. Local builds now stage the
  bundle in the same `Contents/Resources` layout the release ships, so this can't drift
  again.

### Added
- **Drag-to-install `BonsAI.dmg`.** Releases now ship a notarized disk image with a
  **BonsAI → Applications** layout, so installing is the familiar drag onto the
  Applications folder (which also moves the app out of Downloads and avoids macOS App
  Translocation). The Sparkle auto-update path still uses the zipped app.

## [1.0.1] - 2026-06-21

### Added
- **In-app auto-update (Sparkle)** — BonsAI checks GitHub for new releases on launch
  and once a day, then downloads, installs, and relaunches in place. **Check for
  Updates…** is in the app menu and **Settings → About** (with a toggle for automatic
  checks). Releases are **Developer ID-signed and notarized** and ship an EdDSA-signed
  `appcast.xml`, so both the first install and every update are seamless.
- **App connectors** — `@figma`, `@linear`, `@notion`, `@sentry`, and `@xcode`:
  resolve a reference and drop a live chip into a prompt. Personal tokens are
  stored in the Keychain.
- Settings sections for connectors and on-device intelligence (live model
  availability with a recheck).
- A **configurable summon shortcut** — record your own global hotkey in
  Settings → Shortcuts (⌃⌥Space stays the default).
- A two-window workspace: the board with a companion dock that share a bottom edge.
- GitHub Actions workflows: CI (release build + tests), tagged releases that publish a
  signed, notarized zipped `BonsAI.app`, and a changelog-entry check on every PR to
  `main`.
- Project docs: `README`, `CONTRIBUTING` (contribution focus areas + the
  connector philosophy), a `SPLUS.md` review contract, and `docs/semanticlinter.md`.
- Agent & engine docs: `docs/agent-engines.md` (how `claude -p` and Apple
  Intelligence are invoked and selected, plus how to add an engine) and
  `docs/canvas-agent.md` (the board as an agent-readable graph + the loopback
  server/MCP plumbing).
- A board-level **Copy** button in the toolbar that runs `claude -p` to read the
  whole board and write a self-contained, paste-ready description to the clipboard.
- The **Figma** connector shows its real multi-color brand mark (drawn from
  vector, like the GitHub Octocat).
- A **welcome board** seeded on first launch, so new users land on an onboarding
  board that explains BonsAI. Seeded once into an empty store; existing users and
  anyone who deletes it are untouched.
- Board zoom now reaches **200%** (was capped at 100%).

### Changed
- **BonsAI is a regular Dock app** (real Dock icon + Cmd-Tab presence) rather than a
  menu-bar utility. Summon the board with the global hotkey or by clicking the Dock
  icon; `Cmd-,` still opens settings.
- The app is named **BonsAI** (`dev.jow.BonsAI`) with a baked Dock icon, and
  optimized Release is the default build.
- Builds target macOS 26 (swift-tools 6.2).
- **Settings refined to the app's quiet visual language** — neutral header and
  segmented tabs, with the accent glows, colored status badges, and marketing-voice
  headings removed so the panel matches the rails and the agent dock. Brand marks
  and the live model availability readout stay.
- **The agent and its grounding folder live in the left rail**, grouped with the
  board-session actions (New · History — Agent · Folder — Settings); the top toolbar
  is the canvas tools, zoom, and a board Copy button.
- Agent chat **tool calls collapse to a single line** — truncated, with the full
  text on hover — so a burst of edits stays scannable.
- The left **rail gutter is tightened to 6%**, so the rail reads as attached to the
  board rather than marooned at the screen edge.

### Fixed
- **Releases are now Developer ID-signed and notarized** — the download opens with a
  double-click, with no "damaged" Gatekeeper warning or `xattr` quarantine step.
- **Emoji and other non-BMP characters** are no longer corrupted to `�` when a
  card's text is serialized — the serializer now advances by composed-character
  sequences instead of single UTF-16 units.

### Removed
- The menu-bar item (`MenuBarExtra` / `LSUIElement`).
- The Codex (`codex exec`) engine integration — it couldn't be tested, so it was
  dropped. `HeadlessEngine` stays the extension point; a PR re-adding Codex (or
  OpenCode, Pi, …) is welcome — see `docs/agent-engines.md`.
- The manual **Tidy** button in the toolbar — the agent still tidies the board
  from chat (the MCP `tidy`/`relayout` tool).
