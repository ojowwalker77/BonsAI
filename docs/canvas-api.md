# BonsAI canvas API

> Stable loopback HTTP API on `http://127.0.0.1:7337`. BonsAI must be running with a board open.
> External agents (Cursor, Claude Code, Raycast, Alfred, shell scripts) use this to read and shape
> the live board — the same channel as the in-app agent dock.

**API version:** `1` (returned by `GET /health`)

---

## Quick check

```bash
curl -s -m 3 http://127.0.0.1:7337/health
# → {"ok":true,"service":"bonsai-canvas","apiVersion":"1","port":7337}
```

- Connection refused → BonsAI is not running.
- `{"ok":false,"error":"no active canvas"}` on mutations → no board is open.

---

## Endpoints

| Method | Path | Body | Response |
|--------|------|------|----------|
| `GET` | `/health` | — | Liveness + `apiVersion` |
| `GET` | `/canvas` | — | Full board graph (`nodes`, `edges`, `readingOrder`) |
| `POST` | `/canvas` | `{ "op": "…", … }` | Mutation result `{ "ok": true/false, … }` |
| `POST` | `/capture` | `{ "text": "…" }` | Append a text card `{ "ok": true, "id": "<uuid>" }` |
| `POST` | `/mcp` | JSON-RPC | MCP tool transport (used by Claude Code) |

All responses are JSON. The server is bound to **127.0.0.1 only**.

---

## Read the board

```bash
curl -s http://127.0.0.1:7337/canvas | jq .
```

Each node has `id`, `kind`, `text`, `x/y/w/h`, and `whoWrote` (`1` = human, `2` = agent).

---

## Capture text (quick append)

```bash
curl -s -X POST http://127.0.0.1:7337/capture \
  -H 'Content-Type: application/json' \
  -d '{"text":"Fix the race in BoardViewModel"}'
```

Equivalent canvas op:

```bash
curl -s -X POST http://127.0.0.1:7337/canvas \
  -H 'Content-Type: application/json' \
  -d '{"op":"capture","text":"Fix the race in BoardViewModel"}'
```

---

## Mutate the board

`POST /canvas` accepts one operation per request. Common ops:

| `op` | Purpose |
|------|---------|
| `add_text` | One text card (`text`, optional `x`/`y`) |
| `add_equation` | One LaTeX math card (`latex`, optional `x`/`y`; no `$` delimiters needed) |
| `create_diagram` | Nodes + edges (`nodes`, `edges`, optional `direction`) |
| `relayout` | Tidy layout (`direction`: `TB` or `LR`) |
| `update_text` | Replace card text (`id`, `text`) |
| `connect` | Arrow between cards (`from`, `to`, optional `reason`) |
| `supersede` | Evolve an idea (`oldId`, `text`, `reason`) |

Full tool catalog and graph conventions: [canvas-agent.md](canvas-agent.md).

Example — add a card:

```bash
curl -s -X POST http://127.0.0.1:7337/canvas \
  -H 'Content-Type: application/json' \
  -d '{"op":"add_text","text":"Ship smart paste"}'
```

---

## MCP (Claude Code / Codex with tools)

Point your agent at `http://127.0.0.1:7337/mcp`. Tools are prefixed `mcp__canvas__*` in Claude Code.

See [canvas-agent.md](canvas-agent.md) for the full tool list.

---

## URL scheme & Services (macOS)

| Entry point | Usage |
|-------------|--------|
| **Menu bar** | Click the leaf → type → ↩ (summons board + new card) |
| **Services** | Select text anywhere → **BonsAI → Send to BonsAI** |
| **URL** | `open 'bonsai://capture?text=Hello%20world'` |

---

## Integrations

- [Raycast](../integrations/raycast/README.md) — append to board, read graph
- [Alfred](../integrations/alfred/README.md) — workflow scripts

---

## See also

- [canvas-agent.md](canvas-agent.md) — graph model, MCP tools, authorship rules
- [agent-engines.md](agent-engines.md) — Refine / Compile / in-app agent engines
