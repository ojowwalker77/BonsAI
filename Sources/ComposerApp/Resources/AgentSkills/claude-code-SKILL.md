---
name: bonsai-board
description: Write to (or read) the user's BonsAI board — the spatial idea canvas in the BonsAI macOS app. Use when the user asks to put / drop / add / send something to their BonsAI board, capture an idea or note on the board, sketch a diagram or architecture onto the canvas, evolve an idea already on the board, or read what's currently on it. Works from any repo or directory: BonsAI runs a loopback-only canvas server on 127.0.0.1:7337. Requires the BonsAI app to be running with a board open.
---

# Writing to the BonsAI board

BonsAI is a spatial idea canvas (a macOS app). It exposes a tiny **loopback-only** HTTP
server on `http://127.0.0.1:7337` so any local process — including this agent session — can
read and shape the live board. Your writes appear on screen instantly and are tagged as
agent-authored (`whoWrote: 2`), so the user can tell your cards from theirs.

The board you write to is **whichever board is currently open** in BonsAI — there is no
board addressing.

## Before you write: check it's reachable

```bash
curl -s -m 3 http://127.0.0.1:7337/health
```

- `{"ok":true,...}` → good, proceed.
- Connection refused / timeout → **BonsAI isn't running.** Tell the user to open it; do not retry in a loop.
- A write that returns `{"ok":false,"error":"no active canvas"}` → BonsAI is running but no
  board is open/registered. Ask the user to open a board.

## Reading the board

```bash
curl -s http://127.0.0.1:7337/canvas
```

Returns `{ nodes, edges, readingOrder }`. Each node has `id`, `kind`, `text`, `x/y/w/h`, and
`whoWrote` (**1 = the human wrote/edited it, 2 = you drew it, 0 = unknown**). Read the board
before acting on one you've touched before — `whoWrote: 1` nodes are exactly what the human
added or changed since you last looked.

## Writing: POST one op to `/canvas`

Every mutation is a single JSON object `{"op": "...", ...}` POSTed to `/canvas`. It returns
`{"ok": true, ...}` (often with the new `id`) or `{"ok": false, "error": "..."}`.

```bash
curl -s -X POST http://127.0.0.1:7337/canvas \
  --data-binary '{"op":"add_text","text":"Ship the loopback skill"}'
```

For text with quotes, newlines, or any length, write the JSON payload to a file first so
escaping is correct, then send it.

### Op vocabulary

| op | required | optional | returns |
|----|----------|----------|---------|
| `add_text` | `text` | `x`, `y` | `id` |
| `add_shape` | `kind` (`rectangle`\|`ellipse`\|`diamond`\|`line`\|`arrow`) | `w`, `h`, `x`, `y` | `id` |
| `create_diagram` | `nodes` | `edges`, `direction` | `nodes` (key→id map) |
| `relayout` | — | `direction` | — |
| `update_text` | `id`, `text` | — | — |
| `move` | `id` | `x`, `y` | — |
| `resize` | `id` | `w`, `h` | — |
| `delete` | `id` | — | — |
| `connect` | `from`, `to` (node ids) | `reason` (becomes arrow label) | `id` |
| `set_archived` | `id` | `archived` (bool, default true) | — |
| `supersede` | `id`, `text`, `reason` | — | `id` |

`direction` is `"down"` (default) or `"right"`.

Prefer `create_diagram` for any structure (architecture, flow, tree, comparison, decision
graph) — declare nodes + edges in one call and let the board lay it out. Never invent x/y to
place cards yourself.

When an approach changes, call `supersede` instead of silently overwriting — it fades the
old card, adds the new one below, and links them with a `reason`.

## Etiquette

- Keep cards concise; the canvas holds the detail, not long prose.
- Read before mutating a board you've touched; respect `whoWrote: 1` cards.
- One op per request. Batch related cards with `create_diagram` rather than many `add_text`.
- If the server is unreachable, say so once and stop — don't spin retrying.
