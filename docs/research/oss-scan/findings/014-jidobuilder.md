---
project: JidoBuilder
url: https://github.com/TMDLRG/JidoBuilder
category: Agent Platforms With License Warnings
relevance: low
verdict: Non-commercial-licensed UI console for a framework (Jido) samen already formally rejected; nothing adoptable as code, at most faint UX inspiration for an agent-ops console samen mostly already has.
---

# 014 — JidoBuilder

## What the project is

JidoBuilder is a visual management console for building, configuring, deploying, and monitoring autonomous agents built on the **Jido** Elixir agent framework. It is an Elixir umbrella of four OTP apps (core: Ecto + **SQLite** persistence; runtime: agent lifecycle + LLM clients; web: Phoenix LiveView UI with PubSub; codegen), all on a single BEAM node. Features: agent roster (hire/stop/search), state inspection, chat interfaces, multi-provider LLM support (Anthropic/OpenAI/Mock) with a tool-use loop over 75+ Jido actions, agent templates/plugins/directive builder (11 directive types), signal trace logs, audit history, live metrics dashboards, multi-tenant workspaces, a "vault" for agent snapshots, circuit-breaker error policies, and a plugin marketplace. Elixir 1.18+/OTP 27+, Tailwind. ~571 commits, 320 tests, AI-assisted authorship ("ORCHESTRATE Method"), **zero stars/forks** — no visible adoption. License: **PolyForm-Noncommercial-1.0.0** (not OSI-approved; commercial use requires a separate license), while the underlying Jido framework remains Apache-2.0.

## Why relevance is low for samen

1. **Samen already evaluated and rejected Jido itself** (`/Users/clank/Desktop/projects/samen/_orch/jido-eval-report.md`, 2026-08-13, verdict DON'T ADOPT; reaffirmed by ADR-037/ADR-047). Samen's agent loop is first-party, zero-new-deps, built on Reactor/AshStateMachine/Oban with the EG2 governed-egress class. A console *for Jido agents* manages an abstraction samen deliberately does not use.
2. **License is disqualifying for code reuse.** PolyForm-Noncommercial forbids the commercial use samen exists for (MIT SaaS foundry). Even pattern-lifting must stay at the idea level, never vendored code.
3. **Architecture contradicts samen invariants.** SQLite persistence, single-node, LLM clients invoked without any masking chokepoint concept, no PII governance, no approval gating on agent side effects — the exact failure modes samen's AI plane (ADR-043/047: token-blind MaskedPayload minting, AI-writes-do-not-exist, E3 approvals) is built to make structurally impossible.
4. **No adoption signal.** Zero stars/forks despite 571 commits; single-author; 23 open PRs against itself.

## What samen could adopt

Nothing as code. Two idea-level notes, both already substantially covered:

- **Agent-ops console surface checklist** (roster + per-agent state inspector + signal/trace log + live metrics + per-agent debug toggle in one operator screen). *Why it fits:* samen's ADR-047 agent loop shipped with transcripts/budgets but the operator-plane UI for observing agent runs could crib this feature inventory when that surface deepens (fits the "operator cockpit v2" roadmap theme). *Effort:* M — pure samen_web operator-plane work over existing RunRecord/transcript data; no dependency.
- **Circuit-breaker error policies per agent template.** *Why it fits:* samen already has `Automation.Health`/`Automation.Breaker` (ADR-039); the only nuance worth noting is JidoBuilder's per-template policy configuration granularity. *Effort:* S if ever wanted — a policy field on agent definitions feeding the existing breaker.

## What to ignore and why

- **The entire Jido dependency surface** (agents/signals/directives/plugins, jido_ai, req_llm): already adjudicated DON'T ADOPT with a written eval; adopting its console would reopen a closed decision for no gain.
- **All source code:** PolyForm-Noncommercial makes it unusable in an MIT commercial substrate.
- **SQLite/single-node persistence model:** incompatible with samen's Postgres-only, multi-tier verified architecture.
- **"Vault" (agent snapshots) and "multi-tenant workspaces":** name collisions only — no relation to samen's PII vault or two-plane org model; shallower on every axis.
- **LLM provider layer:** raw-string provider calls with no egress governance; samen's chokepoint-minted `%MaskedPayload{}` design is strictly stronger.

## Evaluation notes

Single-pass evaluation (low-relevance calibration): README/repo fetched 2026-08-19; cross-checked against `/Users/clank/Desktop/projects/samen/_orch/jido-eval-report.md` and the samen digest.
