# Alfred workflow scripts for BonsAI

Requires [BonsAI](https://github.com/kiwi-init/BonsAI) running with a board open.

## Capture keyword

1. Alfred Preferences → Workflows → **+** → Blank Workflow
2. Add a **Keyword** input (e.g. `bonsai`)
3. Add a **Run Script** action (Language: `/bin/bash`):

```bash
query="{query}"
PAYLOAD=$(python3 -c 'import json,sys; print(json.dumps({"text": sys.argv[1]}))' "$query")
RESULT=$(curl -s -m 5 -X POST http://127.0.0.1:7337/capture \
  -H 'Content-Type: application/json' \
  -d "$PAYLOAD")
echo "$RESULT"
```

4. Add **Post Notification** or **Copy to Clipboard** on success if desired.

## Open with captured selection (macOS Services alternative)

Use Alfred's **Universal Action** on selected text with the same curl payload, or rely on BonsAI's built-in **Services → Send to BonsAI** (no Alfred required).

## Read board

```bash
curl -s http://127.0.0.1:7337/canvas | python3 -m json.tool
```

Full API reference: [docs/canvas-api.md](../../docs/canvas-api.md)
