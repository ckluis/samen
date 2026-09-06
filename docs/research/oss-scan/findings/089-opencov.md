---
project: OpenCov
url: https://github.com/danhper/opencov
category: Developer Tools
relevance: low
verdict: Old-style (pre-LiveView, pre-Ash) single-tenant Phoenix coverage-history viewer; shares the language but none of samen's architecture — at most a couple of minor interop-pattern crumbs.
---

# OpenCov — evaluation vs samen

## What the project is

OpenCov (MIT, 327 stars, created 2015, still lightly maintained — last push 2026-02) is a self-hosted, Coveralls-API-compatible test-coverage history webapp: projects ingest coverage reports (via a Coveralls-compatible POST endpoint + token), the app stores per-build/per-file coverage history, renders trend graphs, generates an SVG coverage badge per project, and has a basic admin panel for user/project management.

Stack, per the repo's language breakdown and README: Elixir (dominant) + old-generation Phoenix (`mix phoenix.server`, i.e. pre-1.3 Phoenix naming, predates Phoenix LiveView entirely), server-rendered HTML views (Pug templates, Stylus/Less for styling, a little jQuery-era JavaScript/TypeScript), Ecto/Postgres, standard `mix ecto.setup` seeding, SMTP for notifications, Docker/docker-compose and Heroku deploy paths. No Ash, no LiveView, no multi-tenant org model — it's a single admin-managed instance with a flat user/project list, and "not admin" is the only role distinction the README mentions.

Development status per the maintainer: "more or less stable," used personally with 4 languages' coverage data; the one documented gap is PR-status integration (started, unfinished on an `integrations` branch). This reads as a mature but essentially frozen personal-scale tool, not an actively evolving platform.

## What samen could adopt

1. **Coveralls-compatible ingestion API as an interop pattern** — What: OpenCov intentionally mimics the Coveralls POST-report contract so any existing CI coverage reporter works against it with zero client-side changes. Why it fits samen: if samen or a generated app ever exposes an "ops surface that speaks someone else's wire format" (e.g. a metrics or webhook ingress meant to be a drop-in replacement for a popular SaaS), copying an established third-party contract instead of inventing a new one is the same instinct as samen's `no_pii_columns`/`api_contract` verifiers protecting an existing shape. Effort: S (as a pattern to remember, not code to port).
2. **Per-project badge.svg endpoint** — What: a public, tokenless SVG-generation endpoint keyed by project slug, embeddable in a README. Why it fits samen: minor UX idea for the fleet cockpit (ADR-044) or an operator-plane status page (open gap G11) — a small "public read-only badge" surface is a cheap, well-understood interop convention worth keeping in mind for the still-open status-page item. Effort: S.

Neither is architecturally significant; both are copy-a-convention notes rather than code or dependency adoptions.

## What to ignore and why

- **The entire web/data layer** — old-style Phoenix controllers/views with no LiveView, no Ash resources, no declared types, no policy/RBAC layer beyond "is admin." Samen's `samen_web`/`samen_core` split, Ash blueprints, and rich types (ADR-036) are already a generation ahead of anything here.
- **Auth and user model** — flat admin/non-admin distinction with a single hardcoded seeded admin (`admin@example.com` / `p4ssw0rd` per the README, meant to be changed post-install). Samen's identity spine (ADR-035: registration, email verification, OIDC, TOTP, session management, invites) is categorically more complete; nothing to lift.
- **No multi-tenancy, no PII handling, no vaulting, no masking, no audit chain** — OpenCov has no concept resembling samen's core differentiators (vault chokepoint, two-plane architecture, crypto-shred, hash-chained audit). It is a single-purpose internal tool, not a SaaS-foundry building block; there is no tenancy model to even compare against samen's OrgScope/PiiResolution composition.
- **Deploy story (Docker/Heroku/`local.exs` config file)** — conventional and dated relative to samen's fail-honest adapter + generative-CI + sabotage-harness verification discipline; nothing here raises the bar samen already holds itself to.
- **Coverage-trend/history feature itself** — orthogonal to samen's product surface; samen's own suite-count and gate-report tracking (`docs/gate-*.md`, sabotage counts) already serves the equivalent internal need without a dependency.
