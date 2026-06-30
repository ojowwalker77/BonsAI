# BonsAI docs

Deeper write-ups on the parts of BonsAI worth understanding before you change
them. Each is one focused topic, written to explain the *why* behind the shape —
not just what the code does.

| Doc | What it covers |
| --- | -------------- |
| [agent-engines.md](agent-engines.md) | The AI engines — `claude -p`, `codex exec`, and on-device Apple Intelligence — how each is invoked (one-shot vs. streaming), how one gets selected, and how to add another. |
| [canvas-agent.md](canvas-agent.md) | The board as an agent-readable graph: `CanvasGraph` nodes/edges, the loopback server → MCP → bridge plumbing, the tool catalog, and how the agent reads and writes board state. |
| [canvas-api.md](canvas-api.md) | The loopback HTTP API (`127.0.0.1:7337`): health, read, capture, mutate, MCP — for external agents, Raycast, and Alfred. |
| [semanticlinter.md](semanticlinter.md) | The invisible on-device semantic linter: why it runs on Apple's Foundation Models, its precision bias, and the kinds of ambiguity it flags. |

For the project overview and how to build, see the [README](../README.md); for
contribution focus areas and the connector philosophy, see
[CONTRIBUTING](../CONTRIBUTING.md).
