# Raycast extension scripts for BonsAI

Requires [BonsAI](https://github.com/ojowwalker77/BonsAI) running with a board open.

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

BONSAI_TEXT="$TEXT" python3 - "$HOME/Library/Application Support/Composer/Canvas/session.json" <<'PY'
import json, os, sys, urllib.error, urllib.request
with open(sys.argv[1], encoding="utf-8") as file:
    session = json.load(file)
request = urllib.request.Request(
    session["baseURL"] + "/capture",
    data=json.dumps({"text": os.environ["BONSAI_TEXT"]}).encode(),
    headers={
        "Authorization": "Bearer " + session["capability"],
        "Content-Type": "application/json",
    },
    method="POST",
)
opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
try:
    with opener.open(request, timeout=5) as response:
        data = json.load(response)
except urllib.error.HTTPError as error:
    print(error.read().decode(), file=sys.stderr)
    raise SystemExit(1)
if not data.get("ok"):
    print(data.get("error", "Capture failed"), file=sys.stderr)
    sys.exit(1)
print("Captured on board:", data.get("id", ""))
PY
```

## Read the board (JSON)

```bash
#!/bin/bash

# @raycast.schemaVersion 1
# @raycast.title BonsAI board graph
# @raycast.mode fullOutput

python3 - "$HOME/Library/Application Support/Composer/Canvas/session.json" <<'PY'
import json, sys, urllib.request
with open(sys.argv[1], encoding="utf-8") as file:
    session = json.load(file)
request = urllib.request.Request(
    session["baseURL"] + "/canvas",
    headers={"Authorization": "Bearer " + session["capability"]},
)
opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
with opener.open(request, timeout=5) as response:
    print(json.dumps(json.load(response), indent=2))
PY
```

## Health check

```bash
curl -s http://127.0.0.1:7337/health
```

Full API reference: [docs/canvas-api.md](../../docs/canvas-api.md)
