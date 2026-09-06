---
project: Midarr
url: https://github.com/midarrlabs/midarr-server
category: Media and Personal
relevance: low
verdict: Well-built single-household Phoenix media server with no tenancy, auth-vault, or billing concerns — only a handful of small library/pattern ideas transfer.
---

# What the project is

Midarr is a self-hosted, lightweight "companion" media server (v5.0.0, MIT, ~1,400 stars, actively maintained — 1,991 commits, last push 2026-03) written in **plain Elixir/Phoenix** (Elixir ~>1.17, Phoenix ~1.8, Phoenix LiveView ~1.0) with **no Ash framework** anywhere in the stack. It deliberately does not re-index media itself: it sits in front of existing Radarr/Sonarr libraries and serves a polished web UI (real-time online-status via `Phoenix.Presence` + a `room_channel`, user auth/profile via a conventional `phx.gen.auth`-shaped `Accounts` context with `User`/`UserToken`/`UserNotifier`, an invite-based onboarding flow, and OIDC/OAuth 2.0 support for identity providers like Authentik via the `oauth2` package). Its "lightweight" pitch rests on three ideas: direct streaming (no re-encoding/re-indexing), smart caching (webhook-driven sync from Radarr/Sonarr keeps a local cache current), and leaving the underlying libraries untouched. Key deps: `phoenix_live_view`, `oban` (background jobs, e.g. sync workers), `swoosh` (mail), `flop` (Ecto-backed pagination/filtering/sorting), `oapi_tmdb` (generated TMDB API client), `gettext`, `bcrypt_elixir`, `plug_cowboy`. This is a **single-tenant, single-household app** — there is no org/tenant model, no RBAC beyond basic user accounts, no PII vaulting, no billing, and no audit trail; it is architecturally a fairly conventional, well-executed personal Phoenix app, not a SaaS substrate.

# What samen could adopt

- **`gettext` wired end-to-end in a live Phoenix/LiveView app.** Samen's gap register carries G24 (i18n/timezone/currency: USD+UTC hardcoded, no gettext) as an open P2/P3 item. Midarr is a concrete, current reference for wiring `gettext` cleanly through `media_server_web/gettext.ex`, templates, and LiveViews on the exact Phoenix/LiveView versions samen targets — useful as an implementation pattern when G24 is picked up, not as a dependency to import. Effort: S (reference only).
- **`Flop` as a prior-art comparison for list/sort/filter UX, not for adoption.** Samen deliberately hand-built its own keyset-pagination "reads" contract (masking- and catalog-aware). Worth a quick side-by-side read of Flop's Ecto-query-building API for UX ideas (URL-encoded filter/sort state, per-field operators) that could inform the `reads` module's ergonomics, without pulling in the dependency itself (it isn't catalog- or PII-aware). Effort: S.
- **Simple invite-link onboarding flow as a UX reference.** Samen's identity spine already has team invites (ADR-035); Midarr's "simple and easy invite system" is a minimal, polished take on the same problem in the same framework version and could be skimmed for onboarding-copy/flow ideas. Effort: S.

# What to ignore and why

- **The entire product shape and domain**: a single-household media companion to Radarr/Sonarr has zero surface overlap with a multi-tenant SaaS foundry — no orgs, no tenants, no billing, no PII, no operator plane.
- **Its auth model**: conventional `phx.gen.auth`-style token auth with `bcrypt_elixir` and no vaulting/masking/audit — strictly weaker than samen's identity spine (ADR-035) and vault chokepoint; nothing to backport, and adopting any of it would be a regression.
- **Direct-streaming/smart-caching architecture**: solves "serve large media files efficiently from someone else's library," a problem samen's product surfaces don't have (samen's `files` module is a quarantine-by-default upload chokepoint, the opposite design goal).
- **No Ash, no multi-tenancy, no policy/RBAC layer, no audit chain, no crypto-shred, no verifier/sabotage discipline**: none of samen's core moat (vault chokepoints, two-plane masking, hash-chained audit, generative CI proof) has any counterpart here to compare against — this repo simply doesn't operate in that problem space.
- **`oauth2` + Authentik-flavored OIDC integration**: samen already made a considered, ADR-documented choice (`assent`, ADR referenced in digest) for OIDC; Midarr's raw `oauth2` package client is a lower-level, less-opinionated alternative with nothing samen's spine is missing.
