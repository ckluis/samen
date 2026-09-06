---
project: LLMAgent
url: https://github.com/i365dev/llm_agent
category: Agent Frameworks and Development Tools
relevance: low
verdict: Small pre-1.0 signal/handler agent lib on AgentForge; samen already rejected far more mature Jido and shipped its own governed agent loop (ADR-047) — nothing here clears samen's bar.
---

# 045 — LLMAgent

## What the project is

LLMAgent (Hex v0.2.0, MIT, 27 stars / 6 forks, ~53 commits, last push 2026-02-05) is an Elixir abstraction layer for building domain-specific LLM agents on top of the AgentForge workflow framework. It models LLM interaction as signals (`user_message`, `thinking`, `tool_call`) routed through handler modules, keeps conversation state in a store (`get_llm_history/1`), defines tools as maps (`name`/`description`/`parameters` JSON schema/`execute` fn), and supports pluggable providers (OpenAI, Anthropic) behind a common `completion/1` interface. It exists to support the author's MyInvestPilot project. Pre-1.0, no streaming, no telemetry hooks, no error-recovery or deployment story documented; ~6 months since last push.

## What samen could adopt

Effectively nothing as a dependency — samen's ADR-047 agent loop is BUILT with zero new deps, and the Ash-posture gate (ADR-037) plus the Jido evaluation (`_orch/jido-eval-report.md`) already rejected a stronger version of exactly this category (external agent framework, vendor deps, no chokepoint/masking concept). Two marginal pattern-level notes only:

- **Tool-definition-as-data with JSON-schema parameters** — what: tools declared as plain maps with a JSON-schema `parameters` block; why it fits: samen's EG2 egress class treats tool defs/args/results as governed egress, and a uniform schema-carrying tool struct is the shape samen already converged on via `mix samen.gen.agent` — worth a 10-minute skim only to confirm no representation idea was missed; effort S (read-only, no code).
- **Signal-typed agent turns** (`thinking` vs `tool_call` as distinct signal types) — what: explicit turn-phase typing; why it (barely) fits: could inform naming in samen's transcript/RunRecord bounded-outcome vocabulary if that ever gets extended; effort S, and likely already covered by ADR-047's transcript model.

## What to ignore and why

- **The library itself and AgentForge underneath it**: adopting it would import a vendor-adjacent framework into the layer where samen is strongest and most verified. It has no PII/masking concept — every prompt/tool payload is raw strings, structurally incompatible with samen's `%MaskedPayload{}` chokepoint (providers refuse raw strings by FunctionClauseError). INV-4 (vendor-free core) and the ash_ai/Jido rejections apply a fortiori.
- **Its provider adapters**: samen has `samen_anthropic` with fixture-transport cassettes, fail-honest `:not_implemented`, and masked-payload-only entry; LLMAgent's `completion/1` adapters are strictly weaker.
- **Its state/store layer**: samen's transcripts carry erasure-envelope compliance (ADR-046) and budget/cost caps; LLMAgent's conversation store has none of that.
- **Maturity risk**: pre-1.0, single-author, tied to one hobby product, stale ~6 months — below the bar for anything load-bearing.
