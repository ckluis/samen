---
project: Notesclub
url: https://github.com/notesclub/notesclub
category: Developer Tools
relevance: low
verdict: Active, well-run Phoenix/Oban content-discovery app (GitHub crawler + catalog for Livebook notebooks) — no multi-tenancy, PII governance, or AI-plane content, so only a couple of small operational patterns transfer to samen.
---

# Notesclub — evaluation vs samen

## What the project is

Notesclub (notes.club) is a discovery and indexing site for public Livebook notebooks on GitHub. It is a single-purpose Phoenix/Ecto app, MIT-licensed, actively maintained (99 stars, 8 forks, 790+ commits, pushed as recently as 2026-08-17, 10 open issues, ongoing contributions) — not dead or archived.

Stack and mechanism, per repo metadata and README:
- **Phoenix + PostgreSQL/Ecto**, Oban Pro for background jobs, GitHub OAuth via **Ueberauth**, AppSignal for monitoring, Credo + Dialyzer for code quality.
- **Discovery workers**: `RecentNotebooksWorker` paginates GitHub's API to find newly-published `.livemd` notebooks; `AllUserNotebooksSyncWorker` periodically re-syncs a known author's notebook set to catch edits/deletions.
- Test isolation via a `:github_api` tag (mocks GitHub in CI, seed data for local dev without hitting live rate limits).
- **Deploy**: Docker + docker-compose, Fly.io (`fly.toml`, staging environment configured).

It is a content-aggregation/catalog product for a public corpus (notebooks), with a simple single-tenant user model (GitHub login to claim/manage your own notebooks). There is no org/tenant model, no PII vaulting, no masking, no billing, no admin/operator plane distinct from the public site — none of samen's core differentiators (vault chokepoint, two-plane architecture, crypto-shred, reveal grants, hash-chained audit) have an analog here.

## What samen could adopt

1. **Paired "discover new" + "resync existing" Oban worker split for external-API ingestion** — What: two distinct periodic workers, one doing paginated discovery of new records from a rate-limited external API, the other doing bulk staleness-refresh of already-known records, rather than one monolithic sync job. Why it fits samen: samen's fleet cockpit (ADR-044) already does opt-in self-registration/heartbeat from remote apps, and any future "pull-based" catalog ingestion (e.g., syncing external vendor state, or a public gallery of generated apps) would benefit from separating "find new" from "keep existing fresh" so each has its own cadence, rate-limit budget, and failure blast radius. Effort: S — it's a workload-shaping convention, not new infrastructure.

2. **API-mock test tag + local seed fixtures for external-API-dependent workers** — What: a `:github_api` ExUnit tag to skip/mock external-API-hitting tests by default, plus seed data that lets the app run/demo without live credentials. Why it fits samen: samen already has a fake-provider/live-lane split for AI (`SAMEN_AI_LIVE=1`) and similar `_LIVE`/`_SMOKE` flags for Stripe/Postmark/ESP; this is the same discipline applied to any *inbound* crawler-style integration samen might add later (e.g., a future catalog-import adapter). Not a new idea for samen, just confirms the pattern is standard practice elsewhere. Effort: S, and likely already covered by samen's existing live-lane convention.

3. **Fly.io staging config as a deploy reference** — What: a working `fly.toml` + staging environment for a Phoenix/Oban app. Why it fits samen: WS-L (real Fly production deploys) is an open, credential-gated operator TODO in samen's roadmap; Notesclub is a live, small, real-world example of a Phoenix app's Fly config, usable as a cross-check when samen's operator does the real deploy drill. Effort: S (reference only, not code to import).

## What to ignore and why

- **Ueberauth (GitHub OAuth) for authentication** — samen's identity spine (ADR-035) already made a deliberate, documented choice of `assent` for OIDC and rejected `ash_authentication` rewrites; Ueberauth is a different, older library solving the same problem, and re-litigating that choice isn't warranted by a single-tenant public-content app's use of it.
- **AppSignal for monitoring** — samen has already standardized on OpenTelemetry (`opentelemetry`/`opentelemetry_api`/`opentelemetry_ecto`, with `db_statement` disabled specifically to keep PII tokens out of spans). Swapping in a vendor APM would be a regression against that PII-safety design choice, not an upgrade.
- **The core product (notebook discovery/crawling for a public corpus)** — orthogonal domain to a multi-tenant SaaS foundry; there is no tenant boundary, no masking surface, no billing, no reveal/approval flow, nothing that exercises samen's actual moat (governance-by-construction over PII). Not worth deeper study beyond the operational patterns above.
- **Oban Pro specifically** — samen already uses `oban`/`ash_oban` (OSS) deliberately and pins versions; nothing here suggests a reason to move to the paid Pro tier.
