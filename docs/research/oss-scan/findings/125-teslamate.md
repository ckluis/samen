---
project: TeslaMate
url: https://github.com/teslamate-org/teslamate
category: Media and Personal
relevance: low
verdict: A well-built single-user Elixir/Phoenix car-telemetry logger — real Elixir craft, but wrong domain (no multi-tenancy, no PII vault, no Ash) for a SaaS foundry to learn architecture from.
---

## What the project is

TeslaMate is a self-hosted data logger and dashboard for Tesla vehicles (AGPL-3.0, ~8.9k GitHub stars, actively maintained, 3,130+ commits). It polls a single owner's Tesla account, records drives/charges/telemetry into PostgreSQL, publishes live state over MQTT (for Home Assistant / Node-RED / Telegram integration), and ships 20+ pre-built Grafana dashboards for visualization. Stack: Elixir + Phoenix LiveView (UI), PostgreSQL (storage), MQTT broker, Grafana (analytics), Docker Compose (deployment target, including Raspberry Pi). It supports multiple vehicles per account but is fundamentally a **single-user, self-hosted personal appliance** — not a multi-tenant service, has no accounts/orgs model, no billing, no PII-governance concerns beyond "it's your own data on your own box."

This is an unrelated domain relative to samen: samen is a multi-tenant SaaS foundry whose entire value proposition is PII vaulting/masking, two-plane (tenant/operator) architecture, crypto-shred erasure, and generative app scaffolding for many products serving many customers. TeslaMate solves none of those problems because it doesn't have the problem — one operator, one vehicle owner, one Postgres instance, no cross-tenant isolation, no reveal-grant workflow, nothing to mask.

## What samen could adopt

- **Grafana-as-code dashboard packaging** — TeslaMate ships ~20 pre-built Grafana dashboard JSON files versioned in-repo and provisioned automatically via Docker Compose. Why it fits: samen's `docs/gate-*.md` / observability story could borrow the pattern of shipping a small library of pre-built, versioned Grafana dashboards (per-scope: billing, jobs/Oban, audit-chain health) rather than leaving dashboard-building as an operator TODO. Effort: S.
- **Docker Compose self-host bundle for local eval** — TeslaMate's one-command `docker-compose up` (app + Postgres + Grafana + MQTT wired together) is a clean reference for a "run the whole thing locally in one command" onboarding path. Samen already has `mix samen.gen.app` as its generative proof; a docker-compose wrapper around a generated app + Grafana panel could shorten the eval loop for external builders (ties to the G22 agent-grounding-for-builders gap). Effort: S.

Both are minor, cosmetic-tier borrows — nothing here touches samen's actual hard problems (vault chokepoints, reveal grants, token-blind aggregates, Ash resource modeling).

## What to ignore and why

- **Everything about its domain model** (vehicles, drives, charge sessions, geo-fencing) — irrelevant to a generic SaaS foundry.
- **Its data/auth model entirely** — single Tesla-account credential, no orgs/tenants/roles/RBAC, no PII vaulting or masking of any kind (it stores raw location/VIN data by design, since it's the owner's own data). This is the opposite of samen's PII-by-default-masked posture and offers no pattern to reuse, only a contrast case.
- **MQTT/Home-Assistant integration layer** — a home-automation integration surface with no analog in a B2B SaaS foundry's product surfaces (billing, CRM, support, fleet cockpit).
- **Phoenix LiveView usage itself** — samen already uses Phoenix LiveView more sophisticatedly (two-plane masked rendering, chokepoint-aware components); TeslaMate's LiveView usage is a conventional dashboard app with nothing novel to extract.
- **No Ash, no Oban-as-durable-workflow-engine, no Reactor, no OTP-supervision-tree novelty** worth studying — it's a straightforward Phoenix contexts app, not an architecture reference.
