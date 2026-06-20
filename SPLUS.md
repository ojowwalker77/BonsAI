# SPLUS.md — review contract for BonsAI

BonsAI is a macOS scratchpad for turning thoughts into well-formed prompts. It is
a small, opinionated, native AppKit/SwiftUI app with **no third-party
dependencies**. Reviews should protect that smallness and the deliberate
two-window composition above all else.

## Preferences

- **Prioritize, in order:** correctness → user-facing friction/UX → privacy &
  secret handling → concurrency (`@MainActor`/async) → simplicity. Bias toward a
  few high-confidence findings over a long list.
- **Respect the philosophy.** BonsAI exists to remove friction between a thought
  and an entry. Flag changes that add bloat, scope, or steps the user didn't ask
  for — "does this make the prompt longer or change what the tool can do?"
- **Don't relitigate intentional design.** The separate board / dock / settings
  windows and the screen-relative layout are deliberate (see `CLAUDE.md` and
  `AGENTS.md`). Treat them as fixed unless the diff is explicitly reworking them.
- **Skip noise.** No nits on formatting the compiler/SwiftPM already accepts, and
  no rewrites that don't change behavior, unless they remove real duplication.

## Binding nits

1. **The board + dock are two real `NSPanel`s — never an `HStack`, overlay, or
   `ComposerCanvas` child.** Any diff that folds them together, or that routes the
   geometry around `PanelController.positionWorkspace()`, is a must-fix.
2. **Outer workspace layout stays screen-relative.** Reject fixed point widths,
   hard minimums, or intrinsic-size stack layout for dock width, gaps, the rail
   gutter (`Theme.Size.railGutter(in:) == 0.090`), or the toolbar gutter. The top
   toolbar centers on `WorkspaceLayout.toolbarCenterX`, not the reduced board card.
3. **The semantic linter stays fully on-device.** `SemanticLintService` must never
   send draft text over the network, must stay a silent no-op when Apple
   Intelligence is unavailable, and must keep its precision bias (a wrong squiggle
   is worse than a missed one). Flag anything that weakens any of the three.
4. **Connector secrets are sensitive.** API tokens flow through
   `ConnectorSecretStore` only — never logged, never committed, never put in a
   token string or URL that gets persisted. Flag any secret that reaches a log,
   error message, or serialized chip.
5. **Connectors degrade gracefully.** A connector's `render(selection:)` must fall
   back to a plain reference line when the network/CLI fails — never crash, never
   block the main actor. New connectors implement `ComposerAppConnector` and join
   `AppConnectorRegistry.all`; flag bespoke wiring that bypasses the protocol.
6. **No crash-on-user-input.** Flag force-unwraps and unguarded array/string
   indexing on anything derived from pasted text, tokens, URLs, or connector
   responses. The `@token` codec is the source of truth for chips — changes to it
   need round-trip test coverage (see `ConnectorTokenTests`).
7. **User-facing changes carry a `CHANGELOG.md` note.** If a diff changes behavior
   or UX with no Unreleased entry, call it out.
