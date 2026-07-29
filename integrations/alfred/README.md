# Alfred workflow scripts for BonsAI

Requires [BonsAI](https://github.com/ojowwalker77/BonsAI) running with a board open.

## Capture keyword

1. Alfred Preferences → Workflows → **+** → Blank Workflow
2. Add a **Keyword** input (e.g. `bonsai`)
3. Add a **Run Script** action (Language: `/bin/bash`):

```bash
query="{query}"
BONSAI_TEXT="$query" python3 - "$HOME/Library/Application Support/Composer/Canvas/session.json" <<'PY'
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
        print(response.read().decode())
except urllib.error.HTTPError as error:
    print(error.read().decode(), file=sys.stderr)
    raise SystemExit(1)
PY
```

4. Add **Post Notification** or **Copy to Clipboard** on success if desired.

## Open with captured selection (macOS Services alternative)

Use Alfred's **Universal Action** on selected text with the same authenticated Python request, or
rely on BonsAI's built-in **Services → Send to BonsAI** (no Alfred required).

## Read board

```bash
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

Full API reference: [docs/canvas-api.md](../../docs/canvas-api.md)
