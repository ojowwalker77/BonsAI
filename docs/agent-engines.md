# Agent engines: `claude -p`, `codex exec`, and Apple Intelligence

> BonsAI never ships its own model or an API key. Every "AI" surface shells out
> to a coding-agent CLI you already have, or to the model already on your Mac.
> This document is the map of which engine runs where, how each is invoked, and
> how one gets picked — and how to add another.

There are three engines today — two CLI, one on-device — each earning its place
on a different surface:

| Engine                 | CLI / runtime                | Where it's used                                          | Mode                 |
| ---------------------- | ---------------------------- | ------------------------------------------------------- | -------------------- |
| **Claude Code**        | `claude -p`                  | Refine, Compile, **and** the in-canvas chat agent       | one-shot + streaming |
| **Codex**              | `codex exec`                 | Refine, Compile (read-only sandbox; no streaming agent) | one-shot             |
| **Apple Intelligence** | on-device Foundation Models  | the semantic linter (only)                              | on-device, in-process |

Two facts to anchor on before the details, because they're the things people
assume wrong:

1. **The CLI engines run through one shared layer built for more.** Engine choice
   runs through a small enum + preference + capability machinery (below) that's
   deliberately multi-engine — Claude and Codex are just the two `case`s wired up
   today. Adding OpenCode, Pi, or another agent CLI is a well-scoped change — see
   [Adding an engine](#adding-an-engine).
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

### Path 2 — streaming canvas agent ([`CanvasAgent`](../Sources/ComposerApp/Services/CanvasAgent.swift))

This is the conversational agent in the dock. Each turn spawns `claude` in
`stream-json` mode with the **canvas MCP server attached**, so the agent can read
and reshape the board live while it talks. The invocation:

```text
claude -p "<prompt>"
  --output-format stream-json --verbose
  --mcp-config '{"mcpServers":{"canvas":{"type":"http","url":"http://127.0.0.1:7337/mcp"}}}'
  --allowedTools "mcp__canvas__*"            # + ,Read,Grep,Glob when grounded
  --append-system-prompt "<system prompt>"
  [--resume "<session-id>"]                  # second turn onward
```

What each piece buys us:

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

Unlike Path 1, this path streams: `CanvasAgent` reads `stdout.bytes.lines`
incrementally and appends messages as they arrive, and `stop()` terminates the
live `Process`. **This path is Claude-specific by design** — it depends on
`stream-json` framing and MCP tool wiring. A new engine can join Path 1 with a
single `case`; joining Path 2 means writing an equivalent streaming + tools
adapter, which is a much bigger lift.

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
button per enabled engine); the linter's **"Ask Claude"** escalation always
forces `.claude`. If the chosen engine is disabled or missing, the action toasts
and stops rather than silently substituting a different model. When a second
engine is added, this is the function that decides the order they're preferred in.

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
7. **`preferredEngine()` and `AgentEngineIcon`** — decide where the new engine
   sits in the preference order for surfaces that auto-pick one.

That covers the **one-shot** surfaces (Refine / Compile). Wiring a non-Claude
engine into the **streaming chat agent** is a separate, larger effort (see
Path 2) and isn't required to land a useful new engine.

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
