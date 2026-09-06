---
project: Synapse
url: https://github.com/nshkrdotcom/synapse
category: Agent Frameworks and Development Tools
relevance: low
verdict: Early-stage Jido-based orchestration framework whose entire feature set samen has already hand-built (and whose foundation samen explicitly rejected); a couple of design patterns are worth a glance, no code worth adopting.
---

# 048 — Synapse

## What the project is

Synapse (nshkrdotcom/synapse, MIT, v0.1.1 released 2025-11-29, ~49 stars / 4 forks, 71 commits) is a headless, declarative multi-agent orchestration framework in Elixir (~> 1.15, OTP-only, no Phoenix). Components:

- **Signal bus/registry**: domain-agnostic topic registration with per-topic NimbleOptions-style schemas; `Synapse.SignalRouter` pub/sub with telemetry at `[:synapse, :signal_router, :publish|:deliver]`.
- **Declarative workflow engine**: specs with step `id`/`action`/`params` (static or fn), `requires` dependencies, `retry: [max_attempts:, backoff:]`, `on_error: :halt | :continue`, output mapping with path selection/transform. Returns `{:ok, %{results, outputs, audit_trail}}` or a structured error with `failed_step`/`attempts`.
- **Postgres persistence**: `workflow_executions` table recording step-by-step audit trail, accumulated results, optional before/after snapshots per step, request-ID linking; persistence pluggable per execution or globally.
- **Agent runtime reconciliation**: agents declared in `priv/orchestrator_agents.exs` (id, actions, orchestration fns — classify/spawn_specialists/aggregate/negotiate, signal subscribe/emit roles, state_schema); runtime validates, spawns missing agents, monitors health, reconciles on config change.
- **Jido integration**: `Synapse.PlanCompiler` turns Jido Plan DAGs into workflow specs; `PlanRunner.run/2` for one-shot compile+execute.
- **LLM layer**: Altar.AI (preferred) or deprecated `Synapse.ReqLLM` (OpenAI/Gemini via env keys).
- **Observability**: LineageIR trace/span/artifact events, RunIndex run/step lifecycle, NSAI Work job events — all via pluggable adapters.
- Deps: jido, req, ecto/ecto_sql, postgrex, telemetry, optional altar_ai.

## What samen could adopt

Very little — samen already has stronger, governed equivalents, and Synapse's foundations conflict with samen's invariants. Candidates, honestly graded:

1. **Schema-validated signal topics (pattern only)** — *What*: each pub/sub topic carries a declared payload schema, validated at publish time, defined in config or at runtime. *Why it fits*: samen's automation `EventCapture` and webhook/notification fan-out could tighten payload contracts with per-event schemas that also feed the machine-readable catalog (catalog-parity verifier could check event payloads the way it checks resources). *Effort*: M (design + a `samen.verify.*` tier), but marginal value since Ash types + the catalog already cover most of this.

2. **Config-reconciled agent registry (pattern only)** — *What*: declarative agent roster in a data file; runtime diffs desired vs running, spawns/kills/monitors to converge. *Why it fits*: samen's ADR-047 agent loop defines agents in code/generators; a reconcile-on-config-change loop could be a nice operator-plane affordance for enabling/disabling agents per tenant without deploys — akin to samen's fleet-directive "honest degradation" model. *Effort*: M. Low urgency; feature flags + approvals already gate agent behavior.

3. **Structured failure envelope from workflow runs** — *What*: `{:error, %{failed_step, error, attempts, audit_trail}}` as a uniform contract. *Why it fits*: samen's `Automation.RunRecord` has a bounded-outcome allowlist; carrying `failed_step`/`attempts` uniformly in run records (if not already) is a small ergonomic win for the operator cockpit. *Effort*: S.

## What to ignore and why

- **The framework itself / Jido foundation**: samen already evaluated and rejected Jido (`_orch/jido-eval-report.md`, ADR-037 posture); Synapse is built on Jido.Plan, so adopting it re-imports a rejected dependency. Its deps (jido, req, altar_ai) would violate INV-4 (zero vendor/HTTP deps in core).
- **Workflow engine**: samen's ADR-039 automation engine (Action registry → Compile → Reactor with per-step compensation, AshStateMachine runs, health/breaker, same-transaction Oban enqueue) is strictly deeper — Synapse has retries but no compensation/saga semantics visible, no approvals gating, no breaker.
- **LLM integration (Altar.AI/ReqLLM)**: raw-prompt, env-key, multi-provider calls with no masking concept — structurally incompatible with samen's chokepoint-minted `%MaskedPayload{}` / no-PII-egress design (ADR-043). Its own ReqLLM path is already deprecated.
- **Per-step before/after snapshots in `workflow_executions`**: in samen this would be a PII hazard (plaintext state snapshots at rest) unless routed through the vault/masking chokepoint; samen's token-only hash-chained audit is the right primitive. Do not import this pattern.
- **Persistence/audit layer generally**: append-only-ish tables without hash chaining, WORM anchoring, or crypto-shred compatibility — samen's audit chain (ADR-002) supersedes it.
- **Maturity**: v0.1.1, single-maintainer, deprecations already in flight; nothing here is battle-tested enough to trade against samen's verified first-party code.
