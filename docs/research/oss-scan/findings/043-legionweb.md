---
project: LegionWeb
url: https://github.com/software-mansion-labs/legion_web
category: Agent Frameworks and Development Tools
relevance: low
verdict: WiP dashboard for a rival agent framework; samen's ADR-047 agent-oversight surfaces already exceed it — skim only for telemetry-streaming and installer ergonomics.
---

# 043 — LegionWeb

## What the project is

LegionWeb (`software-mansion-labs/legion_web`, MIT, explicitly "[WiP]", ~7 stars, ~15 commits) is an embeddable Phoenix LiveView dashboard for the **Legion** agent framework (`software-mansion-labs/legion`, ~103 stars, ~0.4 on Hex). It gives real-time visibility into agent lifecycle, LLM requests, sandboxed code-execution traces, and results. Integration is `mix legion_web.install` plus a `legion_dashboard "/legion"` router macro (LiveDashboard-style mount); it is unprotected by default and the README tells you to add your own auth pipeline. It renders telemetry events the parent framework emits at every level (`[:legion, :agent|:iteration|:llm|:sandbox, ...]`).

Context on the parent: Legion agents are GenServer-like supervised processes whose LLM **writes executable code** (Lua or AST-restricted Elixir sandboxes) instead of sequential tool calls; providers come via ReqLLM model strings; conversation persistence is a pluggable Postgres/Ecto store.

## What samen could adopt

Very little — samen already built the thing this project is a first cut of. Verified in-repo: `samen_web/lib/samen/web/operator/agent_health_live.ex` (ADR-047 §8/A5: per-definition health aggregates, bounded run+turn log, durable per-{org, definition} kill switch, transcript mask-by-OMISSION with sabotage 261) and `samen_web/lib/samen/web/ai/agent_live.ex` (tenant-plane transcript through PiiResolution). LegionWeb has no masking model, no plane separation, no kill switch.

Residual ideas worth a skim, not a dependency:

1. **Telemetry-event-driven live streaming of agent runs** — what: LegionWeb repaints the dashboard from `:telemetry` events as turns/LLM calls happen, rather than on page refresh/poll. Why it fits: samen's AgentHealthLive shows a *bounded log*; a PubSub/telemetry push so an operator watches a run advance live would improve incident response without touching the token-only projection (events would carry ids/enums/counts only, same mask-by-omission field list). Effort: **S–M** (samen already has cross-plane realtime chat infrastructure and telemetry_metrics in core).
2. **One-command dashboard installer ergonomics** (`mix legion_web.install` auto-patching the router) — what: an Igniter-style installer that wires the mount for you. Why it fits: only as a pattern reference if samen ever packages surfaces for external builders (G22 agent-grounding packaging); samen's `samen.gen.app` already emits routes at generation time, so this matters only for retrofit-into-existing-app scenarios, which ADR-033 (in-monorepo distribution) currently rules out. Effort: **M**, and premature.

## What to ignore and why

- **LegionWeb as a library**: WiP, 15 commits, coupled to Legion's telemetry event schema, unauthenticated by default, and a third-party operator surface — samen rejected ash_admin for exactly this class of reason (first-party operator plane, two-plane discipline). Raw LLM request/response trace rendering would also violate mask-by-omission: samen deliberately never puts transcripts on the operator plane.
- **The Legion framework itself**: same category as Jido, which samen evaluated and rejected (`_orch/jido-eval-report.md`); ADR-047 shipped a first-party loop with zero new deps. Legion's core moves are structurally incompatible with samen's invariants: ReqLLM provider abstraction = vendor/HTTP deps and raw prompt strings (breaks INV-4 and the `%MaskedPayload{}` chokepoint), LLM-generated code execution in sandboxes = an ungoverned side-effect path (samen's rule is "AI writes do not exist"; everything mutating goes through E3 approvals), and "LLM reads tool source code directly" = uncontrolled egress of source into prompts (EG2 governs tool defs/args/results).
- **Its persistence/trace store**: samen already has transcript retention with erasure-envelope compliance (ADR-046); Legion's plain Ecto store has no crypto-shred story.
