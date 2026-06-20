# The Semantic Linter

> What a linter is for a programming language, the semantic linter is for the
> **meaning** of your prose. It quietly flags the phrases in a draft that are too
> ambiguous or underspecified for an AI agent to act on without guessing.

This is one of the more experimental parts of BonsAI. We're not fully happy with
it yet — there's plenty of room to make it smarter — but the shape of it is
deliberate, and this document explains that shape so you can improve it without
breaking the properties that make it tolerable to leave on.

The implementation lives in
[`Sources/ComposerApp/Services/SemanticLintService.swift`](../Sources/ComposerApp/Services/SemanticLintService.swift).

## Why it exists

You draft a thought in BonsAI, then hand it to an AI tool. The failure mode isn't
bad grammar — models handle that fine — it's **ambiguity**: a pronoun with no
clear referent, a "make it faster" with no axis, a "like we discussed" the agent
can't see. Those are the places a competent assistant has to *guess*, and might
guess wrong. The linter's whole job is to surface exactly those spots, while you
still have the thought in your head, and nothing else.

## Why it runs on-device

It is backed by Apple's on-device Foundation Model, and that choice is the
feature:

- **Free per call** — so it can run unprompted on *every typing pause*. A cloud
  round-trip per pause would be neither affordable nor fast enough.
- **Private** — your drafts never leave the Mac. That's a precondition for a tool
  meant to hold raw, half-formed thinking.
- **Offline** — it works on a plane.

The task is also a good fit for a small (~3B) model: it's pure
extraction/classification ("which phrase is ambiguous?"), not the open-ended
reasoning or world knowledge such models are weak at.

## It fails silent

The linter is gated behind **macOS 26+ with Apple Intelligence available**. On an
Intel Mac, with AI disabled, or while the model is still downloading, the whole
feature **turns itself off** — `isAvailable` is `false`, `analyze(...)` returns
`[]`, and nothing else in the app changes. There is no error, no banner, no
degraded mode. A user who can't run it simply never sees it.

It also stays silent on model guardrail refusals, context overflow, and trivial
or oversized drafts (shorter than ~12 characters, longer than ~4000). When in
doubt, it produces nothing.

## Precision is the whole game

The model is told, emphatically, to **bias toward precision**: an *unprompted*
squiggle nobody asked for is far more annoying than a missed one, so when in
doubt it does **not** flag. The aim is effectively zero false positives.

It will **never** flag grammar, spelling, tone, politeness, or style, and never
flags a phrase merely for being short. It only flags a phrase that fits one of
five kinds of genuine ambiguity:

| Kind                   | What it catches                                                            |
| ---------------------- | -------------------------------------------------------------------------- |
| `unresolvedReference`  | A pronoun/noun phrase ("it", "the function", "the client") with an unclear target |
| `unspecifiedDimension` | A comparative/change ("larger", "faster", "better") with no stated axis or amount |
| `vague`                | An unmeasurable directive ("clean it up", "make it nice") with no success criterion |
| `conflicting`          | An instruction that contradicts another part of the draft                  |
| `missingContext`       | A reference to knowledge the agent can't see ("like we discussed", "the usual way") |

For each flag the model returns the **verbatim phrase**, the single best-fitting
kind, a short clarifying question (≤ 8 words), and 0–3 concrete drop-in rewrites.

## How a pass works

1. **Trigger.** On a typing pause, `analyze(visibleText:plainText:boardContext:)`
   runs. `visibleText` is what the user sees (used to locate ranges); `plainText`
   is the self-contained serialization that still carries raw connector tokens
   like `@github:<url>` and `@context7:<library>`.
2. **Stateless session.** Each pass uses a fresh `LanguageModelSession` — every
   analysis is independent, and a growing transcript would only waste the small
   context window. A warmed session is kept around (`prewarm()`) so the first
   real pass doesn't pay cold-start latency.
3. **Guided generation.** The model is *constrained* to fill a `@Generable`
   `LintResult` shape — there is no JSON to parse and no malformed output to
   defend against. Invalid shapes can't come back.
4. **Locate, don't trust offsets.** Small models are unreliable at character
   offsets, so we never ask for them. We ask for the verbatim phrase and find it
   ourselves with `NSString.range(of:)`. Anything we can't locate (a paraphrase
   rather than a true quote) is dropped rather than mis-highlighted.

## Connector-awareness

The linter is told what context the draft's connectors resolve, so it doesn't
flag a reference that a chip already answers. A `ConnectorLintContext` summarizes
every resolved token, and a post-filter (`shouldKeep`) drops flags that a present
connector covers — e.g. with a GitHub chip attached, "the issue" is not ambiguous;
with exactly one connector attached, a bare "it"/"this" is assumed to point at it.
Tokens that start with `@`, the object-replacement character, and `[image: …]`
placeholders are resolved attachments and are never flagged directly.

## The board is read-only context

A draft is one card on a larger board. Sibling cards can be passed as
`boardContext`, but they are strictly **read-only**: the model uses them only to
judge whether the *current* card is ambiguous (a sibling may define a term the
current card uses), and is forbidden from quoting or flagging a phrase that lives
in another card.

## Where to improve it

**The prompt is the product's brain.** `SemanticLintService.instructions` and
`userPrompt(...)` encode the entire policy — what counts as ambiguous, what is
off-limits, how connectors resolve references. Most quality changes are prompt
changes, and they should be made *carefully*: loosening the precision bias is the
fastest way to make the feature annoying enough that people turn it off.

Good directions to explore:

- Sharpening the five kinds, or proposing a sixth that pays for itself.
- Better connector-resolution rules in `ConnectorLintContext.shouldKeep`.
- Smarter use of `boardContext` without ever leaking a sibling card into a flag.
- Latency and warm-up behavior on the first pause.

If you change flagging behavior, exercise it against real drafts on a machine
with Apple Intelligence — and remember the north star: **a wrong squiggle is
worse than a missed one.**
