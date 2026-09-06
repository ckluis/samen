---
project: Atlas
url: https://github.com/dawarich-app/atlas
category: Media and Personal
relevance: low
verdict: A well-built self-hosted Elixir/Phoenix offline-maps stack, but single-tenant, Ash-free, and domain-unrelated to a multi-tenant PII-governed SaaS foundry — a couple of small ops ideas worth noting, nothing architecturally load-bearing.
---

## What the project is

Atlas (dawarich-app/atlas) is a **local-first, self-hostable maps stack** built on OpenStreetMap data: "designed to run on hardware you control with zero outbound API calls at runtime." It ships as a Docker Compose bundle of services — a Phoenix (Elixir) app for UI/admin/APIs/control-plane, Caddy as reverse proxy, and a cluster of geo services (Nominatim for search, Valhalla for routing, Overpass for POIs, OpenTripPlanner for transit, Protomaps/MapLibre for tiles). Data store is SQLite by default with optional external Postgres. A legacy Rails implementation is retained solely as a golden-reference for parity tests (`mix test --include parity`). Deployment is `git clone && docker compose up -d`; it auto-generates and persists a `SECRET_KEY_BASE` on first boot, and exposes uid:gid (`PUID`/`PGID`) knobs for NAS/shared-storage self-hosting. The admin Settings panel does region selection, per-service toggles, basemap config, and shows a "Control plane degraded" banner when the Docker control plane (formerly a separate Go sidecar, now absorbed into Phoenix) can't reach the host daemon. It appears actively maintained (155 stars, 201 commits, live CI with Credo).

It is a personal/self-hosted single-user or single-household tool — no multi-tenancy, no Ash framework, no PII vaulting/masking concerns, and no SaaS billing/identity surface. The domain (offline map serving) has essentially no overlap with samen's domain (a multi-tenant SaaS foundry with vault chokepoints, reveal grants, and generative app scaffolding).

## What samen could adopt

- **Auto-generated, file-persisted `SECRET_KEY_BASE` on first boot** — what: skip requiring an `.env` secret before first boot; generate it and persist to a local file, only override via env var later. Why it fits samen: samen's `mix samen.gen.app` already emits a runnable app with zero hand-edits; a zero-config local-boot convenience for generated apps (dev/demo mode only, never prod per ADR-045's fail-secure `:auth_required?`) shaves friction off the "generative proof" onboarding moment. Effort: S.
- **Explicit "degraded, not fake" status banner in the admin UI** — what: a visible operator-facing banner that surfaces "control plane unreachable" rather than silently no-op'ing. Why it fits samen: this is the same spirit as samen's fail-honest adapters (INV) and Fleet cockpit's "honest degradation," but Atlas's is a concrete, small, user-facing UI widget pattern (banner + live ingest progress) samen's operator plane could borrow verbatim for surfacing adapter/webhook/queue health instead of only logging it. Effort: S.
- **Golden-reference parity testing against a prior implementation** — what: keep an old/reference implementation solely to run `mix test --include parity` against, proving a rewrite matches known-good behavior. Why it fits samen: conceptually adjacent to samen's sabotage/generative-proof discipline, and could inform a lightweight "before/after" parity check when a workstream rewrites a generated-app code path (e.g. WS-C remnants), though samen's sabotage harness is already far more rigorous. Effort: M (would need a maintained reference fixture, likely not worth it given existing verification depth).

## What to ignore and why

- **Geo service stack (Nominatim, Valhalla, Overpass, OpenTripPlanner, Protomaps/MapLibre)** — entirely domain-specific to maps; no transfer to a SaaS foundry.
- **Single-tenant / self-hosted deployment model (uid:gid ownership, Docker-socket-mounted control plane, SQLite-by-default)** — the opposite of samen's cloud multi-tenant, Fly-deploy, Postgres-only posture; adopting it would regress samen's architecture.
- **No Ash usage** — Atlas is plain Phoenix/Ecto (implied), so there's nothing to compare against samen's Ash-ecosystem adopt/reject decisions (ADR-037).
- **No PII/vault/masking/reveal-grant concept at all** — Atlas has no multi-party trust boundary to speak of (single operator, own hardware), so it offers zero precedent for samen's core differentiator (vault chokepoints, token-blind aggregates, crypto-shred).
- **Former Go `atlas-control` sidecar absorbed into Phoenix** — a migration detail specific to Atlas's own history, not a pattern samen needs (samen has no comparable sidecar-to-Phoenix migration in flight).
