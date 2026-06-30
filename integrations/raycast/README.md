# Raycast extension scripts for BonsAI

Requires [BonsAI](https://github.com/kiwi-init/BonsAI) running with a board open.

## Capture text to the board

Save as a Raycast Script Command (mode: *Silent*, language: *Bash*):

```bash
#!/bin/bash

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title Capture to BonsAI
# @raycast.mode silent
# @raycast.argument1 { "type": "text", "placeholder": "Thought to capture" }

TEXT="${1:-}"
if [ -z "$TEXT" ]; then
  echo "No text provided" >&2
  exit 1
fi

PAYLOAD=$(python3 -c 'import json,sys; print(json.dumps({"text": sys.argv[1]}))' "$TEXT")
RESULT=$(curl -s -m 5 -X POST http://127.0.0.1:7337/capture \
  -H 'Content-Type: application/json' \
  -d "$PAYLOAD")

echo "$RESULT" | python3 -c '
import json, sys
data = json.load(sys.stdin)
if not data.get("ok"):
    print(data.get("error", "Capture failed"), file=sys.stderr)
    sys.exit(1)
print("Captured on board:", data.get("id", ""))
'
```

## Read the board (JSON)

```bash
#!/bin/bash

# @raycast.schemaVersion 1
# @raycast.title BonsAI board graph
# @raycast.mode fullOutput

curl -s -m 5 http://127.0.0.1:7337/canvas | python3 -m json.tool
```

## Health check

```bash
curl -s http://127.0.0.1:7337/health
```

Full API reference: [docs/canvas-api.md](../../docs/canvas-api.md)
