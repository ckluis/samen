---
project: Logflare
url: https://github.com/Logflare/logflare
category: Infrastructure and Operations
relevance: medium
verdict: Not a component to embed (BigQuery/ClickHouse-centric, Supabase-owned, multi-tenant SaaS product) — but its multi-backend Adaptor pattern, cron-scheduled AlertQuery design, and Cloak key-rolling vault are concrete, code-adjacent references for samen's still-open G11 alerting/status gap and its single-sink wide-event exporter.
---

# 104 — Logflare

## What the project is

Logflare (Logflare/logflare, Apache-2.0, ~1,000 stars, actively pushed as of today, Elixir/Phoenix) is "stream logs to a central service and tail them in your browser" — a hosted structured-log-ingestion, search, and alerting service. It is now owned/maintained by Supabase and sold as a product at logflare.app; the OSS repo is the actual production codebase, not a reference toy.

Architecture (`architecture.md`, `lib/logflare/`):
- **Per-source ingestion pipeline**: each `Source` gets a `SourceSup` (one per BEAM node) — events land in a `MemoryBuffer`, get pulled into a **Broadway** pipeline, and are dispatched in batches to every configured **Backend** for that source.
- **Pluggable multi-backend fan-out via an `Adaptor` behaviour** (`Logflare.Backends.Adaptor`): one source can stream simultaneously to BigQuery, ClickHouse, Postgres, S3, Datadog, Elastic, Loki, OTLP, Slack, Webhook, Sentry, Syslog, Axiom, incident.io, last9. `Adaptor.get_adaptor/1` maps a `Backend.type` to its module; each adaptor owns `cast_config/validate_config/transform_config`; each `{source, backend}` pair gets its own supervised `AdaptorSupervisor`.
- **LQL (Logflare Query Language)**: a backend-agnostic query DSL (`Logflare.Lql`) with a `BackendTransformer` per SQL dialect (bigquery/clickhouse/postgres) — parse → encode/decode → dialect-specific SQL. Powers saved searches and "Endpoints" (a saved LQL query promoted to a stable, parameterized HTTP API route).
- **Alerting** (`Logflare.Alerting`): `AlertQuery` rows run on a **Crontab**-parsed cron schedule via `AlertWorker`/Oban, execute against a backend (BigQuery/etc.), and on a match dispatch through the same Adaptor set (Slack, Webhook, ...). Straightforward query → threshold → notify loop with reused pipes.
- **Secrets vault**: `Logflare.Vault` — plain `Cloak.Vault` protecting backend credentials (e.g. BigQuery service-account JSON) at rest, with a `default/retired/fallback` key ring and a `do_migrate/0` re-encryption path for key rotation. This is *not* a PII-masking system — it's narrowly scoped to protecting stored backend config secrets.
- **SingleTenant mode** (`Logflare.SingleTenant`): a self-host escape hatch that bootstraps a default user/plan so the multi-tenant SaaS can run as a single-tenant install.
- Real production billing (`stripity_stripe` + `money`), OAuth2 provider for third-party API access, `phoenix_live_react` for parts of the UI, `libcluster`/`syn` for clustering.

## What samen could adopt

1. **Generalize the single-sink wide-event exporter into an Adaptor-style registry.** Samen's `samen_core/lib/samen/wide_event/sinks/otlp.ex` is currently one OTLP sink; Logflare's `Adaptor` behaviour (uniform `cast_config/validate_config`, per-backend supervision, `get_adaptor/1` type→module mapping) is a clean, minimal-surface pattern for adding a second or third sink type (e.g. a webhook/Slack sink for operator alerts, or a Postgres sink for local dev) without touching the emit path. Why it fits: samen's fail-honest-adapter posture (samen_stripe/samen_postmark/etc.) already lives on the same idea — a well-typed adaptor behaviour with config validation is the missing piece for a *plural* sink story. Effort: **S–M**.

2. **Cron-query-notify AlertQuery loop as the design blueprint for G11's "public status/SLA + alerting" gap** (still open per `docs/saas-gap-roadmap.md`). Logflare's shape — a stored query + cron schedule + threshold check + dispatch through the existing adaptor set — maps directly onto samen's operator-plane metrics (`Samen.Metrics.definitions/0`, Prometheus egress) and Oban. Samen would harden it further (fail-honest on unconfigured notify target, approvals-gated mutation if an alert can trigger an action, token-blind evaluation so alert queries can't leak PII). Effort: **M**.

3. **Cloak-style key-ring rotation (`default/retired/fallback` + `do_migrate/0`) as a concrete rotation UX for `Samen.Kms`.** Samen's ADR-001 defines per-subject keys in an external KMS but the digest doesn't describe an operator-facing rotation/migration flow; Logflare's pattern — retired key stays decryptable, default key re-encrypts on a background migration, fallback covers bootstrap — is a small, well-tested shape to adapt (samen would keep its own AES-256-GCM/`Samen.Kms` behaviour; only the rotation *state machine* is worth borrowing). Effort: **S**.

4. **LQL's dialect-transformer split (parse once, render per backend)** is a useful reference if samen's catalog/search layer ever needs to target more than one query engine (today: Postgres tsvector only). Not urgent — flag for later if samen adds a second read-side store. Effort: **M**, speculative.

5. **Point samen's own OTLP wide-event sink AT a Logflare/Supabase-Logflare instance** as one legitimate hosted backend option for operators who want browser log tailing + search without standing up Honeycomb/Tempo/Loki — this is an infra choice for builders using samen, not a code import, but worth naming in samen's observability guide as a documented option since Logflare explicitly documents OTLP ingestion. Effort: **S** (documentation only).

## What to ignore and why

- **The whole service as something to run/embed.** Logflare is a BigQuery/ClickHouse-centric multi-tenant SaaS product now owned by Supabase, with its own billing, OAuth2 provider, and web UI — adopting it wholesale would violate samen's in-monorepo, vendor-free-core, no-Hex-package posture (ADR-033, INV-4). It's a reference architecture, not a dependency.
- **Cloak/`cloak_ecto` itself.** Samen already evaluated and rejected AshCloak/Cloak for its PII vault (ADR-003) in favor of a custom chokepoint-driven vault with per-subject external KMS keys — Logflare's use of Cloak is for a much narrower problem (encrypting backend service-account creds), and re-litigating that ADR isn't warranted; only the key-rotation *shape* (item 3) is worth lifting.
- **BigQuery/ClickHouse/GCP-heavy dependency surface** (`google_api_*`, `ch`, `explorer`, Rust NIFs via `rustler`): none of this belongs in samen_core (INV-4, zero vendor/HTTP deps) or even as a samen adapter package unless a concrete builder need for BigQuery-backed analytics emerges — currently no gap calls for it.
- **LQL as a full query language to adopt verbatim.** It's tightly coupled to Logflare's three backends and its own schema-inference story (`source_schemas`); samen's catalog-driven, type-declared approach (ADR-036 rich types + catalog parity verifiers) is already stronger for samen's use case of grounding LLMs/tooling.
- **OAuth2 provider (`phoenix_oauth2_provider`) for third-party API access.** Not a current samen gap (identity spine covers OIDC-as-client via `assent`, not "samen apps as an OAuth provider"); no roadmap item points at this.
