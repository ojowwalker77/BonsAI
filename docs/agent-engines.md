# Agent engines: `claude -p`, `codex exec`, and Apple Intelligence

> BonsAI never ships its own model or an API key. Every "AI" surface shells out
> to a coding-agent CLI you already have, or to the model already on your Mac.
> This document is the map of which engine runs where, how each is invoked, and
> how one gets picked — and how to add another.

There are four engines today — three CLI, one on-device — each earning its place
on a different surface:

| Engine                 | CLI / runtime                | Where it's used                                          | Mode                 |
| ---------------------- | ---------------------------- | ------------------------------------------------------- | -------------------- |
| **Claude Code**        | `claude -p`                  | Refine, Compile, **and** the in-canvas chat agent       | one-shot + streaming |
| **Codex**              | `codex exec`                 | Refine, Compile, **and** the in-canvas chat agent       | one-shot + streaming |
| **OpenCode**           | `opencode run`               | Refine, Compile, **and** the in-canvas chat agent       | one-shot + streaming |
| **Apple Intelligence** | on-device Foundation Models  | the semantic linter (only)                              | on-device, in-process |

Two facts to anchor on before the details, because they're the things people
assume wrong:

1. **The CLI engines run through one shared layer built for more.** Engine choice
   runs through a small enum + preference + capability machinery (below) that's
   deliberately multi-engine — Claude, Codex, and OpenCode are the three `case`s
   wired up today, on **both** surfaces. Adding Pi or another agent CLI is a
   well-scoped change — see [Adding an engine](#adding-an-engine).
2. **Apple Intelligence is *not* a fallback for chat or refine.** It is a
   separate, in-process, on-device path that today powers exactly one feature —
   the [semantic linter](semanticlinter.md). See
   [What about Apple Intelligence as a fallback?](#what-about-apple-intelligence-as-a-fallback)
   for the honest state and what a real fallback would take.

---

## The two CLI execution paths

The CLI engine is reached through one of two code paths. They look similar
(`Process`, augmented `PATH`) but differ in everything that matters: lifetime,
output shape, and whether the board is in the loop.

### Path 1 — one-shot text transform ([`HeadlessPromptService`](../Sources/ComposerApp/Services/HeadlessPromptService.swift))

This backs the **Refine** actions (selection rewrite, whole-draft intents) and
**Compile to draft**. It's a pure function over text: send a prompt on the
command line, read stdout, done. No streaming, no session, no tools, no MCP.

```text
claude -p "<prompt>"
```

The prompts live in
[`RefineIntent`](../Sources/ComposerApp/Support/RefineIntent.swift)
(`Tighten` / `Concise` / `Spec` / `Checklist`) and `BoardCompile`, and they all
share one contract: preserve the author's voice, keep every `@mention` token
verbatim, return only the rewritten text — no preamble, no fences.

The engine argument list is built in a `switch` over `HeadlessEngine`, so a new
engine's invocation (and any **headless/non-interactive flags** it needs) is one
new `case` here. Failure handling is deliberately blunt: a non-zero exit becomes
the trimmed stderr surfaced as a toast; empty stdout is treated as failure too.

Refine and Compile pass no `--model`, so they stay on the CLI's own default; the
per-engine provider + model pick applies to the streaming chat agent (Path 2). The
one-shot `run(...)` still takes an optional `model`, but no current caller sets it.

### Path 2 — streaming canvas agent ([`CanvasAgent`](../Sources/ComposerApp/Services/CanvasAgent.swift))

This is the conversational agent in the dock. Each turn spawns the selected engine
in a streaming-JSON mode with the **canvas MCP server attached**, so the agent can
read and reshape the board live while it talks. `CanvasAgent` owns the process
lifecycle, the transcript, and the run-token that guards a superseded turn; the
per-engine differences — how to build the invocation and how to parse the stream —
live behind a [`CanvasChatEngine`](../Sources/ComposerApp/Services/CanvasChatEngine.swift)
adapter (`ClaudeChatEngine` / `CodexChatEngine` / `OpenCodeChatEngine`). Each adapter
turns its CLI's stream into the same normalized `AgentStreamEvent`s
(`assistantText` / `toolSummary` / `session`), so one transcript renders them all.
The engine is chosen at send time by `CanvasAgent.resolvedEngine()` — the user's
pick from the Agent-dock engine picker when it's enabled and installed, otherwise
the first enabled + installed engine in preference order.

The three invocations, same board over the same loopback MCP endpoint:

**Claude** — `stream-json` + MCP over `--mcp-config`, plus the permission arbiter:

```text
claude -p "<prompt>"
  --model <opus|sonnet|haiku>                # the chat model; default opus
  --output-format stream-json --verbose
  --mcp-config '{"mcpServers":{"canvas":{"type":"http","url":"http://127.0.0.1:7337/mcp"}}}'
  --allowedTools "mcp__canvas__*"            # + ,Read,Grep,Glob when grounded
  --append-system-prompt "<system prompt>"
  [--resume "<session-id>"]                  # second turn onward
```

What each piece buys us:

- **`--model`** — which Claude model the chat runs on, read from
  [`ModelPreferences`](../Sources/ComposerApp/Support/ModelPreferences.swift) at
  send time (default Opus). It's a CLI *alias* (`opus` / `sonnet` / `haiku`), so
  the CLI resolves it to the latest model in that tier — BonsAI never pins a
  dated snapshot. The picker lives on the Agent panel's composer row and mirrors
  the one in Settings ▸ Models (both bind the same `UserDefaults` key).
- **`--output-format stream-json --verbose`** — the agent emits one JSON object
  per line (`system` / `assistant` / `result`). `handleLine(_:)` parses those
  into the chat transcript: assistant `text` becomes a reply, `tool_use` becomes
  a one-line "read the board" / "drew a diagram · 4 cards" summary.
- **`--mcp-config …`** — points Claude at the loopback
  [canvas MCP server](canvas-agent.md). This is *how* the agent reaches the
  board; the tool half is documented in [canvas-agent.md](canvas-agent.md).
- **`--allowedTools`** — canvas tools only by default. When a **grounding
  directory** is set, `Read,Grep,Glob` are added so the agent can argue from real
  files (read-only — it still can't write to disk; its output goes onto the
  canvas).
- **`--append-system-prompt`** — the agent's whole personality and the layout /
  authorship / lineage rules. This is the product's brain; it lives as
  `CanvasAgent.systemPrompt` (+ `groundingAddendum`).
- **`--resume`** — session continuity. The `session_id` from the stream's
  `init` / `result` events is stashed and replayed next turn, so it's one ongoing
  conversation rather than N cold starts.

**Codex** — `exec --json`, canvas MCP over `-c mcp_servers.*`:

```text
codex exec [resume "<thread-id>"] "<system prompt + prompt on turn 1>"
  --json --skip-git-repo-check --ignore-user-config
  --sandbox read-only --cd <grounding-or-scratch-dir>
  -c approval_policy="never"
  -c mcp_servers.canvas.url="http://127.0.0.1:7337/mcp"
  -c mcp_servers.canvas.default_tools_approval_mode="approve"
```

The load-bearing choices: **`default_tools_approval_mode="approve"`** auto-approves
the (board-only) canvas tools — without it, headless `exec` cancels every MCP call
because it can't answer the approval prompt. **`--sandbox read-only`** keeps Codex
off the user's disk while still letting it read grounded files (its file reads don't
need escalation). **`--ignore-user-config`** skips the user's `config.toml` so their
other MCP servers can't crowd out canvas during startup (auth still comes from
`$CODEX_HOME`). Codex has no `--append-system-prompt`, so the system prompt is
prepended to the first turn's message; later turns `codex exec resume <thread_id>`
carry the context. `CodexChatEngine.parse` reads `thread.started` for the session id
and `item.completed` for the assistant message, MCP tool calls, and shell commands.

**OpenCode** — `run --format json`, canvas MCP injected inline:

```text
OPENCODE_CONFIG_CONTENT='{"mcp":{"canvas":{"type":"remote","url":".../mcp","enabled":true}},
                          "permission":{"edit":"deny","bash":"deny"}}'
opencode run --format json --dangerously-skip-permissions
  --dir <grounding-or-scratch-dir> [--session "<id>"]
  "<system prompt + prompt on turn 1>"
```

OpenCode configures MCP through its config, so the canvas server is injected via
`OPENCODE_CONFIG_CONTENT` (its highest-priority source) alongside a permission policy
that **denies edits and shell** — the agent's writes belong on the board, not on
disk — while `--dangerously-skip-permissions` auto-approves what's left (the canvas
tools and file reads). Continuity is `--session <id>`. `OpenCodeChatEngine.parse`
reads `text` / `tool_use` parts and the `sessionID` that rides every event.

Unlike Path 1, this path streams: `CanvasAgent` reads `stdout.bytes.lines`
incrementally and appends messages as they arrive, and `stop()` terminates the
live `Process`. Adding an engine to Path 2 means writing a `CanvasChatEngine`
adapter — a bigger lift than Path 1's single `case`, but a well-worn one now.

> **Reliability note.** The canvas MCP handshake (`initialize` / `tools/list` /
> `ping` / notifications) is answered **off the MainActor** (see
> [`CanvasMCP.dispatch`](../Sources/ComposerApp/Services/CanvasMCP.swift)); only
> `tools/call` hops to the MainActor to touch the board. Codex's Rust MCP client has
> a short startup handshake window, and hopping to a busy MainActor just to echo
> static capabilities used to lose that race intermittently, so the canvas server
> failed to register. Keep the handshake board-free.

---

## How an engine gets chosen

Two independent gates, then a preference order. A user setting answers *"may I
use this?"*; capability detection answers the separate, practical question
*"can I use it right now?"*. With one engine this is nearly trivial today, but the
machinery is what keeps adding the next engine cheap.

### Enablement — [`EnginePreferences`](../Sources/ComposerApp/Support/EnginePreferences.swift)

A per-engine on/off toggle in Settings, **defaulting to on**, backed by
`UserDefaults` (`engine.claude.enabled`).

### Availability — [`EngineCapabilityStore`](../Sources/ComposerApp/Services/EngineCapabilityService.swift)

The single observable source of truth for Settings, the refine actions, and the
agent chrome. For each engine it holds a `RuntimeAvailability`
(`checking` / `available(path, version)` / `unavailable(reason)`):

- **Locating the binary.** `CommandLineToolLocator` resolves `claude` by scanning
  the usual CLI homes (`~/.local/bin`, `~/.bun/bin`, Homebrew, `~/.claude/bin`, …)
  **without opening a login shell**. This matters: a Finder-launched GUI app
  inherits a sparse `PATH`, so naïvely spawning `claude` would just fail to
  resolve.
- **Detecting version.** `detect(_:)` runs `<bin> --version` and keeps the first
  non-empty line.
- **Not re-checking on every launch.** The first-ever launch detects and
  persists a snapshot; later launches restore it and only re-shell `--version`
  when the user hits **Recheck** in Settings.

### Preference order — `preferredEngine()`

For surfaces that don't take an explicit engine (Compile), `preferredEngine()`
returns the first engine that is *both* enabled and available:

```swift
// ComposerCanvas.runCompile() → preferredEngine()
if EnginePreferences.isEnabled(.claude), capabilities.isAvailable(.claude) { return .claude }
return nil   // → "No engines enabled in Settings"
```

Refine-selection takes the engine the user picked in the selection bar (one
button per enabled engine); the linter's **"Refine with …"** escalation follows
the resolved **Chat Agent** engine (`resolvedChatEngine()` → `resolvedEngine(for:
.chat)`), so the popover shows that engine's logo and clarifies with it — Claude,
Codex, or OpenCode. The streaming chat has its own explicit pick (the Agent-dock
engine picker, key `engine.chat.selected`), resolved by
`CanvasAgent.resolvedEngine()` — the user's choice when it's ready, else this same
preference order. If a chosen engine is disabled or missing, the action toasts and
stops rather than silently substituting a different model. The order of the cases
in `HeadlessEngine` *is* the preference order, so adding an engine slots it in by
where its `case` sits.

---

## Adding an engine

The engine layer is the deliberate extension point, and contributions that add an
agent CLI (Codex, OpenCode, Pi, …) are welcome. The touch points, in order — the
compiler will walk you through most of them once you add the `case`:

1. **`HeadlessEngine`** ([`Models/ComposerModels.swift`](../Sources/ComposerApp/Models/ComposerModels.swift))
   — add a `case` and its `systemImage`, `logoResourceName`, and `commandLabel`.
   Every `switch` over the enum becomes a compile error until handled — that's the
   checklist working for you.
2. **A brand logo** (optional) — drop an SVG in
   [`Resources/Logos/`](../Sources/ComposerApp/Resources/Logos) matching
   `logoResourceName`; without one, `EngineLogo` falls back to the SF Symbol in
   `systemImage`.
3. **`EnginePreferences`** — add an `engine.<name>.enabled` key and the
   `isEnabled` case.
4. **`HeadlessPromptService.run`** — add the `case` that builds the CLI argument
   list. **Mind non-interactive flags**: the one-shot path can't answer prompts,
   so the engine must run fully headless (this is exactly the rock the old Codex
   path needed `exec --ask-for-approval never` to get past).
5. **`SettingsView`** — add an `engineRow` (and its `@AppStorage` toggle) to the
   ENGINES ledger so the user can see and gate it.
6. **`SelectionActionBar`** — add the engine's case to `enabledEngines` so it gets
   a Refine button.
7. **`AgentEngineIcon`** — nothing to do beyond adding the `case`; it and
   `preferredEngine()` iterate `HeadlessEngine.allCases`, so the new engine slots
   into the preference order by where its `case` sits.

That covers the **one-shot** surfaces (Refine / Compile). To also put it on the
**streaming chat agent**, add a `CanvasChatEngine` adapter
([`CanvasChatEngine.swift`](../Sources/ComposerApp/Services/CanvasChatEngine.swift)):
a `launch(...)` that builds the streaming invocation (canvas MCP attached, session
resume, headless tool-approval) and a `parse(...)` that maps the CLI's stream onto
`AgentStreamEvent`s, then wire it into `CanvasChatEngines.adapter(for:)`. That's a
larger lift than the one-shot `case`, but it's a well-worn path now — the existing
three adapters are the templates.

---

## `PATH` for a GUI-launched app

Worth calling out once because it bites every new CLI integration: a Finder- or
Dock-launched app gets a **minimal `PATH`**, so `claude`, `gh`, etc. won't
resolve the way they do in your terminal. Both execution paths fix this the same
way — they prepend the usual CLI locations (Homebrew, `~/.local/bin`,
`~/.bun/bin`, `~/.cargo/bin`, …) before running:

- [`Shell.augmentedEnvironment()`](../Sources/ComposerApp/Services/Shell.swift)
  for Path 1 (and it runs everything off the main thread, draining stdout/stderr
  concurrently to avoid the classic pipe-deadlock).
- `CanvasAgent.augmentedPATH(_:)` for Path 2.

`CommandLineToolLocator` deliberately mirrors the same set so detection and
execution agree on where a binary lives.

---

## What about Apple Intelligence as a fallback?

Short answer: **there isn't one today, and the code should be read with that in
mind.** It's a natural thing to assume (BonsAI does use on-device intelligence),
so here is the precise state:

- **Apple Intelligence is used by exactly one feature** — the
  [semantic linter](semanticlinter.md), via Apple's Foundation Models
  (`SystemLanguageModel` / `LanguageModelSession`) inside
  [`SemanticLintService`](../Sources/ComposerApp/Services/SemanticLintService.swift).
  It runs **in-process**, not as a CLI, and is chosen for that surface precisely
  because it's free-per-call, private, and offline — the right fit for something
  that fires on every typing pause.
- **The chat agent does not fall back to it.** If `claude` isn't installed,
  `CanvasAgent` posts an error ("Couldn't find the `claude` CLI…") and stops.
- **Refine / Compile do not fall back to it either.** If no CLI engine is enabled
  and available, `preferredEngine()` returns nil and the action toasts.

`EngineCapabilityStore` *does* track Apple Intelligence availability
(`appleIntelligenceAvailability()` — gated on **macOS 26+** with Apple
Intelligence enabled and the model ready), but that state today only drives the
linter's on/off and the Settings readout. It is the obvious hook if we ever want
a true offline fallback.

**If you want to build that fallback,** the on-device model is a poor fit for the
*agentic* path (it has no tools and a small context window, so it can't drive the
canvas MCP), but it's a reasonable fit for the *one-shot text transforms*. The
shape would be: extend `preferredEngine()` (or `HeadlessPromptService`) to fall
through to a Foundation Models path when no CLI engine is available, reusing the
same `RefineIntent` / `BoardCompile` prompts against a `LanguageModelSession`.
Keep the linter's hard precision bias in mind — and don't wire it into the chat
agent, which fundamentally needs tools the on-device model doesn't have.

---

## See also

- [canvas-agent.md](canvas-agent.md) — the board as an agent-readable graph: the
  MCP tools, the loopback server, and how the chat agent reads and writes board
  state.
- [semanticlinter.md](semanticlinter.md) — the on-device Apple Intelligence
  feature in full.
