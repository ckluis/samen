---
project: Nous
url: https://github.com/nyo16/nous
category: Agent Frameworks and Development Tools
relevance: medium
verdict: Pattern quarry, not a dependency — mine its streaming backpressure, fallback-chain error discrimination, eval ergonomics, and hybrid-retrieval scoring; keep samen's first-party governed agent loop (same call as the Jido rejection).
---

# 046 — Nous (Elixir AI agent framework)

## What the project is

Nous (Apache-2.0, v0.17, Elixir 1.18+/OTP 27+) is a single-author (nyo16) BEAM-native AI agent framework — roughly "Pydantic AI with OTP supervision." ~97 commits, 14 stars, actively maintained, well-documented (18 guides on hexdocs, 18+ runnable examples, Livebooks, an AGENTS.md for coding agents). Feature surface:

- **Unified provider string** (`"provider:model"`) over 13 providers (OpenAI, Anthropic, Gemini/Vertex, Groq, Mistral, OpenRouter, Together, Ollama, LM Studio, vLLM, SGLang, LlamaCpp, custom OpenAI-compatible).
- **Agent loop**: tool calling with concurrent execution + timeouts, structured output via Ecto schemas, ReAct/basic behaviours, sub-agent delegation.
- **Streaming with real backpressure**: Hackney pull-based `[{:async, :once}]` mode so fast LLM streams cannot OOM slow consumers; Task-based streaming with cancellation checks between chunks.
- **HITL approvals**: `Nous.Plugins.HumanInTheLoop`; sync `approval_handler` callback or async via Phoenix.PubSub topics (`"nous:approval:<id>"`), designed for LiveView approval gestures.
- **Hooks**: 6 lifecycle points (`:pre_tool_use`, `:post_tool_use`, `:pre_request`, `:post_response`, `:session_start`, `:session_end`) with matcher-based allow/deny handlers.
- **Memory**: 6 store backends (ETS/SQLite/DuckDB/Muninn-BM25/Zvec-HNSW/Hybrid) behind a `Store` behaviour; 3 embedding providers; hybrid text+vector search merged by Reciprocal Rank Fusion; temporal decay (`exp(-lambda*hours)`, `evergreen` bypass); composite scoring relevance/importance/recency (0.5/0.3/0.2); scope fields agent/session/user/namespace; `remember`/`recall`/`forget` agent tools; optional post-run reflection auto-update.
- **Workflows**: DAG engine (branching, guarded cycles, static/dynamic parallelism, pause/resume checkpoints, per-node retry/skip/fallback, `:human_checkpoint` node, Mermaid export, telemetry).
- **Fallback chains**: automatic provider/model failover — only transport-layer `ProviderError`/`ModelError` trigger fallback; application errors (validation, max-iterations, tool errors) return immediately.
- **Eval framework**: six evaluators (exact_match, fuzzy_match, contains, tool_usage, schema, llm_judge), YAML suites, `mix nous.eval` / `mix nous.optimize` (Bayesian/grid/random), A/B runs, latency/token/cost metrics.
- **LiveView integration**: `notify_pid:` deltas (`{:agent_delta, text}` / `{:agent_complete, result}`), PubSub fan-out per topic, PromEx observability.

## What samen could adopt

Samen already rejected Jido and ash_ai and built a first-party agent loop (ADR-047, zero new deps, EG2 governed egress, E3 approvals). Nous as a dependency is a non-starter (see below), but four of its mechanisms are directly transplantable as patterns:

1. **Pull-based streaming backpressure** — Nous's `[{:async, :once}]` pull loop + between-chunk cancellation checks. *Why it fits*: AI streaming is samen's one explicitly deferred ADR-047 feature; when it lands in `samen_anthropic` (which already owns the `req` HTTP dep), the pull-based pattern preserves the MaskedPayload chokepoint (scrub per chunk before emit) and keeps slow LiveView consumers from being overwhelmed. Nous is a working reference implementation on the BEAM. **Effort: M.**

2. **Fallback-chain error taxonomy** — failover fires ONLY on transport errors; application-level errors never trigger it, plus dedicated telemetry events on activation. *Why it fits*: this is samen's fail-honest posture applied to retries; a provider-fallback seam inside `Samen.AI`'s chokepoint (all candidates still receive only `%MaskedPayload{}`) adds resilience without faking success, and the transport-vs-application split is exactly the discrimination samen's adapter contracts already encode (`:not_configured`/`:not_implemented`). **Effort: S–M.**

3. **Eval-harness ergonomics** — YAML-defined suites run via a mix task, a small evaluator vocabulary (notably `tool_usage` — assert the agent invoked expected tools — and `llm_judge`), A/B comparison, and per-run latency/token/cost metrics. *Why it fits*: samen has a permanent red-team eval tier (≥90% context-assembly bar) and `mix samen.verify.agent_coverage`; borrowing the declarative-suite + `tool_usage` evaluator shape would let ADR-047 agent behaviors (tool selection, approval-gated writes staying drafts) be asserted as data-defined cases, and feeds the G22 "agent-grounding packaging for builders" roadmap item. **Effort: M.**

4. **Composite retrieval scoring for grounding** — RRF merge of BM25/keyword + vector results, temporal decay with `evergreen` exemption, and weighted relevance/importance/recency. *Why it fits*: samen already has pgvector embeddings + non-PII tsvector search; the same RRF + decay + importance formula is a small pure function over two Postgres queries (no new backends needed) and would sharpen runtime catalog/context grounding for the AI surfaces. **Effort: M.**

5. (Minor, reference-only) **Async approval PubSub shape** — per-approval topics with approve/reject messages driving LiveView gestures. Samen's E3 approvals engine already exceeds this (requester ≠ approver at policy AND DB-CHECK layers); worth a glance only when building richer real-time approval UX in the operator plane. **Effort: S.**

## What to ignore and why

- **Adopting Nous as a dependency / replacing the AI kernel**: violates INV-4 (vendor/HTTP deps in core), has no masking-chokepoint concept (raw strings flow to providers — samen's providers refuse raw strings by FunctionClauseError), and its HITL plugin has no second-party/requester≠approver enforcement. Bus-factor-1, 14 stars, pre-1.0 API churn. Same verdict as the Jido eval.
- **13-provider abstraction layer**: samen is deliberately single-adapter (`samen_anthropic`) with fail-honest stubs; a provider zoo multiplies the masked-egress audit surface for no product need.
- **Memory backend zoo (ETS/SQLite/DuckDB/Muninn/Zvec)**: samen is Postgres-only by ADR (pgvector required); alternate stores would fragment the crypto-shred/erasure guarantee and the no-plaintext-PII oracle's sweep surface.
- **Workflow DAG engine**: samen's Automation engine (ADR-039) on Reactor already has per-step compensation, state-machine runs, bounded outcomes, and breakers — strictly stronger; Nous's `:human_checkpoint` ≈ samen's E3 gate.
- **Auto-update "reflection" memory writes**: an AI write path by construction — directly contradicts ADR-047's "AI writes do not exist; outputs are drafts through approvals."
- **Skills system / deep research / teams**: product-layer features orthogonal to the foundry substrate; nothing load-bearing to extract.
