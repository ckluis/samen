---
project: Jido Studio
url: https://github.com/agentjido/jido_studio
category: Agent Frameworks and Development Tools
relevance: low
verdict: Skip as a dependency (hard-coupled to Jido, which samen already rejected); mine only its agent-ops dashboard UX patterns for the operator plane.
---

# 040 — Jido Studio

## What the project is

Jido Studio is an embeddable Phoenix LiveView dashboard (Apache-2.0, Hex `jido_studio`, v0.1.0, ~15 stars / 83 commits — early but shipping) for managing and debugging agents built on the **Jido** agent framework. It mounts into a host Phoenix app via a router macro (`jido_studio "/studio"`), with no asset-pipeline integration required, discovers running agent instances from one or more configured Jido runtimes (`config :jido_studio, jido_instance: MyApp.Jido`), and provides:

- Dashboards: **Home** (fleet health + attention cues), **Agents** (live instance index, follow/unfollow, viewer counts, uptime), **Catalog** (agent/action/sensor/plugin registry), **Activity** (plain-language operational timeline), **Diagnostics** (traces, actions, workflows, signals).
- Dual interaction surface: chat-first UX plus a non-chat "interaction workbench"; **guarded runner** requiring explicit arm-before-run for executions; thread persistence via Jido.Storage adapters.
- Observability: additive telemetry under `[:jido_studio, ...]`, trace/span timeline visualization with internal-span filtering, pluggable trace persistence (ETS default, optional Postgres/Ecto), event-driven updates with polling fallback, eval-history tracking, a "time-to-triage" benchmark CLI task.
- Access control via a `Resolver` behaviour (admin/dev/read-only), built-in Presence for viewer tracking.

## What samen could adopt

Nothing as code — everything below is pattern inspiration for samen's own first-party surfaces. Samen's agent loop (ADR-047) is hand-built precisely because Jido was evaluated and rejected (`_orch/jido-eval-report.md`: ten production deps, no chokepoint concept, INV-4/INV-7 conflicts); Studio inherits that entire dependency and coupling problem.

1. **Agent-ops "Diagnostics" view in the operator plane** — what: a per-agent-run trace/span timeline (turns, tool calls, provider calls, budget consumption) with internal-span filtering, rendered from samen's existing wide events/observability data. Why it fits: ADR-047 already persists transcripts, budgets, and tool-use records but the operator cockpit has no dedicated agent-run drill-down; this is exactly the "time-to-triage" surface an operator debugging a misbehaving agent needs, and it composes with masked-by-default rendering (transcript segments are already governed EG2 egress). Effort: **M** (LiveView surface over existing data; no new kernel capability).
2. **Guarded runner (arm-before-run) UX** — what: a two-step explicit arm → execute interaction for firing an agent/automation from an admin surface, instead of a single click. Why it fits: samen's E3 approvals engine governs side effects, but operator-plane "run this agent now" test/replay affordances would benefit from the same deliberate-confirmation ergonomics; cheap complement to requester≠approver. Effort: **S** (UI-kit pattern + one confirm state).
3. **Plain-language Activity timeline** — what: an operational feed that summarizes agent/automation events in human sentences ("Agent X exhausted its budget on run Y") rather than raw event rows. Why it fits: samen has audit chain + notifications + wide events; a narrated fleet-activity feed in the fleet cockpit (ADR-044) would raise operator legibility with data already captured — and Studio's framing ("attention cues", triage baseline) is a good spec vocabulary. Effort: **M**.
4. **Eval-history surface** — what: persist and display red-team/eval tier results over time per agent. Why it fits: samen already runs a permanent AI red-team eval tier (ADR-043 §10, ≥90% bar) in CI; surfacing the trend in the operator plane turns a CI artifact into an operator trust signal. Effort: **S–M** (samen already stores claim-evidence; needs a resource + chart).
5. **Presence/viewer-count on shared operator views** — what: Phoenix.Presence showing who else is watching an agent/tenant view. Why it fits: multi-operator fleets (ADR-044 cross-product operator identity); trivial with LiveView. Effort: **S**. Nice-to-have only.

## What to ignore and why

- **The package itself, and any Jido dependency**: Studio only works against Jido runtimes (`jido_instance` supervisor discovery, Jido.Signal/Action introspection, Jido.Storage thread persistence). Samen rejected Jido for cause — adopting Studio would re-import the framework samen declined, violate INV-4 (vendor-free core; Studio brings the jido dep tree), and its UI cannot render `%Masked{}`/token-blind data correctly.
- **Chat-first agent UX as the primary surface**: samen already has a cross-plane, catalog-driven, masking-aware chat; Studio's chat adds nothing and lacks PII governance.
- **ETS-default trace persistence**: samen's observability posture is Postgres + wide events + OTel (with db_statement disabled for token safety); an ETS trace store is a step backward and unshreddable-by-design concerns don't even arise because it would bypass the audit/erasure envelope.
- **Router-macro embeddability as a pattern to copy**: samen already has the stronger version (`Samen.Web.Mount` / two-plane mountable modules, ADR-009); nothing new here.
- **Its RBAC Resolver behaviour**: samen's policy/RBAC/OrgScope stack is deeper and fail-closed; a per-dashboard resolver would be a parallel, weaker authz path.

## Depth note

Single research pass (repo README/docs via WebFetch) plus verification against samen's prior Jido evaluation. Low relevance was clear early: the project is young (v0.1.0, 15 stars) and structurally inseparable from a framework samen has already adjudicated. The adoptable value is a short list of operator-UX ideas, captured above.
