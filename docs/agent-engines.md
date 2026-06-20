# Agent engines: `claude -p`, `codex exec`, and Apple Intelligence

> BonsAI never ships its own model or an API key. Every "AI" surface shells out
> to a coding-agent CLI you already have, or to the model already on your Mac.
> This document is the map of which engine runs where, how each is invoked, and
> how one gets picked.

There are **three** engines, and they are not interchangeable — each earns its
place on a different surface:

| Engine                | CLI / runtime                  | Where it's used                                          | Mode                |
| --------------------- | ------------------------------ | ------------------------------------------------------- | ------------------- |
| **Claude Code**       | `claude -p`                    | Refine, Compile, **and** the in-canvas chat agent       | one-shot + streaming |
| **Codex**             | `codex exec`                   | Refine, Compile                                          | one-shot            |
| **Apple Intelligence** | on-device Foundation Models   | the semantic linter (only)                              | on-device, in-process |

Two facts to anchor on before the details, because they're the things people
assume wrong:

1. **The chat agent is Claude-only.** Codex drives the one-shot text transforms
   (Refine / Compile), but the streaming canvas agent shells out to `claude`
   specifically — see [`CanvasAgent`](../Sources/ComposerApp/Services/CanvasAgent.swift).
2. **Apple Intelligence is *not* a fallback for chat or refine.** It is a
   separate, in-process, on-device path that today powers exactly one feature —
   the [semantic linter](semanticlinter.md). See
   [What about Apple Intelligence as a fallback?](#what-about-apple-intelligence-as-a-fallback)
   for the honest state and what a real fallback would take.

---

## The two CLI execution paths

Both CLI engines are reached through one of two code paths. They look similar
(`Process`, augmented `PATH`) but differ in everything that matters: lifetime,
output shape, and whether the board is in the loop.

### Path 1 — one-shot text transform ([`HeadlessPromptService`](../Sources/ComposerApp/Services/HeadlessPromptService.swift))

This backs the **Refine** actions (selection rewrite, whole-draft intents) and
**Compile to draft**. It's a pure function over text: send a prompt on the
command line, read stdout, done. No streaming, no session, no tools, no MCP.

```text
claude:  claude -p "<prompt>"
codex:   codex exec --ask-for-approval never "<prompt>"
```

The `--ask-for-approval never` on Codex is load-bearing: `codex exec` will
otherwise block waiting for an interactive approval that a headless caller can
never give. The prompts themselves live in
[`RefineIntent`](../Sources/ComposerApp/Support/RefineIntent.swift)
(`Tighten` / `Concise` / `Spec` / `Checklist`) and `BoardCompile`, and they all
share one contract: preserve the author's voice, keep every `@mention` token
verbatim, return only the rewritten text — no preamble, no fences.

Failure handling is deliberately blunt: a non-zero exit becomes the trimmed
stderr surfaced as a toast; empty stdout is treated as failure too. The caller
gets a clean `throws` and shows the message.

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
live `Process`.

---

## How an engine gets chosen

Two independent gates, then a preference order. A user setting answers *"may I
use this?"*; capability detection answers the separate, practical question
*"can I use it right now?"*.

### Enablement — [`EnginePreferences`](../Sources/ComposerApp/Support/EnginePreferences.swift)

A simple per-engine on/off toggle in Settings, **defaulting to on**. Backed by
`UserDefaults` (`engine.claude.enabled` / `engine.codex.enabled`).

### Availability — [`EngineCapabilityStore`](../Sources/ComposerApp/Services/EngineCapabilityService.swift)

The single observable source of truth for Settings, the refine actions, and the
agent chrome. For each engine it holds a `RuntimeAvailability`
(`checking` / `available(path, version)` / `unavailable(reason)`):

- **Locating the binary.** `CommandLineToolLocator` resolves `claude` / `codex`
  by scanning the usual CLI homes (`~/.local/bin`, `~/.bun/bin`, Homebrew, the
  per-tool `~/.codex/bin` / `~/.claude/bin`, …) **without opening a login
  shell**. This matters: a Finder-launched GUI app inherits a sparse `PATH`, so
  naïvely spawning `claude` would just fail to resolve.
- **Detecting version.** `detect(_:)` runs `<bin> --version` and keeps the first
  non-empty line.
- **Not re-checking on every launch.** The first-ever launch detects and
  persists a snapshot; later launches restore it and only re-shell `--version`
  when the user hits **Recheck** in Settings. (This stopped Settings from
  flickering "Checking…" and re-spawning every engine each time it opened.)

### Preference order — `preferredEngine()`

For surfaces that don't take an explicit engine (Compile), the order is **Claude
first, then Codex**, and only among engines that are *both* enabled and
available:

```swift
// ComposerCanvas.runCompile() → preferredEngine()
if EnginePreferences.isEnabled(.claude), capabilities.isAvailable(.claude) { return .claude }
if EnginePreferences.isEnabled(.codex), capabilities.isAvailable(.codex) { return .codex }
return nil   // → "No engines enabled in Settings"
```

Refine-selection takes the engine the user picked in the selection bar; the
linter's **"Ask Claude"** escalation always forces `.claude`. There is no
silent cross-engine fallback beyond this Claude→Codex order — if the chosen
engine is disabled or missing, the action toasts and stops rather than quietly
switching models on you.

---

## `PATH` for a GUI-launched app

Worth calling out once because it bites every new CLI integration: a Finder- or
Dock-launched app gets a **minimal `PATH`**, so `claude`, `codex`, `gh`, etc.
won't resolve the way they do in your terminal. Both execution paths fix this
the same way — they prepend the usual CLI locations (Homebrew, `~/.local/bin`,
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
- **Refine / Compile do not fall back to it either.** They fall back only
  Claude→Codex via `preferredEngine()`, and toast if neither is usable.

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
