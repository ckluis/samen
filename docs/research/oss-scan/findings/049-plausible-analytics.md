---
project: Plausible Analytics
url: https://github.com/plausible/analytics
category: Analytics
relevance: high
verdict: Mature privacy-first Elixir/Phoenix analytics whose cookie-less identity, ClickHouse ingestion pipeline, and streamed-export patterns map directly onto samen's analytics scope and DSAR/status-page gaps — adopt patterns, not code (AGPL).
---

# 049 — Plausible Analytics

## What the project is

Privacy-centric web analytics (Google Analytics alternative): no cookies, no persistent identifiers, no stored IPs; GDPR/CCPA/PECR-compliant by construction. Very mature (28.7k stars, ~4.4k commits, active). Open-core split: Community Edition (AGPL-3.0, self-hosted, twice-yearly releases) vs proprietary Cloud with premium features (funnels, ecommerce, SSO/SAML).

Stack: Elixir ~>1.18 / Phoenix ~>1.8, PostgreSQL for accounts/settings, **ClickHouse (via `ecto_ch`) for the analytics event store**, React+Tailwind dashboard, MIT-licensed JS tracker. Oban for jobs, full OpenTelemetry suite + PromEx/peep for metrics, libcluster for clustering, `site_encrypt` for CE self-hosted TLS.

Architecture highlights confirmed from source (`lib/plausible/`):
- **Multiple Ecto repos by write path**: `Repo` (PG), `ClickhouseRepo` (reads), `IngestRepo`, `AsyncInsertRepo`, `DeletionRepo` — each tuned for its workload.
- **Ingestion pipeline** (`Plausible.Ingestion.Event.build_and_buffer/1`): Request → build → uniformly *buffered in batches* to ClickHouse or *dropped* with a closed `drop_reason()` union type (~17 reasons: `:bot`, `:spam_referrer`, `:dc_ip`, `:threat_ip`, site-level block rules, `:persist_timeout`, …); `WriteBuffer` batching; per-site `GateKeeper` admission policy; `Shield` (IP/country/page/hostname block rules); 32k+ datacenter-IP bot filtering.
- **Cookie-less visitor identity**: daily-rotating server-side salts (`Session.Salts`) + SipHash over (salt, domain, IP, UA) — the identifier is unlinkable across days and never stored raw. Session ownership balanced across processes (`Session.Balancer` / `Transfer`) with a cache-backed store.
- **EE/CE compile-time split**: `use Plausible` provides `on_ee`/`on_ce` macros that gate premium code paths at compile time in one codebase.
- **Data lifecycle**: streamed CSV exports/imports to S3 (`ex_aws` + `zstream` streaming zips, `nimble_csv`), Google Search Console import, purge/retention modules, `pending_stats_deletion` two-phase deletes.

## What samen could adopt

1. **Rotating-salt hashed identity for the analytics scope** — what: derive visitor/actor identifiers as `SipHash(daily_salt, …)` with salts rotated and old salts discarded, so analytics identity is structurally unlinkable and nothing PII-shaped is ever at rest. Why: this is "token-blind by construction" applied to product analytics — a perfect sibling to samen's masked-aggregate plane, and it upgrades `Samen.Scopes.Analytics` from CRUD counters toward real traffic analytics without touching the vault. Effort: **M** (`siphash` is a tiny dep; salt rotation is one GenServer + Oban job; verifier tier `verify.analytics_unlinkable` in the samen style).
2. **Closed drop-reason taxonomy + gatekeeper admission at the ingestion chokepoint** — what: Plausible's pattern of a single `build_and_buffer` chokepoint whose only outcomes are `buffered` or `dropped(reason ∈ closed union)`, with per-tenant GateKeeper policy and Shield block rules in front. Why: samen already believes in chokepoints and bounded-outcome allowlists (Automation `RunRecord`); applying the same shape to webhook/event ingress (and future analytics ingest) gives honest, enumerable failure telemetry instead of ad-hoc errors. Effort: **S–M** (pattern retrofit onto existing `Samen.Webhook`/wide_event ingress).
3. **Write-buffer batching + dedicated ingest/async-insert repos for ClickHouse** — what: `WriteBuffer` batching inserts, separate `IngestRepo`/`AsyncInsertRepo`/`DeletionRepo` instances, `ecto_ch` as the driver. Why: samen's digest lists ClickHouse ClickPipes activation as an open operator TODO and the token-blind aggregate plane is exactly what ClickHouse is for; Plausible is the best-in-class reference for PG-metadata + CH-events in Elixir. Effort: **L** (new storage tier; but the repo-per-write-path split alone is an **S** idea worth stealing for the local ClickHouse plan).
4. **Streamed S3 exports for DSAR self-serve (gap G19)** — what: `zstream` streaming zip assembly + `nimble_csv` + `ex_aws_s3` multipart upload, producing tenant-downloadable exports without materializing files in memory/disk. Why: G19 (DSAR self-serve export) is an open P2; Plausible's exports.ex shows the exact production-tested lib combo, and it composes with samen's existing CSV chokepoint (formula-injection neutralization stays). Effort: **M**.
5. **Two-phase stats deletion (`pending_stats_deletions`)** — what: deletion requests recorded as pending rows, executed asynchronously against the analytics store via a dedicated `DeletionRepo`. Why: when samen's erasure/crypto-shred meets an eventual ClickHouse tier, the destruction oracle needs a durable "deletion in flight" state to attest against; this is the proven shape. Effort: **S** once (3) exists.
6. **`zxcvbn` password strength in the identity spine** — what: realistic password-strength estimation at registration/reset. Why: cheap hardening for samen's generator-emitted auth flows; a pure-Elixir dep with no vendor/HTTP surface (INV-4 safe, though it would live in samen_web). Effort: **S**.
7. **`open_api_spex` for the JSON:API contract** — what: typed OpenAPI specs + request validation for the public API. Why: samen has `api/api_contract` and a `verify.api_contract` tier; emitting a machine-readable OpenAPI doc from the same source would strengthen the catalog-as-data story for external builders (G22). Effort: **M**.
8. **EE/CE `on_ee`/`on_ce` compile-time edition macros** — what: one codebase, compile-time feature gating via a `use`-injected macro pair. Why: if samen ever splits a public substrate from private verticals or paid features, this is the lightest-weight open-core mechanism in the Elixir ecosystem; also useful today for `SAMEN_AI_LIVE`-style lane gating without runtime flag checks. Effort: **S**.
9. **Geo/UA enrichment lib picks** (`locus` for MaxMind, `ua_inspector`, `ref_inspector`, `referrer_blocklist`) — what: the settled library choices for IP-geo, user-agent parsing, referrer spam. Why: if the analytics scope grows real traffic features, these are the vetted deps; note they'd live in an adapter package (locus does HTTP db updates) per INV-4. Effort: **M**.

## What to ignore and why

- **The code itself**: AGPL-3.0 vs samen's MIT — study and reimplement patterns; never vendor or transcribe source.
- **React dashboard + JS tracker**: samen is LiveView-first with its own UI kit; a web-tracker product is not samen's domain (samen instruments its own apps, not third-party sites).
- **`cloak`/`cloak_ecto`**: samen's ADR-003 already rejected Cloak-style encryption in favor of the per-subject-key vault + crypto-shred; Plausible's use is app-secret encryption, a weaker model than samen's.
- **`bamboo` + Postmark, `sentry`**: samen has first-party fail-honest ESP adapter packages and its own observability posture; swapping would be regression, not adoption.
- **`fun_with_flags`, `paginator`, Hammer-alternatives**: samen already has feature flags, a keyset-pagination reads contract, and ash_rate_limiter+hammer — no gain.
- **`site_encrypt`, libcluster topologies, self-host packaging**: solves CE-distribution problems samen explicitly doesn't have (ADR-033: in-monorepo, no external distribution).
- **SAML (`simple_saml`)**: samen deliberately keeps SAML as a documented extension seam; Plausible's EE-only SSO confirms it's separable, but doesn't change the deferral.
