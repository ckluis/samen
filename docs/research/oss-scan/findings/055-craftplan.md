---
project: Craftplan
url: https://github.com/puemos/craftplan
category: Business and Collaboration
relevance: medium
verdict: High-quality single-tenant Ash 3 vertical ERP — no substrate to lift (AGPL anyway), but strong pattern donor for samen's i18n gap (G24), S3 storage follow-on, OpenAPI surface, and runtime email-provider settings UX.
---

# 055 — Craftplan

## What the project is

Craftplan is an open-source (AGPL-3.0) self-hosted ERP for small artisanal manufacturers / craft D2C businesses: product catalog with **versioned, nested BOMs and automatic cost rollups**, production batching with material consumption, raw-material inventory with lot traceability, **statistical demand forecasting** (z-score safety stock, configurable service level / lookback / horizon), supplier + purchase orders, calendar-scheduled customer orders with invoicing, CRM, CSV import/export, iCal feeds, ⌘K command palette, and JSON:API + GraphQL APIs.

Stack: Elixir ~>1.20, Phoenix ~>1.8, LiveView ~>1.1, **Ash ~>3.0 + ash_postgres 2**, ash_authentication, ash_json_api + ash_graphql + open_api_spex, ash_money/ex_money_sql, cloak_ecto (encrypted settings), waffle + ex_aws_s3 (MinIO/S3 uploads), nimble_csv, icalendar, tz, **ex_cldr + gettext**, bandit, Docker Compose one-command deploy plus Railway/Fly configs. Domain layer is clean Ash DDD: `accounts, calendar, catalog, crm, csv, encrypted, inventory, orders, production, settings, types` under `lib/craftplan/`, with a pure-logic `inventory_forecasting.ex`. Active and healthy: ~1.1k stars, 62 forks, 343 commits, v0.6.0, structured contribution/formatting discipline (Styler, Spark, HEEx formatters). **Single-tenant per instance — no multitenancy, no operator plane, no PII vaulting.**

## What samen could adopt

1. **ex_cldr + gettext + tz i18n/currency wiring (targets samen gap G24).**
   - What: Craftplan ships Cldr (`cldr.ex`), Gettext, and the `tz` timezone DB integrated with ash_money/ex_money for locale-aware currency, plus per-install currency/tax settings. Samen is USD+UTC hardcoded with no gettext (digest §11, G24).
   - Why it fits: same Ash 3 + ash_money base, so Craftplan is a working reference for exactly the libraries samen would pick; closes a named P2 gap without inventing anything.
   - Effort: **M** (kernel type plumbing + UI kit pass; verifier for no-hardcoded-locale strings is extra).

2. **ex_aws_s3 upload path as reference for samen's fail-honest `Storage.S3` (WS-E follow-on).**
   - What: Craftplan's waffle + ex_aws + ex_aws_s3 + MinIO setup is a small, working S3-compatible object-storage implementation including local dev via MinIO in docker-compose.
   - Why it fits: samen shipped `Storage.S3` as an honest `{:error, :not_implemented}` skeleton; Craftplan shows the minimal real implementation and a MinIO-based local lane samen could use to make the S3 adapter CI-provable without AWS credentials (pattern for the vendor adapter package — deps stay out of core per INV-4).
   - Effort: **M** (implement in a `samen_s3`-style adapter behind the existing files chokepoint; MinIO service in a live-lane, not root CI).

3. **OpenAPI spec emission via open_api_spex on the JSON:API surface.**
   - What: Craftplan exposes open_api_spex-backed API docs alongside ash_json_api.
   - Why it fits: samen already has `api/api_contract` + `mix samen.verify.api_contract`; emitting a machine-readable OpenAPI doc from the same surface strengthens the catalog/contract story and the agent-grounding packaging theme (G22) — an OpenAPI doc is another LLM-groundable artifact.
   - Effort: **S** (ash_json_api has open_api integration; add a parity check against the existing contract verifier).

4. **Tenant-facing runtime email-provider settings surface (pattern, not the library).**
   - What: a singleton encrypted Settings resource (`email_provider` atom over SMTP/SendGrid/Mailgun/Postmark/Brevo/SES, `EncryptedBinary` API keys, `sensitive? true`, admin-gated update, unauthenticated `:init` bootstrap action) that reconfigures the mailer at runtime.
   - Why it fits: samen's ESP adapters (Postmark/SES/Resend) are operator/env-configured; a per-host runtime provider-selection settings resource in front of `Samen.Delivery.Chokepoint` is a genuine product-surface upgrade for hosts. Caution: Craftplan stores secrets with cloak_ecto — samen rejected Cloak (ADR-003) and must route these credentials through its own vault/KMS instead; adopt the UX and singleton-resource shape only. The `:init` bootstrap-without-auth action is also a useful first-run pattern for generated apps, but must be fail-secure in `:prod` (cf. ADR-045).
   - Effort: **M**.

5. **Inventory/manufacturing as a future vertical proof or scope blueprint (idea bank).**
   - What: the domain decomposition (catalog/BOM-versioning with read-only history + cost rollup calculations, inventory movements consume/receive/adjust, production batches, purchasing, forecasting as a pure module fed by orders+BOMs+stock+settings — `prepare_materials_requirements`, `owner_grid_rows`, `open_purchase_orders_by_material`) is a clean map of what a `Samen.Scopes.Inventory`/`Manufacturing` blueprint or a third vertical (after driftwood/pawchart) would need.
   - Why it fits: substrate-first (INV-5) — if samen ever wants a "light ERP" scope, this is the best-in-ecosystem Ash reference for resource shapes and the versioned-BOM-with-rollup pattern (samen already has versioning + revenue/rollup machinery to build it on).
   - Effort: **L** (only if/when a vertical demands it; file as idea, don't build).

## What to ignore and why

- **Code reuse of any kind**: AGPL-3.0 is incompatible with MIT samen — patterns and library choices only, never lifted code.
- **ash_authentication / ash_authentication_phoenix**: samen deliberately built its own identity spine and rejected ash_authentication rewrites (ADR-037/035); Craftplan's simpler Admin/Staff RBAC is far below samen's two-plane three-identity model.
- **ash_graphql**: samen's API posture is deny-by-default JSON:API; adding a second API surface widens the PII-egress audit area for no current need.
- **cloak_ecto encryption**: directly conflicts with ADR-003 (custom thin vault over OTP crypto + external KMS); Craftplan's approach has no crypto-shred, no per-subject keys.
- **Single-tenant architecture, CSV handling, command palette, iCal**: no multitenancy to learn from; samen's CSV chokepoint (RFC-4180 + formula-injection neutralization), ⌘K search, and ics module already meet or exceed Craftplan's equivalents.
- **Docker Compose self-host onboarding**: nice DX, but samen is an in-monorepo foundry (ADR-033), not a distributed self-hosted product; not a current goal.
