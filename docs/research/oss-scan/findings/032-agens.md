---
project: Agens
url: https://github.com/jessedrelick/agens
category: Agent Frameworks and Development Tools
relevance: low
verdict: Small, actively maintained OTP agent-workflow library; samen already built this capability first-party (ADR-047) and the Jido-rejection precedent binds — mine two or three orchestration patterns, adopt nothing as a dependency.
---

# 032 — Agens

## What the project is

Agens is a small (24 stars, ~88 commits) Apache-2.0 Elixir library by a solo author (jessedrelick) for "multi-agent workflows with language models on OTP — dynamic routing, MCP-shaped tools and resources, structured outputs, and pluggable observability." It is inspired by LangChain/LangGraph and CrewAI but leans on BEAM primitives instead of Python-style chains. Latest release v0.2.0 published to Hex on 2026-05-25 (a substantial redesign from v0.1, Aug 2024), so it is alive but pre-1.0 and API-unstable.

Core abstractions in v0.2:
- **Servings** — wrap LM inference behind an `Agens.Serving` behaviour (OpenAI, Anthropic, Ollama, or local `Nx.Serving`/Bumblebee), with a built-in FIFO queue and configurable in-flight limit per Serving (`use Agens.Serving, limit: N`).
- **Routers** — an `Agens.Router` behaviour mapping structured LM outputs to routing instructions; the JSON schema for structured output is assembled per-request from the Router's declared outputs (OpenAI strict-mode compatible).
- **Jobs** — graphs of `Agens.Job.Node`s with a start node; routing between nodes is decided at runtime by the LM. Jobs are addressed by opaque `run_id` (not process name), so the same Job.Config can run many instances in parallel. Supports fan-out (`{:route, node_id, count}`), yield/aggregation, retry-with-LM-reason, sub-jobs (hierarchical composition), and JSON-defined job configs loaded at runtime (`Agens.Job.Config.from_json/1`).
- **Backends** — pluggable observability: lifecycle messages (`{:node_started, msg}`, `{:tool_call, msg, call}`, ...) emitted to the caller process for LiveView/GenServer consumption, plus `Agens.Metrics` telemetry across Job/Node/Serving/tool lifecycles. Tool use is MCP-shaped, executed via the Serving's `tool_call/3` callback (examples use `hermes_mcp`).

## What samen could adopt

Samen should adopt **no code** from Agens — its first-party agent loop (ADR-047, BUILT and accepted 2026-08-17, zero new dependencies) already covers durable multi-step tool use, and Agens fails exactly the tests that got Jido rejected (`_orch/jido-eval-report.md`): a third-party framework sitting where the EG2 egress chokepoint must sit, with no masking concept — every prompt/tool path in Agens moves raw strings, which `Samen.AI` providers refuse by construction. Patterns worth mining:

1. **Per-Serving FIFO queue + in-flight limit** (`use Agens.Serving, limit: N`). What: bounded-concurrency admission control at the provider-wrapper level. Why it fits: samen's AI kernel has budgets/cost caps (ADR-047) but a declarative per-provider in-flight ceiling is a clean backpressure primitive for the `Samen.AI` chokepoint when many agent runs share one Anthropic adapter; it complements (not duplicates) ash_rate_limiter's ingress-only posture. Effort: S.

2. **Opaque run_id addressing for parallel runs of one config**. What: job instances addressed by generated run_id rather than registered name, so the same agent definition runs N concurrent instances trivially. Why it fits: samen's `mix samen.gen.agent` emits agent definitions; if/when operators fan the same agent across many tenant contexts, run_id addressing avoids name-collision plumbing and keys transcript retention (ADR-046) naturally. Effort: S (samen may already do this via Oban job ids — verify before building).

3. **Declarative graph jobs with LM-driven routing + fan-out/yield primitives**. What: agent workflows as data (node graphs, JSON-loadable) with runtime routing, `{:route, node, count}` fan-out and yield/aggregation. Why it fits: samen's automation engine (ADR-039) already compiles Action registries into Reactor graphs with compensation — the interesting delta is *LM-chosen edges* inside a bounded, declared graph, which would let samen offer "agentic automations" where the LM picks the next declared step but can never invent one (fits AI-writes-don't-exist: each mutating node still goes through E3 approvals). Effort: M (a routing-node kind in the existing 8-kind Action registry, not a new engine).

4. **Lifecycle message emission to the caller process**. What: backend emits `{:node_started, ...}` / `{:tool_call, ...}` messages consumable by LiveView. Why it fits: cheap live "agent run" progress UI for the operator plane / support-operator AI surfaces without polling; samen has wide events and telemetry but a caller-process message contract is the simplest LiveView-native seam. Effort: S.

## What to ignore and why

- **Agens as a dependency**: violates the substrate-first invariant (INV-5) and the chokepoint architecture — tool defs/args/results are governed EG2 egress in samen, and Agens has no seam for per-turn history re-scrub or `%MaskedPayload{}`-only providers. Same verdict class as ash_ai and Jido (ADR-037, jido-eval-report).
- **Servings/Bumblebee/Nx local-inference wrappers**: samen is keyless-fake-by-default in CI with a single Anthropic adapter package; local Nx inference is out of scope and would drag heavy deps into exactly the layer INV-4 keeps vendor-free.
- **JSON-defined jobs loaded at runtime**: runtime-loaded workflow definitions are an injection/audit surface samen deliberately avoids — samen's automations are compiled, catalog-grounded, and sabotage-tested; keep workflows as code + data in the repo, not operator-uploaded JSON.
- **Its MCP tool client shape**: samen already ships an MCP *server* with per-operator tokens; Agens's client-side `hermes_mcp` examples solve a different direction and its structured-output plumbing targets OpenAI strict mode, not Anthropic.
- **Maturity risk generally**: solo-maintainer, pre-1.0, one breaking redesign already (v0.1→v0.2 removed `Agens.Agent` entirely) — even the patterns above should be re-derived first-party, not tracked against Agens's API.
