# BonsAI docs

Deeper write-ups on the parts of BonsAI worth understanding before you change
them. Each is one focused topic, written to explain the *why* behind the shape —
not just what the code does.

| Doc | What it covers |
| --- | -------------- |
| [canvas-agent.md](canvas-agent.md) | The board as an agent-readable graph: `CanvasGraph` nodes/edges, the loopback server → MCP → bridge plumbing, the tool catalog, and how agents read and write board state. |
| [canvas-api.md](canvas-api.md) | The loopback HTTP API (`127.0.0.1:7337`): health, read, mutate, MCP, and the authentication helper for scripts and external agents. |
| [releasing.md](releasing.md) | Cutting a signed, notarized release and maintaining the Sparkle update feed. |

For the project overview and how to build, see the [README](../README.md); for
contribution focus areas, see [CONTRIBUTING](../CONTRIBUTING.md).
