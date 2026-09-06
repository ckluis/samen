---
project: Soundbored
url: https://github.com/christomitov/soundbored
category: Communication and Social With License Warnings
relevance: low
verdict: Actively-maintained Elixir/Phoenix/LiveView Discord soundboard — same stack as samen but a single-tenant hobby app with no multi-tenancy, PII vaulting, billing, or audit story to adopt.
---

## What the project is

Soundbored is a self-hosted, unlimited Discord soundboard: a Phoenix + LiveView web app that lets users upload or URL-link audio clips and trigger them into a Discord voice channel via a bot, with three join modes (auto-on-play, presence-following, manual), tag-based filtering, and a stats dashboard. It integrates with Discord using EDA (Elixir Discord API, with DAVE voice-encryption support). Storage is SQLite on a mounted volume; deployment is Docker (plain host or Coolify) with explicit volume-mount guidance for uploads + DB persistence. Auth is Discord OAuth2 for browser login, optional HTTP Basic Auth as an extra UI gate, and DB-backed personal API tokens (`Authorization: Bearer`) for the REST API, attributed per-user for stats. Any signed-in user can edit shared sound metadata; only the uploader can delete. It's actively maintained (v1.7.0, 2026-03-07; ~96% Coveralls coverage, Credo lint, CI). **No LICENSE file is present in the repo** (confirmed via direct fetch — 404), matching the manifest's "License Warnings" flag.

It is a single-tenant, single-instance hobby/utility tool — one shared pool of sounds and users per deployment, no orgs, no tenant isolation, no billing, no PII handling beyond a Discord identity, no audit trail, no masking. It shares samen's language and web framework (Elixir/Phoenix/LiveView) but occupies none of samen's actual problem space (multi-tenant SaaS substrate, PII vault/masking, two-plane architecture, verification discipline).

## What samen could adopt

- **User-scoped API token pattern (bearer tokens, DB-stored, per-user attribution).** What: a simple table of personal API tokens tied to a user, checked via `Authorization: Bearer`, with the token owner attributed on writes for stats/audit. Why it fits samen: this is a miniature, non-PII-flavored version of what samen's identity spine + audit chain already do far more rigorously (session/API auth, hash-chained attribution) — low value as a reference beyond confirming a common, unremarkable Phoenix idiom. Effort: S (not worth a dedicated adoption; samen's existing auth/audit already exceeds it).
- **"Degraded mode" startup pattern.** What: the app boots in a reduced-functionality mode when optional voice capabilities (Discord voice runtime) are unavailable, rather than crash-looping. Why it fits samen: conceptually rhymes with samen's fail-honest adapters (ADR-014/024/026/038) that return `{:error, :not_configured}` instead of faking success — a possible naming/pattern cross-check, not new architecture. Effort: S (already covered, no action needed).
- **Docker/Coolify volume-mount deployment writeup for stateful local storage.** What: explicit documentation of which paths must be declared as named volumes (uploads dir + SQLite DB) so redeploys don't silently lose data, plus a documented `UPGRADING.md` migration note for a past storage-path change. Why it fits samen: samen's own `Storage.Local` adapter and any future self-host/Coolify deploy docs could borrow this "volumes you must declare, and why" phrasing as a template for its own deploy runbook. Effort: S (documentation-only, easy to lift).

Nothing here rises above small documentation/pattern-confirmation value — none of it is a structural or library adoption candidate.

## What to ignore and why

- **The entire domain and feature set** (soundboard, Discord bot/voice integration, EDA library, tag filtering, stats dashboard) — irrelevant to a multi-tenant B2B SaaS foundry; there is no tenant model, billing, PII, or masking concern anywhere in this app.
- **SQLite storage choice** — samen is Postgres-only by design (ADR-001 KMS/vault architecture assumes Postgres); SQLite is a reasonable choice for a single-user self-hosted tool but has no bearing on samen's substrate.
- **Discord OAuth2 flow specifics** — samen already ships assent-based OIDC (Google reference IdP) in its identity spine; a Discord-specific OAuth integration is a narrower, redundant case with nothing new to teach.
- **No-license status** — a governance flag for anyone vendoring code from this repo, not a technical pattern; nothing here should be copied verbatim regardless, given the shallow overlap.
- **Any notion of "go deep"** — the repo's actual engineering (voice command/presence modules, DAVE encryption) is Discord-voice-protocol plumbing with no analog in samen's problem space; deeper study would not surface transferable SaaS-foundry patterns.
