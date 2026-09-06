---
project: LangChain for Elixir
url: https://github.com/brainlid/langchain
category: Agent Frameworks and Development Tools
relevance: high
verdict: Do not take the dependency (INV-4 + chokepoint bypass risk) — but mine it hard for patterns; its trajectory-eval testing, tool-argument error feedback, GenAI OTel semconv, and MessageDelta streaming design map directly onto samen's AI plane roadmap.
---

# 041 — LangChain for Elixir

## What the project is

`brainlid/langchain` (Apache-2.0, ~1.2k stars, 214 forks, v0.9.x as of mid-2026, actively maintained) is the de-facto standard Elixir framework for adding LLMs, tools, chains, and agents to applications. It is a from-scratch Elixir design, not a port of the Python LangChain.

Core abstractions:
- **`LLMChain`** — central orchestrator; `run(mode: :while_needs_response)` loops model → tool calls → tool results until the model stops requesting tools (i.e., a built-in agent loop).
- **`LangChain.Function`** — tool definition with `name`/`description`/`parameters_schema` (JSON Schema); tool fns receive validated `arguments` plus a caller-supplied `context` (actor/tenant scoping for permission checks).
- **`Message` / `ContentPart` / `MessageDelta`** — multimodal messages (text, images, files, extended-thinking blocks); streaming is per-chunk `MessageDelta` structs merged into a full message.
- **Providers**: Anthropic (incl. Bedrock + extended thinking), OpenAI (Chat + Responses API w/ server-side context compaction), Google Gemini/Vertex, xAI, DeepSeek, Mistral, Ollama, Cloudflare, local Bumblebee, and a `ChatReqLLM` gateway; multi-provider **fallback chains**; **prompt caching** (Claude/GPT/DeepSeek); token-usage tracking.
- **`LangChain.Trajectory`** — captures the tool-call sequence of a chain run; `assert_trajectory`/`refute_trajectory` ExUnit macros with strict / wildcard / unordered / superset match modes and golden-file round-tripping (`to_map`/`from_map`). Agent-behavior regression testing as a first-class feature.
- **`LangChain.Telemetry` + `LangChain.OpenTelemetry`** — `:telemetry` events (provider, model, duration, tokens) mapped to GenAI semantic-convention spans (Langfuse/Honeycomb/OTLP); message/tool content capture **off by default** for PII; chain context (tenant/user/feature) propagated to all spans (v0.9.5).

Only hard dependency is `req`; OTel is optional. Recent releases (0.9.3–0.9.7) show real production hardening: dependency CVE bumps, Vertex credential-in-URL fix, actionable tool-argument error messages (v0.9.6 tells the model which params are required/missing/unrecognized so it can self-correct).

## What samen could adopt

Samen already rejected ash_ai and Jido and built a first-party AI kernel + agent loop (ADR-043/047) with zero new deps, so this is a pattern quarry, not a dependency. Concrete picks:

1. **Trajectory-based agent regression testing** — capture the tool-call sequence of an ADR-047 agent run (samen already persists transcripts/RunRecords) into a comparable structure with strict/wildcard/unordered/superset matchers, ExUnit assertion macros with diffs, and golden files.
   *Why it fits*: this is exactly samen's verification religion ("every guarantee ships with a proof") applied to agent behavior — it complements `mix samen.verify.agent_coverage` and the red-team eval tier with behavioral regression pins, and golden trajectories are sabotage-able. *Effort: M* (first-party, ~1 module + assertions + generator emission into `gen.agent` scaffolds).

2. **Actionable tool-argument error feedback (v0.9.6 pattern)** — when the model calls an agent-loop tool with wrong/missing/unknown arguments, return a structured error naming required, missing, and unrecognized params instead of a generic failure, so the model self-corrects in the next turn.
   *Why it fits*: cheap loop-reliability win for ADR-047; the error text is derived from the tool schema (already in the catalog), so it stays deterministic and maskable. *Effort: S*.

3. **GenAI semantic-convention OTel spans for the AI plane** — emit `:telemetry` events (provider, model, duration, input/output tokens) from the `Samen.AI` chokepoint and map to OTel GenAI semconv spans, with content capture structurally absent (samen is stronger here: token-blind by construction, vs LangChain's off-by-default flag) and org/plane attributes on every span.
   *Why it fits*: samen already runs opentelemetry(_ecto) with db_statement disabled; this extends the same posture to AI calls and makes agent-loop budgets/cost caps observable in standard tooling. *Effort: S–M*.

4. **MessageDelta streaming design as the reference for the deferred streaming work** — per-chunk delta structs with a deterministic merge function, callbacks invoked per delta, final merged message identical to the non-streaming result. Also study their fix history (reasoning-text stream events, extended-thinking signature round-tripping on tool-result continuations) as a pre-paid bug list.
   *Why it fits*: ADR-047 explicitly deferred streaming; when it lands, the per-turn history-grant re-scrub must run on merged messages, and delta-merge-then-scrub is the clean seam. *Effort: L for the feature itself; S to write the design note now*.

5. **Anthropic prompt caching in `samen_anthropic`** — support `cache_control` blocks on chokepoint-minted `%MaskedPayload{}` system/context segments.
   *Why it fits*: agent loop re-sends grounding catalog + tool defs every turn; caching cuts real cost within existing budget caps, adapter-local change, fail-honest if unconfigured. *Effort: S*.

6. **Provider-fallback shape (design only)** — `with_fallbacks`-style ordered provider list at the chokepoint boundary, each provider still only accepting `%MaskedPayload{}`.
   *Why it fits*: samen is single-provider today; a fallback seam future-proofs Bedrock-Claude or a second vendor adapter without touching core. *Effort: M, defer until a second real provider exists*.

## What to ignore and why

- **The library as a dependency**: `LLMChain` assembles prompts and marshals tool results itself — outside samen's EG2 governed-egress and masking chokepoint — and pulls `req` toward core, violating INV-4. Same structural objection that sank ash_ai (ADR-037). Pre-1.0 API churn (breaking changes across 0.7→0.9) makes it a poor substrate dependency anyway.
- **Multi-provider breadth / ChatReqLLM gateway**: samen's keyless-CI + fixture-cassette + fail-honest adapter model deliberately trades breadth for provable masking; 12 providers is a liability, not a feature, here.
- **Bumblebee/local-model support and Livebook notebooks**: out of scope for samen's server-side product planes.
- **OpenAI Responses server-side context compaction**: vendor-specific state held server-side conflicts with samen's transcript-retention + erasure-envelope compliance (ADR-046); samen must own its history to re-scrub it.
- **`context`-for-permissions tool pattern**: samen already does this stronger via Ash actors + policies + E3 approvals; nothing to import.
