# BonsAI canvas API

> Authenticated loopback HTTP API on `http://127.0.0.1:7337`. BonsAI must be running with a board open.
> External agents (Claude Code, Codex, Cursor, shell scripts) use this to read and shape the live
> board. Settings ▸ Agents can install a short skill doc that teaches each agent this API.

**API version:** `2` (returned by `GET /health`)

---

## Quick check

```bash
curl -s -m 3 http://127.0.0.1:7337/health
# → {"ok":true,"service":"bonsai-canvas","apiVersion":"2","port":7337}
```

- Connection refused → BonsAI is not running.
- `{"ok":false,"error":"no active canvas"}` on mutations → no board is open.

---

## Authenticate without exposing the capability

Every endpoint except `/health` requires the per-launch capability from:

```text
~/Library/Application Support/Composer/Canvas/session.json
```

BonsAI replaces this mode-`0600` descriptor every launch. It contains `apiVersion`, `baseURL`, and
`capability`. Do not print the capability, put it in a URL, or expand it into a process argument.

Use this shell helper. Python reads the descriptor and constructs the authorization header in its
own memory, so the capability never appears in `ps` output:

```bash
bonsai_request() {
  BONSAI_METHOD="$1" BONSAI_PATH="$2" BONSAI_BODY="${3-}" \
  python3 - "$HOME/Library/Application Support/Composer/Canvas/session.json" <<'PY'
import json, os, sys, urllib.error, urllib.request

with open(sys.argv[1], encoding="utf-8") as file:
    session = json.load(file)

body = os.environ["BONSAI_BODY"]
headers = {"Authorization": "Bearer " + session["capability"]}
if body:
    headers["Content-Type"] = "application/json"
request = urllib.request.Request(
    session["baseURL"] + os.environ["BONSAI_PATH"],
    data=body.encode() if body else None,
    headers=headers,
    method=os.environ["BONSAI_METHOD"],
)
opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
try:
    with opener.open(request, timeout=5) as response:
        print(response.read().decode())
except urllib.error.HTTPError as error:
    print(error.read().decode(), file=sys.stderr)
    raise SystemExit(1)
PY
}
```

Run the helper definition and request in the same shell session.

---

## Endpoints

| Method | Path | Body | Response |
|--------|------|------|----------|
| `GET` | `/health` | — | Liveness + `apiVersion` |
| `GET` | `/canvas` | — | Full board graph (`nodes`, `edges`, `readingOrder`) |
| `POST` | `/canvas` | `{ "op": "…", … }` | Mutation result `{ "ok": true/false, … }` |
| `POST` | `/mcp` | JSON-RPC | MCP tool transport (Streamable HTTP, JSON responses only) |

All responses are JSON. The server is bound to **127.0.0.1 only**, validates an exact loopback
`Host`, rejects foreign and `null` browser origins, and does not enable CORS.

---

## Read the board

```bash
bonsai_request GET /canvas | jq .
```

Each node has `id`, `kind`, `text`, `x/y/w/h`, and `whoWrote` (`1` = human, `2` = agent).

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
| `connect` | Connector between cards (`from`, `to`, optional `reason`; `kind` is `arrow` by default or `line`) |
| `supersede` | Evolve an idea (`oldId`, `text`, `reason`) |

Full tool catalog and graph conventions: [canvas-agent.md](canvas-agent.md).

Example — add a card:

```bash
bonsai_request POST /canvas '{"op":"add_text","text":"Fix the race in BoardViewModel"}'
```

---

## MCP (Claude Code / Codex / Cursor)

Point your agent at `http://127.0.0.1:7337/mcp` and configure its authorization header from an
environment variable populated with the session capability (never inline the capability in a config
file or command line). Tools are prefixed `mcp__canvas__*` in Claude Code.

See [canvas-agent.md](canvas-agent.md) for the full tool list.

---

## See also

- [canvas-agent.md](canvas-agent.md) — graph model, MCP tools, authorship rules
