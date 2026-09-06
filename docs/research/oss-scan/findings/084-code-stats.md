---
project: Code::Stats
url: https://gitlab.com/code-stats/code-stats
category: Developer Tools
relevance: low
verdict: A real, long-running single-tenant Elixir/Phoenix gamification service — solid production hygiene but wrong domain (no Ash, no multi-tenancy, no PII governance) for samen's foundry.
---

# What the project is

Code::Stats (codestats.net) is a free coding-activity/XP-tracking service: an editor plugin sends "pulses" (files touched, keystrokes, language) and the backend attributes XP per language, builds levels, and live-updates a public profile page while the user codes. It's a single-project Phoenix backend (~5,200 lines of Elixir/EEx across ~120 files), running since October 2017, still actively tagged (v2.4.9, August 2025) — a genuinely maintained, in-production hobby-scale service, not a toy or an archived repo. Stack: Erlang 25.2+/Elixir 1.14+, Phoenix, plain Ecto over PostgreSQL (no Ash), Elm for the live-updating frontend over Phoenix Channels, ETS for local caching (single-node deployment), Mix releases for deploys, GitLab CI builds the release and docs on push to master. License is CC-BY-NC-4.0 (non-commercial), not a permissive OSS license for reuse of the code itself.

# What samen could adopt

- **Mix-release production packaging as a concrete existence proof, not a new idea.** Code::Stats ships via `MIX_ENV=prod ... mix release` with `.env`-driven config (PORT/HOST/HOST_PORT) — this is already samen's own deploy shape; nothing new to take, but it's a useful "this pattern works at 8-years-in-production scale" data point if samen's docs ever want a real-world citation. Effort: N/A (no action).
- **Per-user cached-JSON-column pattern for hot read paths.** Code::Stats caches derived per-user stats (XP totals, language breakdowns) into a Postgres JSON column refreshed by a dedicated `XPCacheRefresher` process, rather than recomputing on every profile view. Samen's fleet cockpit and analytics/rollup modules solve a similar "expensive aggregate, cheap read" problem; a documented convention of "materialize to a JSON column behind a refresher process, not an ad hoc cache" is a small, generically reusable idea. Effort: S.
- **Phoenix Channels + minimal frontend for live-updating dashboards.** Code::Stats live-updates the index/profile page purely via Channels + Elm as pulses arrive. Samen already has cross-plane realtime chat (ADR-009-adjacent) and a fleet cockpit; if the fleet cockpit or operator dashboards ever want "live-updating without a polling loop," this is a working minimal-frontend reference, though samen's own `samen_web`/`ui` LiveView kit already covers this need more richly. Effort: N/A (samen already ahead here).

# What to ignore and why

- **No Ash at all.** Everything is hand-rolled Ecto/Phoenix; none of Ash's resource/policy/blueprint patterns exist here to borrow, so there's no architectural pattern transfer for samen's Ash-based kernel.
- **Single-tenant, single-node, no multi-tenancy.** Code::Stats has one flat user table and no org/tenant model; nothing here informs samen's two-plane, org-scoped, per-tenant-masking architecture, which is the actual hard problem samen exists to solve.
- **No PII vaulting, no masking, no audit chain, no crypto-shred.** The service stores usernames, emails, and language-activity data essentially in the clear (typical for a low-stakes hobby tracker); this is the opposite of samen's core differentiator and offers no governance pattern worth importing — adopting anything here would be a downgrade.
- **No billing, no approvals engine, no agent/AI plane, no verification/sabotage discipline.** None of samen's commercial-readiness or trust-kernel surfaces have an analogue in this codebase.
- **CC-BY-NC-4.0 license.** Even setting relevance aside, the code itself isn't permissively licensed for reuse, which further caps any "port this code" value versus "read it as a pattern reference."
- **ETS single-node caching as a scaling model.** Code::Stats explicitly runs on one BEAM node; samen already has multi-node Oban proofs (`L4`) and a fleet-of-apps model, so a single-node cache pattern doesn't map onto samen's target deployment shape.
