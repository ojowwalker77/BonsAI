# Changelog

All notable changes to **BonsAI** are recorded here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project aims to follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Every pull request to `main` adds at least one note under **Unreleased** (the
`Changelog` workflow enforces this). On release, the Unreleased notes move down
under the new version heading.

## [Unreleased]

### Added
- **App connectors** — `@figma`, `@linear`, `@notion`, `@sentry`, and `@xcode`:
  resolve a reference and drop a live chip into a prompt. Personal tokens are
  stored in the Keychain.
- Settings sections for connectors and on-device intelligence (live model
  availability with a recheck).
- A two-window workspace: the board with a companion dock that share a bottom edge.
- GitHub Actions workflows: CI (release build + tests), tagged releases that
  publish a zipped `BonsAI.app`, and a changelog-entry check on every PR to `main`.
- Project docs: `README`, `CONTRIBUTING` (contribution focus areas + the
  connector philosophy), a `SPLUS.md` review contract, and `docs/semanticlinter.md`.

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

<!--
Add a bullet under the matching heading for every user-facing change. Create a
heading only when you have an entry for it; delete this comment when you do.

### Added     — new capabilities
### Changed   — behavior or UX that changed
### Fixed     — bug fixes
### Removed    — things taken out
-->
