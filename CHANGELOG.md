# Changelog

All notable changes to **BonsAI** are recorded here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project aims to follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Every pull request to `main` adds at least one note under **Unreleased** (the
`Changelog` workflow enforces this). On release, the Unreleased notes move down
under the new version heading.

## [Unreleased]


## [1.3.1] - 2026-07-02

### Added
- **LaTeX equation cards.** The canvas now has an equation tool for native SwiftMath-rendered math
  cards, with editable LaTeX source, theme-aware ink, copy/export support, and a readable fallback
  when an expression does not parse.
- **Canvas image intake and export.** Drag image files directly onto the board, keep them in a
  compressed local asset store, and export a board to PNG with real image content instead of loading
  placeholders.
- **Selectable app fonts.** Appearance settings now include San Francisco, Nohemi, and Satoshi,
  with the required font resources bundled into the app.

### Changed
- **Cleaner bottom command bar.** The grounding-folder control moved out of the bottom tool bar;
  grounding remains available from the agent chat and command palette so the main canvas tools stay
  focused.
- **Hover polish and haptics.** Board menus and card affordances are quieter at rest, reveal on
  hover, and only trigger haptic feedback for intentional hover transitions.

### Fixed
- **Canvas basics are sturdier.** Arrow drawing, zoomed text edits, Finder/iCloud image tagging,
  and selection ink all behave consistently across the board interaction paths.
- **Backspace routing stays scoped.** Regression coverage now protects the distinction between
  deleting selected cards from the bare canvas and editing text inside AppKit or SwiftUI fields.

## [1.3.0] - 2026-07-01

### Added
- **A calmer standard window workspace.** BonsAI now opens as one resizable macOS window with the
  board, Agent, Settings, board switcher, tools, zoom, and grounding controls arranged as floating
  canvas chrome instead of separate side rails and history panels.
- **Codex and OpenCode join the streaming agent.** The in-canvas chat agent now runs on Codex
  (`codex exec --json`) or OpenCode (`opencode run --format json`), not just Claude. Pick one from the
  new engine chip on the Agent panel's composer row — it appears whenever two or more engines are
  ready. Each engine reaches the same board over the loopback canvas MCP server, keeps its own session
  for follow-ups, and streams replies and tool calls into one shared transcript. See
  `docs/agent-engines.md`.
- **OpenCode as a one-shot engine.** OpenCode joins Claude and Codex on Refine / Compile,
  toggleable in **Settings ▸ Runtime ▸ Engines** and gated on the `opencode` binary being installed.
- **Writing on the canvas feels like writing.** Text cards now live-render Markdown headings, bold,
  italics, code, quotes, lists, and checkboxes while keeping the plain text source intact for agents.
  Cards at rest render the formatted version, the selection bar can apply common Markdown actions,
  and Focus Mode expands the active card into a centered writing sheet.
- **Themes and element colors.** Appearance settings now offer BonsAI Dark, BonsAI Light,
  Catppuccin Mocha, and Catppuccin Latte previews. Canvas element colors are theme-relative, so a
  selected tint follows the active palette instead of hard-coding one color value.
- **Better drawing controls.** Holding Shift while drawing or resizing rectangles, ellipses, and
  diamonds constrains them to square/circle/uniform proportions. The bottom color swatch now colors
  new elements and can retint the current selection.
- **The linter's clarify escalation follows your chat engine.** The ambiguity popover's escalate
  button was hardcoded to Claude; it now runs on your resolved **Chat Agent** engine and shows that
  engine's logo — "Refine with Codex" / "Refine with OpenCode" — so a non-Claude setup no longer
  silently reaches for Claude (and the row hides when no engine is installed).
- **Provider + model for the chat agent.** Both **Settings ▸ Models** and the Agent panel now read as
  *pick a provider, then a model*: Claude keeps its Opus/Sonnet/Haiku tiers; OpenCode lists its live
  `opencode models` catalog; Codex offers the model from your `~/.codex/config.toml`. Each is passed
  to the CLI (`--model` / `-m`). Codex now honors your configured model again — the chat runs it with
  `--ignore-user-config` (to protect canvas MCP startup), which had been dropping it — and the
  one-shot Codex path gained `--skip-git-repo-check` so Refine / Compile work from any folder.

### Changed
- **Runs on macOS 14 (Sonoma) and up.** The minimum was lowered from macOS 26 (Tahoe); the board and
  every core feature work throughout. Tahoe-only extras — the Apple Intelligence semantic linter and
  screenshot cleanup, plus the Liquid Glass look — stay gated and quietly turn themselves off below
  macOS 26 or when Apple Intelligence is unavailable, so nothing shows a broken control or a
  missing-glyph icon on older systems.
- **The welcome canvas was refreshed for 1.3.0.** New and existing users get the new Welcome Canvas
  with a smaller bundled image asset that resolves through the app bundle instead of a stale local
  attachment path.

### Fixed
- **Canvas MCP registers reliably for strict clients.** The MCP handshake (`initialize` /
  `tools/list` / `ping`) is now answered off the main thread; only board mutations hop to it. An
  agent CLI with a short startup handshake window (Codex) no longer intermittently fails to see the
  canvas tools while the UI is busy.
- **Newly added engines light up on their own.** The runtime-availability cache used to restore its
  saved snapshot verbatim, so an engine added in an update (OpenCode) stayed stuck on "Checking…" —
  invisible to the agent picker and refine bar — until you hit Recheck. It now detects any engine the
  snapshot doesn't cover on launch.
- **Japanese and other IME input no longer breaks in the canvas editor.** While composing marked text
  (Japanese / Chinese / Korean, or dead-key accents), the editor was reformatting the half-composed
  text and could steal the Return that confirms a candidate, so characters dropped or the wrong
  reading was committed. Composition is now left untouched until it commits.
- **Single-click selects text cards again.** Text blocks no longer jump straight into editing on a
  normal click; single-click selects/moves the card, and double-click enters text editing.
- **The board switcher no longer fights macOS window controls.** The top-left board picker now sits
  in its own lane away from the traffic-light hit boxes.
- **Settings model pickers no longer crush their labels.** The Models row keeps readable copy beside
  the provider/model menus, and falls back to stacking the controls when the panel is narrow.

## [1.2.2] - 2026-06-30

### Added
- **Agent skills for any coding agent.** BonsAI's canvas API (`127.0.0.1:7337`) now ships a portable
  skill doc, not just a Claude Code skill. On first launch, if Claude Code, Codex CLI, and/or Cursor
  are detected on the Mac, BonsAI offers to install the matching doc into each one's own config
  location, so any of them can read and write the board over HTTP. Reinstall or add more anytime
  from **Settings ▸ Connectors ▸ Agent Skills**.
- **Model pickers for the agent chat and board description.** Choose which Claude model each runs on
  (Opus / Sonnet / Haiku). The chat picker lives in the Agent panel header and mirrors a matching
  control in **Settings ▸ Runtime ▸ Models**; describing the board has its own picker in the same
  place. Chat defaults to **Opus**, describe defaults to **Sonnet**. The choice is passed to
  `claude --model`; Refine and Compile stay on the CLI default. The Describe picker disables itself
  (with a note) when Codex — not Claude — is the active engine, since Codex ignores the Claude model.
- **Describe board now preserves image references.** Image cards keep their absolute file paths in
  the board graph, so the copied description can point at the exact picture without granting the
  headless prompt broad local-file read access.

### Fixed
- **Copying a board no longer drops image cards.** An image card now contributes its file path to
  the copied and compiled prompt, so a coding agent can open it — and a board that holds only an
  image no longer copies as "Nothing to copy yet".
- **Board edits made right before quit are no longer lost.** The board autosaves on a ~400ms
  debounce, so an edit landing just before the app closed — including a `delete`/`add_text` op from
  an external agent over the canvas API — could be dropped before the pending save fired. BonsAI now
  flushes the pending save on termination, and a bare `SIGTERM` (e.g. `pkill` from the dev-loop
  relaunch script) is rerouted through the normal quit path so the flush still runs.
- **Image selection ring no longer double-borders.** An image card draws its own rounded border, so
  the accent selection ring — which sat a few pixels outside — read as a second, gapped border. The
  ring now hugs the image's own edge as a single clean outline. Other elements are unchanged.

## [1.2.1] - 2026-06-30

### Added
- **Smart paste.** Pasting a GitHub issue/PR URL, an existing file path (`/…`, `~/…`, or `file://…`), or a library name like `next.js` / `vercel/next.js` now becomes the matching connector chip (`@github`, `@finder`, `@context7`) instead of raw text.
- **Quick capture.** A menu-bar leaf opens a one-line capture field (↩ sends to the current board). macOS **Services → Send to BonsAI** and `bonsai://capture?text=…` use the same path. The loopback API adds `POST /capture`.
- **Codex engine.** Refine and Compile can run through `codex exec` (read-only sandbox) when Codex CLI is installed — toggle in Settings ▸ Runtime.
- **Canvas API docs + integrations.** [docs/canvas-api.md](docs/canvas-api.md) formalizes the `127.0.0.1:7337` API; [integrations/raycast](integrations/raycast/README.md) and [integrations/alfred](integrations/alfred/README.md) ship starter scripts.
- **Agent tool permission prompts.** Agent-run MCP tool calls now ask before running, remember
  allowed tools, and include a Settings control to reset remembered permissions.

### Fixed
- **Shift+Enter in the Agent chat inserts a newline instead of sending.** Shift+Enter breaks the line at the caret. ([#27](https://github.com/ojowwalker77/BonsAI/issues/27))

## [1.2.0] - 2026-06-30

### Added
- **Smart paste.** Pasting a GitHub issue/PR URL, an existing file path (`/…`, `~/…`, or `file://…`), or a library name like `next.js` / `vercel/next.js` now becomes the matching connector chip (`@github`, `@finder`, `@context7`) instead of raw text.
- **Quick capture.** A menu-bar leaf opens a one-line capture field (↩ sends to the current board). macOS **Services → Send to BonsAI** and `bonsai://capture?text=…` use the same path. The loopback API adds `POST /capture`.
- **Codex engine.** Refine and Compile can run through `codex exec` (read-only sandbox) when Codex CLI is installed — toggle in Settings ▸ Runtime.
- **Canvas API docs + integrations.** [docs/canvas-api.md](docs/canvas-api.md) formalizes the `127.0.0.1:7337` API; [integrations/raycast](integrations/raycast/README.md) and [integrations/alfred](integrations/alfred/README.md) ship starter scripts.
- **Agent tool permission prompts.** Agent-run MCP tool calls now ask before running, remember
  allowed tools, and include a Settings control to reset remembered permissions.

### Fixed
- **Shift+Enter in the Agent chat inserts a newline instead of sending.** The input used `.onSubmit`,
  which fired on every Return — including Shift+Return — so holding Shift still sent the message. It
  now follows the standard chat convention (Slack, Discord, Linear): plain **Enter sends**, and
  **Shift+Enter** breaks the line at the caret. ([#27](https://github.com/ojowwalker77/BonsAI/issues/27))

## [1.1.0] - 2026-06-24

### Added
- **Snap to board.** A global hotkey (⇧⌘Space, rebindable in Settings ▸ Keyboard) drops a dim
  crosshair over every display. Drag out a region and it **freezes** into a quick markup step —
  move, arrow, box, highlighter, and text tools with colors, undo, and ⌘↩ to send (Esc cancels) —
  then it lands on the board. The shot is read **entirely on-device**: Vision OCR, then cleaned and
  classified by Apple Intelligence (falling back to raw OCR when it's unavailable), so a screenshot
  now **compiles into the prompt as real text** — a terminal error, transcribed code, a described
  UI, a Markdown table — instead of an inert image the board used to drop on copy. Nothing leaves
  your Mac. The markup overlay mirrors the board's own interaction model (move is the default tool,
  drawing one shape returns to move, double-click adds or edits a text label), works across every
  display, and is also reachable from the command palette (⌘K ▸ "Capture screen to board"). A small
  badge marks an image card once it's been read.

### Changed
- **The board feels immediate.** Drawing shapes, freehand, the selection rectangle, panning, and
  zooming no longer re-render every card each frame — the card layer is isolated (an `Equatable`
  layer with live pan applied outside it) so it rebuilds only when a card actually changes. Editing,
  typing, dragging, and resizing a card still update just that card. Gestures now glide, matching the
  snappiness of the capture overlay; no behavior or features changed.
## [1.0.5] - 2026-06-23

### Added
- **Copy-time shell resolution.** A board can now run shell when you copy it, pasting the output
  straight into the self-contained draft. The syntax mirrors the shell: `$(command)` is command
  substitution (run it, inline its stdout), and `name=(value)` defines a **board-scoped variable** —
  the parentheses bound the value so you can define one mid-sentence, and you reference `$name` /
  `${name}` from any other card, because a board is one thing. A value can be a chip, a `$(…)`
  command, or text; the command behind a variable runs once no matter how many places reference it,
  and the `name=(…)` definition itself is consumed from the copied output (it's plumbing).
  Only names you actually defined match, so `$5` or `$HOME` in prose are left alone. The literal
  source is all that's saved — expansion is recomputed on every copy, exactly like a resolved
  `@app` chip. It's **off by default**: a *Resolve shell at copy time* toggle in Settings ▸
  Connectors turns it on, and even then every copy first confirms which commands will run. A
  command that fails is left literal and reported, so a copy never silently mangles what you wrote.
  On the board the syntax reads as live code — `$(…)` commands tint green and monospaced, variables
  violet — styled the same in the editor and the rendered card. Type `$` to autocomplete the board's
  variables (the same menu `@` uses). Commands run in the board's **grounding folder** when one is
  set (so `git`/`ls`/relative paths work), otherwise your home directory; each command is capped by
  a timeout so a hung tool can't freeze the copy, an identical command runs once per copy, and a
  command that failed lights up **amber** on the board so you can see which `$(…)` to fix.
- **Crisp zoom.** The board now zooms by re-laying-out text at the target scale instead of stretching
  a bitmap, so cards stay sharp at any zoom (and track ⌘+/⌘−). The live editor of the card you're
  actively typing in is still transform-scaled; every other card is crisp.

### Fixed
- **Reloaded image cards came back empty.** An image card now re-decodes reliably when a saved board
  reopens or the card pans back into view, instead of showing the dashed placeholder despite having a
  valid image — the loader runs on every appearance rather than once.

## [1.0.4] - 2026-06-23

### Added
- **⌘K command palette.** A transient spotlight over the board with two sections:
  **Boards** — fuzzy-search every board by title (exact > prefix > substring >
  subsequence ranking; an empty query lists the most recent) — and **Actions** — the
  buried, shortcut-less board commands (Fit, Describe, ground/clear grounding,
  reset/stop agent, compile, copy, new board, toggle Agent, Settings). Esc or click-away
  returns the caret to the card you were editing.
- **Board-wide ambiguity linting.** The invisible on-device semantic linter can now
  analyze the whole board in a single pass, catching contradictions and missing context
  *between* cards — not just ambiguity within one card. It stays fully on-device and
  skips boards too large to fit the model.

### Changed
- **Live agent state in the toolbar and ⌘K palette.** The agent's coarse running state
  is now observed separately from its streaming transcript, so the toolbar and palette
  reflect whether the agent is running without the board re-rendering on every streamed
  token.
- **Hardened board services.** The canvas bridge/server, GitHub and Xcode connectors,
  and board persistence are more defensively guarded against edge-case failures.

### Fixed
- **Stop-then-send no longer breaks the agent.** Hitting stop and immediately sending
  again used to race: the old run's trailing cleanup clobbered the new turn — the spinner
  vanished and the live agent could no longer be stopped. Runs now carry a generation
  token, so only the current turn writes back state.
- **Stop works at the very start of a turn.** A stop fired before the agent process was
  assigned could not terminate the turn; the process launch is now guarded and assigned
  before the run begins.
- **The command palette restores your cursor on cancel.** Esc, click-away, or a second
  ⌘K now returns the caret to the card you were editing; the editing-card reference was
  previously cleared before dismiss could run.

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
