---
project: Alloy
url: https://github.com/alloy-ex/alloy
category: Agent Frameworks and Development Tools
relevance: medium
verdict: Do not adopt as a dependency (violates INV-4 and has no masking-chokepoint concept), but mine 4-5 concrete agent-loop patterns — until_tool structured output, block/edit middleware seam, versioned streaming event envelope, Anthropic prompt caching, context compaction — into samen's first-party ADR-047 loop.
---

# 034 — Alloy

## What the project is

Alloy is a minimal, OTP-native, model-independent **agent harness for Elixir** — "the agent loop and nothing else." MIT, v0.12.x, ~9,000 LOC, 81 stars / 118 commits, actively maintained, deliberately dependency-light (BEAM primitives + Phoenix.PubSub). Core surface:

- `Alloy.run/2` one-shot loop; `Alloy.Agent.Server` (GenServer) for stateful agents; `Alloy.Agent.Turn` for single-turn execution.
- `Alloy.Provider` behaviour with six adapters: Anthropic, OpenAI, Gemini, Codex, xAI, OpenAICompat (Ollama/OpenRouter/DeepSeek/Mistral/Groq/Together).
- `Alloy.Tool` behaviour + inline tools; ships read/write/edit/bash built-ins (bash has a restricted mode but is explicitly "not a sandbox").
- Unified token-by-token streaming across providers (`Alloy.stream/3`, `Agent.Server.stream_chat/4`), async dispatch via `send_message/2` → request ID → results over PubSub (LiveView-friendly).
- `Alloy.Middleware`: single `call(hook, State.t())` callback over eight lifecycle hooks (`:session_start/:session_end`, `:before_completion`, `:after_completion`, `:after_compaction`, `:after_tool_request`, `:before_tool_call`, `:after_tool_execution`, `:on_error`). From `:before_tool_call` a middleware may return `{:block, reason}` or `{:edit, modified_call}` (id/name immutable, validated with ArgumentError); any hook may `{:halt, reason}`; first block/edit/halt wins.
- `until_tool` structured-output enforcement: the loop terminates only when the model calls a named tool, so output shape is API-schema-validated rather than prompt-instructed.
- `Alloy.Context.Compactor` (configurable summarization), `max_budget_cents` cost guard (halt before overspend), Anthropic prompt caching (claimed 60-90% input-token savings), DeepSeek/xAI reasoning blocks as first-class thinking content, `Alloy.Memory` for Anthropic's memory tool.
- Telemetry: one event `[:alloy, :event]` carrying a versioned envelope `%{v: 1, seq, correlation_id, turn, ts_ms, event, payload}` (event atoms like `:tool_start`/`:tool_end`); streaming deltas surface through an `:on_event` callback.

## What samen could adopt

Samen already **built** its agent loop (ADR-047, accepted 2026-08-17, zero new deps) and has rejected ash_ai and Jido; Alloy is best treated as a well-executed reference implementation to steal patterns from, not a package to depend on.

1. **`until_tool` structured-output termination** — end the loop only when a designated tool is called, making the final output an API-validated schema instead of a prompted format. Why it fits: samen's "AI writes do not exist" posture means every agent outcome is a draft/proposal handed to the E3 approvals engine; a terminal proposal-tool with a validated schema is exactly the right hand-off shape and removes parse-failure red paths. Effort: **S** (loop-termination predicate + one verifier assertion in `samen.verify.agent_coverage`).

2. **Block/edit middleware seam at `:before_tool_call`** — the `{:block, reason}` / `{:edit, modified_call}` / `{:halt, reason}` return contract with id/name immutability enforced by construction. Why it fits: samen's EG2 governance (per-turn history grant re-scrub, governed tool args/results) is currently loop-internal; formalizing it as an ordered hook chain gives a single seam for policy, budget, and masking checks, and the "first block wins + edited call cannot change identity" rule is a fail-closed pattern samen would want verbatim. Effort: **M** (refactor of existing loop internals, no behavior change intended, sabotage patches for the new seam).

3. **Streaming design + versioned event envelope** — samen deferred streaming in ADR-047; Alloy shows the shape to lift it: unified per-provider delta normalization, `:on_event` callback, async `send_message` → request ID → PubSub results for LiveView, and a v1 envelope (`seq`, `correlation_id`, `turn`) that makes event streams replayable/auditable. Why it fits: the envelope aligns with samen's wide-event/audit ethos, and PubSub dispatch matches samen_web's LiveView surfaces. Caveat: samen must re-scrub **per delta** through the masking chokepoint (Alloy does not solve this — it is the hard part). Effort: **L** for streaming itself; **S** to adopt just the envelope shape for the existing non-streaming loop's transcript events.

4. **Anthropic prompt caching in `samen_anthropic`** — cache_control breakpoints on stable prompt prefixes (catalog grounding, tool defs) for 60-90% input-token savings. Why it fits: samen's runtime catalog grounding is a large, stable prefix on every call, and cheaper turns compound with ADR-047 budget caps; it is adapter-local so INV-4 is untouched. Effort: **S** (adapter-only change + fixture-cassette update; verify masked payloads are cached, never raw).

5. **Context compaction with an `:after_compaction` hook** — configurable summarization when transcripts grow. Why it fits: pairs with ADR-046 transcript retention/erasure envelopes (compact-then-retain shrinks the erasure surface); the summary is itself AI output, so it must round-trip the masking chokepoint and be recorded in the audit chain. Effort: **M**.

6. **Model catalog/metadata as data** (`model_catalog.ex` / `model_metadata.ex`) — machine-readable model capabilities/pricing driving budget math. Why it fits: samen's catalog-as-data ethos; enables cost caps computed from declared per-model pricing rather than constants. Effort: **S**.

## What to ignore and why

- **Alloy as a dependency**: its provider adapters embed HTTP/vendor concerns that INV-4 forbids in core; providers accept raw strings (no `%MaskedPayload{}` chokepoint, no PII concept anywhere), so it fails samen's token-blind AI-egress invariant by construction — same reason ash_ai and Jido were rejected.
- **Built-in read/write/edit/bash tools**: filesystem/shell mutation tools contradict "AI writes do not exist"; the bash restricted mode is self-described as not a sandbox. Samen tools are catalog-grounded reads + E3-gated proposals.
- **Six-provider breadth**: samen is Anthropic-first with a deterministic fake provider in CI; multi-provider matrixing adds surface without a current requirement (the `Samen.AI.Provider` behaviour already leaves the seam open).
- **`Alloy.Memory` (Anthropic memory tool)**: samen transcripts are governed artifacts with retention/erasure envelopes; a provider-native memory store would sit outside the vault/audit plane.
- **`max_budget_cents` cost guard**: already covered by ADR-047 budgets/cost caps; at most cross-check the halt-before-overspend semantics.
