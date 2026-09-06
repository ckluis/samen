---
project: Myconet
url: https://codeberg.org/myconet/myconet
category: Communication and Social
relevance: low
verdict: Hobby-scale Elixir/Phoenix ActivityPub server with a stock dependency set and unrelated domain — nothing samen needs to adopt.
---

# 075 — Myconet

## What the project is

Myconet is a small, actively-developed (last commit Nov 2025, ~316 commits, 0 stars / 1 fork) federated social network server on Codeberg, written in Elixir/Phoenix (~92% Elixir), licensed EUPL-1.2. Its pitch is user-owned data via self-hosting on the Fediverse: ActivityPub federation, multi-account/multi-user separation on one instance (context isolation per local account), follow/unfollow + follow-request management, configurable open/closed/invite registration, and a server-side-rendered frontend with "very little to no JavaScript". Deployment is a Dockerfile plus a Nix dev shell.

Its dependency set is essentially the stock `mix phx.new` output (Phoenix 1.7, LiveView 1.0, Ecto/Postgrex, Bandit, Swoosh, Oban 2.19, Req/Finch, gettext) plus the minimal ActivityPub additions: `http_signatures` (HTTP Signature verification for federation), `flake_id` (distributed IDs), `html_sanitize_ex`/`floki` (sanitizing remote HTML), `argon2_elixir`. No Ash, no policy layer, no multi-tenancy in the SaaS sense, no notable OTP architecture beyond Phoenix defaults.

## What samen could adopt

Nothing rises to adoption. Evaluated candidates, all declined or noted-only:

- **ActivityPub federation / `http_signatures`** — samen has no federation surface or roadmap item; ActivityPub is orthogonal to a SaaS foundry's tenant/operator planes. Not applicable (effort would be L for zero demand).
- **SSR no-JS frontend posture** — samen already has its own function-component UI kit and LiveView surfaces; Myconet's approach is just standard Phoenix templates, nothing novel to lift. Skip.
- **`gettext` usage** — samen's G24 gap (i18n) is open, but Myconet's gettext use is the default generator wiring, not a pattern worth studying; the canonical gettext docs are a better reference. Skip.
- **Multi-account context isolation** — conceptually adjacent to samen's org-scoping, but samen's `OrgScope` + policy SAT layer is far deeper; nothing to learn here. Skip.

## What to ignore and why

- The entire federation/social domain: unrelated to SaaS substrate concerns (PII vaulting, masking, billing, operator plane).
- Its architecture: plain Ecto schemas + Phoenix contexts with no policy/authorization framework, no audit, no verification discipline — below samen's bar on every axis samen cares about.
- Maturity signals: 0 stars, 1 fork, single-digit contributor activity; not a source of battle-tested patterns.
