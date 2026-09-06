---
project: ExTracker
url: https://github.com/Dahrkael/ExTracker
category: Infrastructure and Operations
relevance: low
verdict: A single-purpose, in-memory BitTorrent tracker (no Phoenix/Ash/Ecto, no PII, no multi-tenancy) — almost nothing overlaps with samen's SaaS-foundry concerns beyond generic Elixir ops hygiene.
---

## What the project is

ExTracker is a work-in-progress BitTorrent tracker written in Elixir (341 stars, Apache-2.0, actively pushed as of 2026-03). It implements the BitTorrent tracker protocol BEPs (UDP tracker protocol, compact peer lists, IPv6, scrape, protocol v2, etc.) over `plug_cowboy`, storing all peer/swarm state **in-memory** (no database — "Database backups to disk" is a periodic dump, not a persistence layer). Its stated goals are raw performance and zero-setup ops: "uses ALL available cores," ~200MB RAM per 1M peers, `MIX_ENV=prod mix release` + Docker image, and environment-variable-driven `config/runtime.exs` for container configuration.

Dependencies confirm the scope: `plug_cowboy` (HTTP/UDP-ish serving), `bento` (bencoding, BitTorrent's wire format), `locus` (GeoIP), `telemetry` / `telemetry_metrics_prometheus_core` (Prometheus metrics export), `tesla` + `mint` (HTTP client for integrations). No Phoenix, no Ash, no Ecto/Postgres, no auth/identity system, no PII of any kind (peer state is IP + port + infohash, ephemeral and unmasked by design), no multi-tenancy concept.

This is an unrelated-domain, single-service infra tool — not a web app framework, not SaaS, not privacy-governed.

## What samen could adopt

- **Env-var-driven `runtime.exs` for Docker configuration**: ExTracker documents an explicit "config via environment variables because editing `runtime.exs` inside a container is awkward" convention, with a full example `docker-compose.yml` enumerating every configurable env var. Why it fits samen: samen already uses `mix release` deploys and Fly.io is a stated target; a documented, exhaustive env-var reference table alongside the compose/deploy config is a cheap docs/ops polish samen's `docs/` could crib for its own deploy guide. Effort: S.
- **`telemetry_metrics_prometheus_core` for zero-Grafana-dependency metrics export**: a lightweight way to expose Prometheus-scrapeable metrics straight from `:telemetry` events without extra infra. Samen already has `telemetry_metrics` + OpenTelemetry wired (with `db_statement` disabled to keep PII tokens out of spans); if samen wants a simpler local/self-hosted metrics path for the fleet cockpit or operator plane (independent of a full OTel collector), this library is a proven, minimal option. Effort: S.

Both are minor, generic-Elixir-ops takeaways, not architectural ones — nothing here touches samen's actual differentiators (PII vaulting, masking, Ash resources, multi-tenancy, reveal grants, audit chains).

## What to ignore and why

- **The tracker protocol/domain logic itself** (BEP implementations, bencoding, UDP protocol handling, in-memory swarm/peer ETS storage) — entirely irrelevant; samen is a multi-tenant web SaaS substrate, not a P2P protocol server, and has no use for BitTorrent semantics.
- **In-memory-only storage model** — the opposite of samen's Postgres/Ash-resource, vault-chokepoint, audit-chained persistence model; adopting it would regress every one of samen's PII/erasure/audit guarantees.
- **GeoIP (`locus`) and swarm-scale performance tuning** — solves a problem samen doesn't have (samen's multi-tenant CRUD workloads aren't peer-swarm-scale nor latency-critical UDP).
- **No Phoenix/Ash/Ecto usage at all** — there is no web-framework, ORM, or authz pattern here to compare against samen_web/samen_core; nothing to port at the architecture level.
