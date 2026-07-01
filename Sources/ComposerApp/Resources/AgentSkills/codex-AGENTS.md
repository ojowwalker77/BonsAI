## BonsAI canvas API

BonsAI is a spatial idea board (macOS app). When it's running, it exposes a **loopback-only**
HTTP server at `http://127.0.0.1:7337` for reading and writing the board that's currently
open. Use this whenever the user asks to put/drop/add something on their BonsAI board,
sketch a diagram onto the canvas, or read what's on it.

Check it's up first: `curl -s -m 3 http://127.0.0.1:7337/health` — if that fails to connect,
BonsAI isn't running; tell the user and don't retry in a loop.

Read the board: `curl -s http://127.0.0.1:7337/canvas` → `{ nodes, edges, readingOrder }`.
Each node has `whoWrote` (1 = human, 2 = agent, 0 = unknown) — treat `whoWrote: 1` nodes as
the human's latest input.

Write by POSTing one JSON op per request to `/canvas`:

```bash
curl -s -X POST http://127.0.0.1:7337/canvas \
  --data-binary '{"op":"add_text","text":"Ship the loopback skill"}'
```

Ops: `add_text {text,x?,y?}`, `add_shape {kind: rectangle|ellipse|diamond|line|arrow, w?,h?,x?,y?}`,
`create_diagram {nodes,edges?,direction?}` (preferred for any structure — don't hand-place x/y
yourself), `relayout {direction?}`, `update_text {id,text}`, `move {id,x,y}`, `resize {id,w,h}`,
`delete {id}`, `connect {from,to,reason?}`, `set_archived {id,archived?}`,
`supersede {id,text,reason}` (use this instead of overwriting when an idea evolves — it keeps
the old card, fades it, and links the new one with the reason).

Keep cards short — the canvas holds detail, not paragraphs. Batch related cards with
`create_diagram` rather than many sequential `add_text` calls.
