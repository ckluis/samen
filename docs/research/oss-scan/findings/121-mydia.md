---
project: Mydia
url: https://github.com/getmydia/mydia
category: Media and Personal
relevance: low
verdict: "Active, well-built Elixir/Phoenix LiveView self-hosted media manager (781 stars) with a couple of nice DX/tooling habits, but single-tenant personal-use domain with no Ash, no multi-tenancy, and no PII-governance concerns — nothing core to mine, at most two small tooling ideas."
---

# 121 — Mydia

## What the project is

Mydia is a **self-hosted personal media library manager** (AGPL-3.0, Elixir/Phoenix LiveView, 781 stars, actively developed, not archived) — the same product category as Sonarr/Radarr/Overseerr: it tracks movies and TV shows, pulls metadata from TMDB/TVDB, automates downloads via quality profiles against download clients (qBittorrent, Transmission, SABnzbd, debrid providers) and indexers (Prowlarr, Jackett, a built-in Cardigann-compatible WASM plugin runtime), and serves a real-time LiveView dashboard plus calendar/request workflow. It supports multi-user admin/guest roles with request workflows and OIDC/SSO (via `ueberauth_oidcc`) on top of local auth (Guardian + bcrypt/argon2). It also ships a companion cross-platform "Mydia Player" app (Android/iOS/macOS/Windows/Linux/web) that streams the library over an encrypted P2P connection, no port forwarding needed.

Stack: plain Phoenix 1.8 + LiveView 1.2 + Ecto (dual Postgres/SQLite support) — **no Ash anywhere**. Notable dependencies: Oban + crontab for scheduling, `wasmex` (wasmtime via Rustler NIF) for a sandboxed WASM indexer-plugin runtime, `finch`/`req` for HTTP, `websockex` for a Flutter dev-server proxy backing the Player app. Docs are a full Diataxis-style MkDocs site (tutorials/how-to/reference/explanation) at docs.mydia.dev. Dev loop uses a `./dev` wrapper script and `mix precommit`.

The domain (single-tenant, self-hosted, one household's media library) is fundamentally different from samen's target (multi-tenant B2B SaaS with PII vaulting, org-scoped policy, crypto-shred, operator/tenant two-plane governance). There is no tenancy model here beyond an admin/guest role split, no PII-handling story, and no verification/sabotage discipline comparable to samen's.

## What samen could adopt

1. **Predicate-based dead-code ignore rules over `mix_unused`** — Mydia gates a `:unused` compiler pass behind `UNUSED_CHECK=true` (kept off the hot path) and expresses every exclusion as a *rule* (regex-on-module + arity match, or a `behaviour_callback?/1` predicate that walks `@behaviour` attributes at runtime rather than hand-listing every Guardian/Plug/OTP callback). Their own comment states the discipline explicitly: "a rule auto-covers future code; a finding-list is grandfathering." Why it fits samen: this is the same "encode knowledge as infra" instinct samen already applies to verifier tiers, and samen's growing kernel (100+ modules, many behaviour-based: `Samen.AI.Provider`, `Samen.Kms`, adapter behaviours) has the identical static-analysis-blind-spot problem for dead-code tooling. Effort: **S** (a `mix_unused` (or `:sobelow`-style) integration plus one `behaviour_callback?/1`-shaped predicate module, opt-in via env var to avoid slowing default CI).

2. **WASM-sandboxed plugin runtime for third-party extension points (`wasmex`)** — Mydia runs experimental Cardigann-compatible indexer definitions inside a pooled `wasmex`/wasmtime sandbox (`nimble_pool` for instance reuse) rather than shelling out or eval'ing arbitrary Elixir. Why it fits samen: if the agent-grounding/MCP differentiator (G22, "packaging for external builders") ever needs to let a tenant or third party supply custom transform/enrichment logic without granting it BEAM-level trust, a WASM sandbox is a proven, dependency-light pattern that composes with samen's chokepoint philosophy (untrusted code, trusted boundary) — closer in spirit to a governed extension point than a general code-exec tool. Effort: **L** (new dependency class, sandboxing story, and a use case that doesn't exist yet — park as an ADR seam note, not near-term work).

## What to ignore and why

- **Everything domain-specific** (movies/TV metadata, download clients, indexers, quality profiles, calendar) — no overlap with a SaaS foundry's surface area.
- **No Ash usage at all** — plain Ecto/Phoenix, so none of the resource/policy/type patterns samen has already standardized on (Ash.Resource, Ash policies, ash_archival, ash_paper_trail) have an analog here to compare against.
- **Guardian + ueberauth for auth** — samen already has a more complete identity spine (ADR-035: registration, OIDC via `assent`, TOTP via `nimble_totp`, session management, audited password resets) that is purpose-built for the two-plane multi-tenant model; Mydia's simpler admin/guest auth has nothing samen's spine is missing.
- **Dual Postgres/SQLite support** — directly contrary to samen's deliberate Postgres-only purity (crypto-shred, pgvector, hash-chained audit triggers, CHECK constraints all assume Postgres).
- **Mydia Player P2P streaming app** — a consumer end-user product distribution model (native apps, TestFlight, notarized macOS builds, Flatpak) that has no bearing on samen's in-monorepo, no-Hex-packages distribution stance (ADR-033).
- **Taking code directly** — different domain, different framework posture (no Ash), and AGPL-3.0 licensing would be a poor fit to pull code from into an MIT monorepo; at most the two patterns above are worth reading, not vendoring.
