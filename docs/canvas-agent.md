# The canvas agent and the board as an agent-readable graph

> The board isn't just a UI an agent draws into — it's a live, structured graph
> the agent can **read**, reason over, and **reshape**, with every change landing
> on screen instantly. This document explains the graph the agent sees, the
> plumbing that lets an external CLI process touch the in-app board safely, and
> the conventions that keep a worked-on board legible.

The conversational half of this — how `claude` is spawned in streaming mode with
this server attached — lives in [agent-engines.md](agent-engines.md). This
document is the **board contract**: what the agent reads and how its writes apply.

---

## The board, as the agent sees it

On disk and in memory the board is just an array of cards
([`CardState`](../Sources/ComposerApp/Support/CardState.swift)) — text cards,
shapes, images, and bound arrows/lines — serialized as JSON. But an agent
shouldn't have to parse the editor's internal model, so we expose a clean,
serializable projection: [`CanvasGraph`](../Sources/ComposerApp/Support/CanvasGraph.swift).

It has three parts — **nodes**, **edges**, and **reading order**:

### Nodes

Every card becomes a node. The fields the agent actually reasons over:

| Field      | Meaning                                                                                  |
| ---------- | ---------------------------------------------------------------------------------------- |
| `id`       | Stable UUID string — what every mutation targets.                                        |
| `kind`     | `text`, `rectangle`, `ellipse`, `diamond`, `line`, `arrow`, `freehand`, `image`.         |
| `text`     | Plain text with `@mention` tokens preserved verbatim (e.g. `@github:…`). Empty for shapes. |
| `x/y/w/h`  | Board-space frame (the board is effectively infinite).                                    |
| `z`        | Stacking order.                                                                           |
| `group`    | Optional group id, if the card is part of a multi-select group.                           |
| `locked`   | Whether direct editing is locked.                                                         |
| `archived` | A **superseded** idea — kept for lineage, faded on the board.                             |
| `whoWrote` | **Authorship: `1` = human, `2` = agent, `0` = unknown/legacy.** The most important field for an agent re-reading a board (see below). |

### Edges — where the "tree" actually lives

There is **no parent-pointer tree** in the model. Relationships are **edges**,
and an edge is realized as a real, first-class card: a `line` or `arrow` whose
`startBindingID` / `endBindingID` bind it to two other cards. The arrow's own
`text` is the **label** — the "why" of the relationship.

`CanvasGraph.snapshot()` derives the edge list by walking the cards, picking out
the bound arrows/lines, and emitting `{ id, from, to, kind }`. So:

- A **hierarchy / tree** (architecture, decision graph) is just a set of nodes
  wired by directed arrows; [`BoardLayout`](../Sources/ComposerApp/Support/BoardLayout.swift)
  arranges them into clean layers. The "tree-ness" is emergent from the edges and
  the layered layout, not a stored structure.
- A **lineage** ("we changed our mind: X became Y") is an old→new edge created by
  `supersede`, with the old node archived/faded.

This is why the agent is told never to invent coordinates: structure is declared
as nodes-and-edges, and the board owns placement.

### Reading order

`readingOrder` is the node ids sorted **top→bottom, then left→right** (banded
into 64pt rows so cards roughly on the same line read left-to-right, ties broken
by `z`). It's the order **Compile** and **Copy** flatten the board in, and the
order an agent should narrate a board in.

---

## The read/write plumbing

An external `claude` process can't touch the in-app `BoardViewModel` directly —
it's a separate process, and the board lives on the main actor. Three small
pieces bridge that gap, loopback-only:

```text
  claude (separate process)
        │  JSON-RPC over HTTP (MCP)
        ▼
  CanvasServer      127.0.0.1:7337  — loopback HTTP, dependency-free (Network.framework)
        │  routes POST /mcp
        ▼
  CanvasMCP         JSON-RPC ⇄ MCP tools  (tools surface as mcp__canvas__<name>)
        │  maps each tool → an op
        ▼
  CanvasBridge      @MainActor seam: snapshot() reads · apply(op) mutates · tags author
        │
        ▼
  BoardViewModel    the live board on screen
```

### [`CanvasServer`](../Sources/ComposerApp/Services/CanvasServer.swift) — the loopback HTTP server

A tiny, dependency-free HTTP server (`Network.framework`) bound to
**`127.0.0.1:7337`**, so the board never leaves the machine. `AppDelegate` starts
it at launch. Endpoints:

| Method · path   | Does                                                              |
| --------------- | ---------------------------------------------------------------- |
| `GET /canvas`   | The full `CanvasGraph` as JSON.                                   |
| `POST /canvas`  | One `{ "op": …, … }` mutation → `{ "ok": …, … }`. (raw op names)  |
| `POST /mcp`     | One MCP JSON-RPC message (the agent's transport).                 |
| `GET /health`   | Liveness check.                                                   |

It's request/response only (no server-initiated SSE — `GET /mcp` returns 405),
and it caps the request buffer at 1 MB so a buggy client can't grow it unbounded.
Canvas mutations are deliberately tiny JSON.

### [`CanvasMCP`](../Sources/ComposerApp/Services/CanvasMCP.swift) — the MCP tool surface

A minimal stateless MCP server over `POST /mcp`. It answers `initialize`,
`tools/list`, and `tools/call`. Each tool maps to a `CanvasBridge` op (except
`get_canvas`, which reads the snapshot directly), and the tools surface to the
agent as **`mcp__canvas__<name>`**.

### [`CanvasBridge`](../Sources/ComposerApp/Services/CanvasBridge.swift) — the main-actor seam

The single point where an off-main-thread request becomes a real edit. The
running canvas registers itself here (`ComposerCanvas.onAppear →
CanvasBridge.register(board)`). `snapshot()` projects the board into a
`CanvasGraph`; `apply(_:)` dispatches one op onto the `BoardViewModel` and returns
a JSON-serializable result, so the agent's change appears on screen immediately.

---

## The tool catalog

What the agent can actually call. Reads are cheap; everything else mutates the
live board and is tagged agent-authored.

| Tool (`mcp__canvas__…`) | Bridge op       | Effect                                                                 |
| ----------------------- | --------------- | --------------------------------------------------------------------- |
| `get_canvas`            | *(read)*        | The whole board as a `CanvasGraph` — nodes, edges, reading order.     |
| `draw_diagram`          | `create_diagram`| **Preferred for structure.** Declare nodes + edges in one call; the board lays them out cleanly. Returns your keys → new ids. |
| `tidy`                  | `relayout`      | Re-flow everything into a clean layered layout.                       |
| `add_text`              | `add_text`      | Add one text card (auto-placed if x/y omitted).                       |
| `add_shape`            | `add_shape`     | Add a shape by bounding box (auto-placed if x/y omitted).            |
| `set_text`              | `update_text`   | Replace a node's text by id.                                          |
| `move_node`             | `move`          | Move a node.                                                          |
| `resize_node`           | `resize`        | Resize a node.                                                        |
| `delete_node`           | `delete`        | Delete a node.                                                        |
| `connect`               | `connect`       | Draw a labeled arrow from one node to another (the label is the "why"). |
| `archive`               | `set_archived`  | Fade a node as superseded, or revive it — keeps lineage.             |
| `supersede`             | `supersede`     | Evolve an idea: fade the old card, add the new one below it, link them with the reason. |

The friendly MCP names (`draw_diagram`, `tidy`, …) differ from the raw bridge op
names (`create_diagram`, `relayout`, …); a direct `POST /canvas` caller uses the
**op** names, the agent uses the **tool** names. The mapping is `CanvasMCP.opForTool`.

---

## How the agent *knows* the board state

Reading is one `get_canvas` call, but using that snapshot well is a discipline
encoded in `CanvasAgent.systemPrompt`:

- **Authorship is the key signal.** Every mutation records `whoWrote`. The bridge
  flips `BoardViewModel.nextAuthor` to `.agent` (2) for the duration of `apply`,
  so agent edits are tagged `2` and direct user gestures stay `1`. When the agent
  re-reads a board it has worked on, scanning for `whoWrote == 1` nodes shows
  **exactly what the human added or changed since it last looked** — and a
  human-authored card phrased as a question ("is this right?", "what about X?") is
  a prompt aimed at the agent, to be answered rather than treated as inert.
- **Re-read before acting on a touched board.** The snapshot is the only state;
  there's no push channel, so the agent re-reads to see the user's latest moves.
- **Positions are the board's job.** `get_canvas` returns coordinates, but the
  agent is told to prefer `draw_diagram` / `tidy` over hand-moving cards — it
  can't track overlaps and crossings in its head.

---

## Layout: declare structure, not coordinates

[`BoardLayout`](../Sources/ComposerApp/Support/BoardLayout.swift) is a pure,
deterministic **Sugiyama-style layered layout** — the spatial reasoning an LLM
can't do reliably by hand. The agent declares which nodes connect to which; the
board assigns ranks (longest-path, cycle-safe), reduces edge crossings
(barycenter sweeps), and places coordinates rank by rank. Disconnected clusters
are laid out independently and flow-packed into rows.

That's the whole reason `draw_diagram` exists and the system prompt forbids the
agent from inventing x/y: hand-placed boards come out tangled, and crossing
arrows read as noise. `createDiagram` builds the entire structure in **one undo
step**, drawing each node as a labeled box (so arrows terminate on an edge
instead of stabbing through floating text), then wires the labeled arrows.

---

## Provenance: a board is a history, not just a latest state

Two mutations exist purely to keep the board legible as decisions evolve:

- **`archive`** fades a node without deleting it.
- **`supersede`** is the important one: it archives the old card, drops the new
  idea just below it, and links **old → new** with the agent's reason. The system
  prompt pushes the agent to use it whenever an approach changes, rather than
  silently overwriting — so the board reads as *how* the thinking got here and
  *why*, not only where it landed.

---

## Security & footprint

- **Loopback only.** Bound to `127.0.0.1`; nothing is reachable off-device.
- **Bounded input.** 1 MB request cap; request/response only (no streaming
  endpoint).
- **Read-only file grounding.** When the chat agent is given a grounding folder,
  it gets `Read,Grep,Glob` and nothing that writes to disk — its output goes onto
  the canvas, never into your files.

---

## See also

- [agent-engines.md](agent-engines.md) — how `claude` is invoked in streaming
  mode with this server attached, and the engine landscape overall.
- [semanticlinter.md](semanticlinter.md) — the on-device linter, which reads the
  same board as read-only `boardContext`.
