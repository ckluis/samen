---
project: Inkwell
url: https://github.com/stantondev/inkwell
category: Communication and Social
relevance: low
verdict: Well-crafted indie Phoenix/ActivityPub journaling product, but domain, frontend split, and license diverge from samen; only small delivery-channel and inbound-email patterns are worth borrowing.
---

# 067 — Inkwell

## What the project is

Federated social journaling + community platform (LiveJournal-meets-MySpace) built on ActivityPub, AGPL-3.0. Small but active (8 stars, ~562 commits, Docker images published on every push to main). Stack: Elixir ~1.17+/Phoenix 1.8 API (contexts-based, **no Ash**) + a **Next.js 16/React frontend** (npm-workspaces monorepo), PostgreSQL 16, Oban, Meilisearch (with Postgres ILIKE fallback), gen_smtp/Resend email, Stripe subscriptions plus Stripe Connect micropayments ("Postage", 8% commission). Federation is hand-rolled natively in Phoenix — WebFinger, HTTP Signatures, actor endpoints, entries federated as `Article` (FEP-b2b8) — no ActivityPub hex library and no sidecar. Deps are notably lean: bandit, oban, atomex (Atom feeds), saxy, gen_smtp, web_push_encryption, bcrypt_elixir; no Stripe or HTTP-client lib surfaced in mix.exs, implying hand-rolled API clients. Deploys as three Fly.io apps (api/web/search) with auto-migrations; ships SELF_HOSTING.md (Docker Compose + Caddy, backup/restore/upgrade docs). Magic-link auth with a dev mode that renders the link on screen so no email service is needed locally.

## What samen could adopt

- **Web push as a notification delivery channel** (`web_push_encryption`, VAPID). What: browser push endpoint + subscription storage feeding the existing notifications inbox. Why it fits: samen already has notifications + prefs and a single send path (`Samen.Delivery.Chokepoint`); push is just another masked-payload sink behind it, and the lib is dependency-light (adapter package per INV-4, not core). Effort: M.
- **Inbound email → object creation ("post-by-email") pattern.** What: unique per-tenant/per-object ingest addresses, SMTP/webhook ingestion parsed by an Oban job into drafts. Why it fits: samen's mailbox scope and support-desk depth gap (G21) both want email-in (reply-to-ticket, email-to-CRM-activity); ingestion must route through the vault chokepoint since inbound mail is PII-laden — a good red-path exercise. Effort: M.
- **Dev-mode "link on screen" delivery.** What: in dev, the email adapter surfaces the actionable link/token in the UI instead of requiring a mail service. Why it fits: matches samen's keyless-by-default, fail-honest local-sim ethos; improves generated-app first-run DX for verification/reset flows. Effort: S.
- **Generated SELF_HOSTING.md for host apps.** What: `samen.gen.app` emitting a Caddy/Docker-Compose self-host + backup/upgrade doc, verified by the existing doc_commands harness. Why it fits: samen already treats docs-as-code; verticals lack a per-app self-host story. Effort: M, low priority.
- **Atom/RSS feed generation (`atomex`)** for public surfaces (status page — open gap G11 — or CMS scope changelogs). Small, non-PII by construction. Effort: S.

## What to ignore and why

- **ActivityPub/federation itself** — impressive hand-rolled work, but federation has zero pull in samen's B2B SaaS roadmap, and its identity model (public actors, open inboxes) is opposite to mask-by-default.
- **Next.js frontend split** — samen is deliberately LiveView + server-rendered two-plane; a JS SPA frontend contradicts the mount/plane architecture.
- **Meilisearch** — samen chose Postgres-only purity (non-PII tsvector); an extra search service adds an ops dependency samen rejected. The ILIKE-fallback idea is already covered by samen's fail-honest posture.
- **Stripe Connect micropayments** — marketplace payouts are out of scope; samen's G13 needs plain Stripe sync (currently a stub) first, and Inkwell's Stripe code isn't visible enough to learn from.
- **Code reuse of any kind** — AGPL-3.0 vs samen's MIT: patterns only, never copied code.
- **Auth approach** — magic-link-only is thinner than samen's shipped identity spine (password + OIDC + TOTP + sessions); nothing to gain.
