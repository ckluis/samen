# ADR Index

Every accepted architecture decision in the foundry, one line each: number → title → the
decision in one clause. Read the ADR itself before changing anything it governs (per
`CLAUDE.md`) — this table is a map, not a substitute.

Numbering is chronological, not thematic; the columns below group them by concern so you can
scan for "everything about the vault" or "everything about the operator plane" without
reading all 33.

## Vault, crypto-shred, audit

| # | Title | Decision |
|---|---|---|
| [001](001-key-hierarchy.md) | The per-subject external-KMS key hierarchy | Each subject's vault key lives in an external KMS outside the Postgres/WAL surface, so destroying it (crypto-shred) makes every tier unrecoverable at once and a PITR restore cannot resurrect it. |
| [002](002-worm-anchor.md) | Hash-chained audit + WORM anchor | The audit log is a hash-chained, append-only, tenant-readable table (trigger-refused edits) periodically anchored to a WORM store, carrying tokens only so it stays crypto-shreddable. |
| [003](003-encryption-lib.md) | Encryption-library integration for the per-subject vault | Reject AshCloak / a `Cloak.Vault`-per-subject wrapper; build a thin custom vault layer directly on OTP `:crypto` AES-256-GCM driven by the `Samen.Kms` behaviour. |

## Scope packaging & the framework extraction

| # | Title | Decision |
|---|---|---|
| [004](004-scope-packaging.md) | Scope packaging: how a universal scope ships and how a host mounts it | Every universal scope ships as a library-authored Ash blueprint macro (`use Samen.Scopes.X`) that a host materializes into its own namespace/repo — the packaging seam every later scope copies. |
| [005](005-operator-plane-migration-extraction.md) | Extract the `aud_chain` operator-plane migration into a shared core helper | Extract the hash-chain audit migration into a shared core template so every host mounting the operator plane gets it without hand copy-paste. |
| [006](006-abbrev-registry-scoping.md) | Abbrev registry: global-vs-per-host scoping | Defer the registry refactor for now; adopt per-host-namespaced ownership inside one global registry file (Option B) as the target, explicitly behind a future generator. |
| [007](007-rollup-cron-worker.md) | Rollup refresh as a real AshOban cron worker vs a plain function | Define the spec-registration bridge for rollups as real cron workers; defer wiring vertical rollups until a 3rd vertical confirms the generalized `Spec` shape. |
| [008](008-ui-kit.md) | Samen product-UI kit (function components + shared CSS) | Unify the three approved product-UI mockups into one shared function-component kit + `:root` token CSS (later superseded by ADR-009). |
| [009](009-samen-web.md) | `samen_web`: the framework UI library + the two-plane mountable-module pattern | Promote the inherited product UI (component kit + CRM/Billing/Support LiveViews) out of driftwood into a shared `samen_web` lib, parameterized by a `Samen.Web.Mount` struct and driven by a `Samen.Web.Plane` two-plane (tenant/operator) abstraction. |

## The operator / control plane

| # | Title | Decision |
|---|---|---|
| [010](010-operator-plane.md) | The Operator / SaaS-company plane: accounts ARE tenant orgs, platform billing over tenants, the SaaS's own help desk, and the identity line | The SaaS is itself an org (the operator org) mounting the same universal scopes over its tenant orgs as accounts; the identity line (tenant-admin PII clear, tenant end-customer PII masked) is drawn purely by composing the existing `OrgScope` + `PiiResolution` primitives — no new masking code. |
| [011](011-crm-enrichment.md) | CRM enrichment: contact/company detail, activity timeline, email/sequences, prospecting, social — a real CRM in `samen_web` | Build a world-class CRM (detail pages, activity timeline, email/sequences, prospecting, social) entirely in `samen_web` so every vertical inherits it. |
| [012](012-crossplane-chat.md) | Cross-plane realtime chat, catalog-driven object unfurl, and the participant identity model | Ship a flagship framework-level chat spanning the operator↔tenant plane boundary, with a catalog-driven, per-viewer masking-aware object unfurl and a 3-state participant identity model. |
| [013](013-demo-coherence.md) | Demo coherence: home, current-org resolution, workspace switcher, and the 5-tenant seed | Fix Driftwood's entry model — session-resolved current org, a real workspace switcher, the operator "Open account →" drill-in, a 5-brokerage seed — so the three-plane model is navigable without typed UUIDs. |

## WS-A "Product Reality"

| # | Title | Decision |
|---|---|---|
| [014](014-delivery-adapter-fail-honest.md) | Outbound delivery adapter contract, fail-honest send semantics, and abbrev-derived suppression | Replace the always-succeeds stub email adapter with a pluggable, fail-honest `Samen.Delivery.Adapter` behaviour, and derive the suppression check from the abbrev instead of a hardcoded table name. |
| [015](015-default-deny-cdc-classifier.md) | Default-deny CDC/aggregate classifier for freeform content columns | Flip the CDC/aggregate projection default for freeform string/text/map columns from opt-out-of-flagging to opt-in-allowlisted (vault-routed or two-reviewer `non_pii!`), closing the silent-PII-mirroring gap. |
| [016](016-kit-list-crud-notifications.md) | Kit list/CRUD primitives, keyset pagination contract, and the masking-aware notifications engine + inbox | Ship kit-level `simple_form`/`modal`/`list_view` primitives + a `ListLive` behaviour, a keyset-pagination reads contract, and a masking-aware notifications delivery engine + inbox — framework-first. |

## WS-B "Operator Cockpit v1"

| # | Title | Decision |
|---|---|---|
| [017](017-subscription-movement-ledger.md) | Subscription-change ledger via the StatusChange seam (not audit-event reconstruction) | Capture MRR-movement events with a dedicated append-only `Billing.SubscriptionEvent` resource, written by a change modeled on the proven `StatusChange` seam — not reconstructed from the audit tier. |
| [018](018-domain-sourced-rollup-spec.md) | Implement the `:source :domain` rollup Spec dimension now (resolving the ADR-007 defer) | Implement the previously-deferred `:source :domain` rollup dimension so a domain-table-sourced rollup (the revenue-movement rollup) can register, and extend the destruction oracle to cover it. |
| [019](019-health-score-model.md) | Composite, explainable per-tenant health score (compute layer, not a new PII surface) | Compute a composite, explainable per-tenant health score (`HealthBreakdown` with weighted factors) purely over already-assembled operator-read data — no new PII surface. |
| [020](020-feature-flag-evaluation-engine.md) | Feature-flag evaluation engine: kernel placement, deterministic bucketing, non-PII keys, fail-safe kill switch | Build the flag evaluation engine (`evaluate/2`) in the kernel with deterministic `phash2` bucketing, non-PII targeting keys, and a fail-safe kill switch; the admin UI lives in `samen_web`. |
| [021](021-product-analytics-event-primitive.md) | Product-analytics event capture: a new governed kernel resource (not WideEvent), refusing PII at capture | Capture product events via a new governed kernel resource (`Analytics.ProductEvent`, token-blind by construction) rather than overloading `WideEvent`/`Notifications`/`AuditEvent`, refusing PII-bearing payloads at the capture boundary. |

## WS-D "Builder Joy"

| # | Title | Decision |
|---|---|---|
| [022](022-generator-emits-running-product.md) | The generator emits a running product (flagged web/API/seed/observability), not a headless data layer | `mix samen.gen.app` scaffolds a real running product (web UI, JSON:API, seeds, observability) behind flags, not just a headless data-and-gate scaffold. |
| [023](023-abbrev-reserve-allocator-host-namespace.md) | `mix samen.abbrev.reserve` allocator + host-namespaced registry schema (implementing ADR-006 Option B, bounded) | Ship `mix samen.abbrev.reserve` (deterministic propose/reserve) plus a host-namespaced registry schema, implementing ADR-006's deferred Option B, bounded behind the generator. |
| [024](024-generated-deploy-fail-honest.md) | Generated deploy artifacts are fail-honest, not aspirational | Generated deploy artifacts (Fly/Neon/secrets) must be fail-honest — raising and naming a missing secret rather than shipping an aspirational "just run `fly deploy`" claim. |
| [025](025-abbrev-verifier-host-partition-followon.md) | Abbrev registry + verifier host-partition (phased follow-on to ADR-023) | **Proposed/deferred** — a phased follow-on to fully host-partition the abbrev registry and its verifier, filed as a bounded decompose item, not yet built. |

## WS-E "Table Stakes UX"

| # | Title | Decision |
|---|---|---|
| [026](026-files-storage-adapter-fail-honest.md) | Files engine: fail-honest storage adapter behaviour, quarantine-by-default, LiveView upload chokepoint | Build a `Samen.Files.Storage` adapter behaviour (`Local` + an `S3` skeleton, fail-honest) with a LiveView upload chokepoint, quarantine-by-default freshly-uploaded files, and a masking-aware preview surface. |
| [027](027-search-engine-non-pii-tsquery.md) | Search engine: kernel `Search.query/2` over the non-PII tsvector, registry-gated, org-scoped, ⌘K in samen_web | Build a kernel `Samen.Search.query/2` over the existing non-PII tsvector/registry, org-scoped and ranked, with a `samen_web` ⌘K palette on top. |
| [028](028-csv-import-export-mask-by-omission.md) | CSV import/export: catalog-driven mapper, export as a first-class masking surface, import through the write chokepoint | Build a catalog-driven CSV mapper where export renders every cell through the same per-plane masking seam as the UI (non-negotiable red path) and import writes through the vault `WriteGuard` chokepoint. |
| [029](029-self-serve-settings-scope-gated-self-edit.md) | Self-serve settings: profile self-edit through the vault chokepoint, API-key mint UI, host-owned auth boundary respected | Build a `/settings` surface (profile self-edit, API-key management, session list) that writes the user's own vaulted PII through the same `WriteGuard`/`Vault.Change` chokepoint, keeping auth host-owned. |
| [030](030-responsive-kit-level-pass.md) | Responsive: a kit-level CSS pass (one stylesheet, one shell component) so every vertical becomes mobile-usable at once | Make the whole fleet mobile-usable with one CSS-and-kit-only pass (two breakpoints; sidebar becomes a toggle drawer; tables restack or scroll) — no per-page LiveView changes. |

## Launch (F1–F4)

| # | Title | Decision |
|---|---|---|
| [031](031-byo-auth-launch-onramp.md) | BYO-auth launch on-ramp: the prod tenant actor is derived from an authenticated session, not a query param | Wire a real session-auth flow into `Samen.Web.CurrentOrg` for one vertical (driftwood), replacing the query-param-derived actor on its prod path. |
| [032](032-data-residency-us-only.md) | Data residency: US-only, documented (no per-tenant region selection) | Document (no code change) that the single-Postgres-per-host model is US-only with no per-tenant region selection, and name what a real multi-region story would require. |
| [033](033-in-monorepo-distribution-constraint.md) | Framework distribution stays path-dep-in-monorepo; Hex publishing deferred to a stated trigger | Keep framework distribution as `path:` deps inside the monorepo; defer Hex publishing until a stated trigger, since every consumer today resolves the framework via a path dep. |

## Hardening (F7)

| # | Title | Decision |
|---|---|---|
| [034](034-nonpii-type-selfclassify-reviewer-gate.md) | The type-level `:non_pii` self-classification is reviewer-gated (two distinct parties) | Honor a host type's `:non_pii` self-classification only behind a valid two-distinct-party clearance (`Samen.NonPii.TypeClearance`, a pure config allowlist); an ungoverned/self-reviewed one falls through to the mask-unknown-by-default PII result — closing the single-party escape hatch, symmetric with the per-column `non_pii!` gate. |

## SaaS-readiness ecosystem + rich types (WS-H) + identity spine (WS-A)

| # | Title | Decision |
|---|---|---|
| [ADR-035](ADR-035-identity-spine.md) | Identity spine architecture: the WS-A A1–A10 contracts | Consumes ADR-037 §5.1 (AshAuthentication REJECT) → hand-built spine on the existing seams: org-less `Identity.Credential` principal + Session/AuthToken/UserIdentity resources, HMAC blind-index email lookup (no plaintext email at rest; `k_bidx` = reserved Kms subject `sys:bidx`, shred-refused), hashed single-use tokens, DB-backed revocable sessions (tenant-plane only), PBKDF2-SHA256 behind `Samen.Auth.Hasher`, assent/nimble_totp/ash_rate_limiter placed in `samen_web` only — `samen_core/mix.exs` untouched. |
| [ADR-037](ADR-037-ash-ecosystem-adoption.md) | Ash-ecosystem adoption evaluation (operator directive M6) | One ADOPT/REJECT verdict per Ash package against INV-1/INV-3/maturity/cost: ADOPT ash_money, ash_archival, ash_paper_trail, reactor, ash_state_machine, ash_oban, ash_rate_limiter (narrow), usage_rules (dev); REJECT ash_authentication, ash_events, ash_ai, ash_geo, ash_csv, ash_double_entry, ash_admin — no verdict weakens a masking claim or removes a verifier tier. |
| [ADR-036](ADR-036-rich-types.md) | Rich property types: the H1–H7 `Ash.Type` contracts, AshMoney-backed `Money`, destructive cents→composite migration | `Samen.Type.Money` wraps `AshMoney.Types.Money` (samen name in catalog, package semantics); non-PII types (Money/Percent/Score/Duration/Priority/URL) self-classify `:non_pii` behind a two-party `TypeClearance`; email/phone stay PII-by-default (personal→vault, org-contact→per-column clearance); Address is a PII composite (`pii_address`); H1 migrates Opportunity + Price via one pre-1.0 destructive data-copy migration per resource (implements ADR-037 §5.2). |

---

37 ADRs total. All are `Status: Accepted` except ADR-025 (`Proposed (deferred)`). If you add a
new one, append a row here in the same pass (`docs/guides/cookbook.md`'s claim-evidence
discipline applies to this index too — keep it honest, not aspirational).
