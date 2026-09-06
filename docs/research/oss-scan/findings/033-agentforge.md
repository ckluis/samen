---
project: AgentForge
url: https://github.com/i365dev/agent_forge
category: Agent Frameworks and Development Tools
relevance: low
verdict: Tiny dormant signal/handler pipeline library; samen's Reactor-based automation engine (ADR-039) and first-party agent loop (ADR-047) already cover everything it offers with stronger guarantees.
---

# 033 — AgentForge

## What the project is

AgentForge is a lightweight MIT-licensed Elixir library (v0.2.2, ~18 stars, 53 commits) for building
signal-driven data-processing pipelines. Its abstractions are Signals (immutable typed messages),
Handlers (functions of signal + state that emit new signals or mutate state), Flows (sequential
handler compositions), and five Primitives (Transform, Branch, Loop, Wait, Notify). It adds
YAML-configured workflow definitions, execution limits with timeout/statistics, and a small plugin
system. Documentation is well organized (design philosophy, getting-started, core concepts, worked
examples) relative to the codebase's size.

Maturity: the last substantive code change was March 2025 (the 0.2.x releases); the only activity
since is a February 2026 README edit. Effectively dormant, pre-1.0, with no visible production
adopters, no persistence/durability story, no supervision-tree/OTP process model beyond plain
function composition, and no Ash/Phoenix integration.

## What samen could adopt

Nothing warrants adoption. Checked against the digest, every AgentForge concept is already present
in samen in a strictly stronger form:

- **Flows/handlers with compensation** — samen's automation engine (ADR-039) compiles an 8-kind
  `Samen.Automation.Action` registry through `Automation.Compile` into `Reactor.Builder` with
  per-step compensation, runs on AshStateMachine, and bounds outcomes via a RunRecord allowlist.
  Reactor (already ADOPTed per ADR-037) is the mature, saga-capable superset of AgentForge's Flow.
  Adopting AgentForge would be a downgrade. (Effort to adopt: n/a — anti-recommendation.)
- **Agent orchestration** — ADR-047's first-party agent loop (durable multi-step tool use, EG2
  governed egress, E3 approvals for side effects, budgets, `mix samen.verify.agent_coverage`) was
  built after samen explicitly evaluated and rejected Jido, a far more mature agent framework
  (`_orch/jido-eval-report.md`). AgentForge clears none of the bars Jido failed: no masking
  chokepoint concept, no governance, no durability.
- **Execution limits / run statistics** — samen already has budgets/cost caps (ADR-047),
  Automation Health/Breaker, and wide_event/observability in core.
- **YAML-defined workflows** — the one idea samen lacks, but it conflicts with samen's posture:
  automations are catalog-grounded, policy-checked, compiled data structures, not operator-supplied
  config files; a YAML surface would bypass the bounded-action registry. If declarative authoring
  is ever wanted, it belongs as a UI over the existing Action registry, not a YAML loader (M, and
  not sourced from this repo).

The only transferable value is as a ~2-hour reading reference for minimal signal/primitive API
naming if samen ever exposes a simplified public automation-authoring DSL (G22 agent-grounding
packaging). That is inspiration, not adoption (S, optional).

## What to ignore and why

- The entire library as a dependency: pre-1.0, single-maintainer, dormant ~17 months, would violate
  samen's substrate-first and vendor-scrutiny posture (INV-4 spirit; a framework that lost to Jido's
  rejection rationale by a wide margin).
- Plugin system: samen's extension model is Ash extensions/blueprint macros + adapter behaviours
  with fail-honest defaults; an ad-hoc plugin registry adds an ungoverned execution path.
- Wait/Notify async primitives: samen standardizes on Oban (same-transaction enqueue) and
  notifications scope; parallel async mechanisms would fragment the durability story.
