---
project: Hive
url: https://github.com/tuist/hive
category: Software Factories
relevance: medium
verdict: Early-stage but idea-rich Elixir/Phoenix agentic product-dev platform from Tuist — adopt its "flights" durable-agent-execution UX and signal-ingestion patterns as designs, not its code or its NIF-backed agent runtime.
---

# 020 — Hive (tuist/hive)

## What the project is

Hive is Tuist's self-hostable "agentic product-development system": a Phoenix 1.8 / LiveView 1.1 / Postgres / Oban app (MPL-2.0, canonical instance at hive.tuist.dev, docs at docs.hive.tuist.dev) that centralizes product signals, plans, and shipped work, with LLMs continuously maintaining the product taxonomy. Very early stage (~7 stars, ~300 commits, README says "expect APIs, behavior, and deployment details to change often") but built by a credible Elixir team.

Core concepts:
- **Forage** — inbound product signals (requests, feedback, issues, alerts) captured from Slack messages, GitHub issues, and Grafana alerts and converted into items.
- **Specs** — evidence-backed product intent derived from forage items.
- **Domains** — a durable business-domain taxonomy that the LLM keeps aligned as new items/specs arrive (instead of ad-hoc tickets).
- **Drops** — releases/changelogs linked back to the product areas and source signals they improve.
- **Flights** (`lib/hive/flights.ex`) — "durable agent executions that can be inspected and continued after their original sandbox has stopped": typed objectives (investigate/reproduce/fix), typed outcomes (investigated/reproduced/fixed/inconclusive...), statuses (queued/running/succeeded/failed), started from manual items, GitHub issues, or Grafana alerts, listed/filtered per-user with policy checks.
- **Inference** (`lib/hive/inference.ex`) — a built-in LLM gateway: relays chat/embedding requests to OpenAI-compatible upstreams via `ModelBinding` (provider from DB or env), Req-based, SSE streaming passthrough, token auth with role/expiry checks, and **billable usage metering** on 2xx responses with per-model pricing maps.
- **Agent runtime** — `Hive.Agents.Sessions.run/3` delegates to **Condukt** (tuist/condukt), Tuist's separate Elixir agent framework: agent loop + declarative workflows, sandboxes (in-memory, microVM, or per-session Kubernetes pod), per-session network allow/deny policies, secret redaction from transcripts, OTP supervision/streaming/cancellation — with Rust NIFs (bashkit, microsandbox, egress control).
- Also: MCP support (`emcp`), OAuth2/OIDC provider (`boruta`), `ueberauth` login, `let_me` authz, `flop` pagination, `mdex` markdown, `noora` UI kit, Swoosh mail, Sentry.

## What samen could adopt

1. **"Flights" as a first-class operator-plane surface for agent runs** — durable, inspectable, resumable executions with a typed objective/outcome vocabulary and list/filter/inspect UI, launchable from a domain object (ticket, alert, item). *Why it fits:* samen's ADR-047 agent loop already persists transcripts and budgets; what it lacks is exactly this product surface — a fleet/operator cockpit view of agent runs with bounded-outcome semantics (which rhymes with samen's existing RunRecord bounded-outcome allowlist in the automation engine). *Effort: M* (UI + read models over existing agent-loop records; no new kernel mechanism).

2. **Signal ingestion: Slack-message → item and alert → agent-run triggers.** Hive's flow of converting Slack threads and Grafana alerts into structured work items, then optionally launching an agent flight against them, is a concrete design for samen's open **G23 (product feedback → roadmap, currently absent)** and a support-desk enrichment. *Why it fits:* samen already has support/mailbox/notifications scopes and fail-honest vendor adapter discipline — a `samen_slack` adapter package (req lives in the adapter, never core, per INV-4) slots straight into the existing pattern. *Effort: M* for Slack ingestion; *L* if extended to alert-triggered agent investigations.

3. **Usage metering on the AI egress path.** Hive's Inference gateway counts billable usage per model binding with pricing maps at the relay chokepoint. Samen already has the single AI egress chokepoint and budgets/cost caps (ADR-047) — adding per-tenant/per-model usage rating there feeds the open **G13 usage-rating gap** with real numbers. Adopt the metering/pricing-map idea only, not the gateway (see below). *Effort: S–M* (instrument the existing chokepoint; rating rollups already have a home in revenue/rollup).

4. **LLM-maintained taxonomy ("domains").** Having the AI plane continuously reconcile inbound signals against a durable domain taxonomy is a good pattern for samen's AI-drafts-only posture: the AI proposes reclassifications; the E3 approvals engine gates application. *Effort: M*, and only once G23 ingestion exists.

5. **Watch, don't adopt: Condukt.** It is the most serious open-source Elixir agent-runtime alternative to samen's hand-built loop (the same evaluation samen ran on Jido and ash_ai). Its microVM/K8s per-session sandboxing and per-session network egress policies are the interesting ideas if samen agents ever execute code. Today it fails samen's gates: Rust NIFs and vendor deps can't enter samen_core (INV-4, no-NIF posture), it has no masked-payload chokepoint concept, and samen's "AI writes do not exist" model removes most of the need for sandboxed tool execution. Worth a periodic re-check as it matures. *Effort if ever adopted: L, via an adapter package only.*

## What to ignore and why

- **The transparent LLM relay/gateway architecture.** Hive forwards request bodies verbatim to OpenAI-compatible upstreams. That is the exact opposite of samen's token-blind chokepoint (providers accept only chokepoint-minted `%MaskedPayload{}`); adopting a passthrough proxy would structurally reintroduce the PII-egress risk samen exists to eliminate.
- **The overall product.** Hive is a product-management application; samen is a foundry. There is no reusable substrate to vendor — value is in the patterns above, and MPL-2.0 plus pre-1.0 churn make code-lifting unattractive anyway.
- **Library swaps:** `let_me` (samen has Ash policies + SAT solver), `flop` (samen has its keyset-pagination reads contract), `emcp` (samen has a first-party MCP server, HTTP+SSE), `boruta` (samen consumes OIDC via assent and has no need to be an IdP), `noora`/`mdex` (samen has its own UI kit; mdex only worth a look if AI-draft markdown rendering ever needs hardening).
- **Maturity signals as evidence:** 7 stars, 1 open issue, self-described WIP — treat everything here as design inspiration from a good team, not proven practice.
