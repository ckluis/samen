# ADR-021 — Product-analytics event capture: a new governed kernel resource (not WideEvent), refusing PII at capture

- **Status:** Accepted (design; WS-B phase B7 implements the seed).
- **Date:** 2026-07-13
- **Task:** WS-B / G12 seed — a governed product-event capture primitive (framework-emitted: sign-in, first-run, record-created, search-used, flag-assignment) flowing into the vault-excluded CDC projection, plus one thin operator funnel/retention read.
- **Deciders:** opus (WS-B design), grounded in `docs/gap-discovery/operator.md` G2 (the PII-safe-by-construction analytics moat), `docs/cdc-analytics-tier.md`, and the live `WideEvent` / `Notifications` / `AuditEvent` primitives.

---

## 1 · Context

There is no product-event capture today. Three existing primitives were considered as the feed: `WideEvent` (a 7-day-TTL observability STRUCT, not persisted, bounded-type-only), `Notifications` (`pnt`, a UI/delivery record with a vault-routed body), and `AuditEvent` (`aud`, a compliance/system-event log with no product semantics). None is a durable, per-tenant, erasure-covered, CDC-mirrorable product-event LEDGER.

## 2 · Decision

**Build a new kernel resource `Analytics.ProductEvent` (abbrev `pae`) in the primitives scope, token-blind by construction, captured via `Samen.Analytics.track/1`, refusing PII-bearing payloads at the capture boundary.** Capture is a kernel candidate (framework-emitted from choke points every plane/worker hits — session, first-run, kit create path, search); funnel/retention READS are a thin `samen_web` operator surface.

`pae` columns are ALL bounded/non-PII: `pae_org_id` (bounded id), `pae_actor_ref` (a per-subject-keyed HMAC pseudonym via the existing `WideEvent.for_subject/2` — never a raw id), `pae_event_name` (enum from a registered catalog — never freeform), `pae_entity_ref` (bounded id/token), `pae_occurred_at` (timestamp), `pae_props` (bounded map, structurally validated per event schema, no freeform strings).

`track/1` is best-effort (rides alongside the primary write like `Engine.emit/2`, never fails it) and validates the payload against the bounded catalog + the shared `Samen.Pii.Classification` oracle — a prop that classifies `:plaintext_pii` is REFUSED (dropped + logged `:pii_rejected`, never persisted).

## 3 · Rationale

- **Why NOT WideEvent** — it's observability-shaped (short TTL, not persisted, no per-tenant scope, no erasure coverage). Product analytics need durability, org-scoping, and the CDC path. Reusing WideEvent would either break its observability contract or fail to persist. (We DO reuse its `for_subject/2` pseudonym mechanism for `pae_actor_ref` — the right piece to borrow.)
- **Token-blind by construction = the moat** — because `pae` carries only tokens/pseudonyms/enums/bounded-ids, it mirrors cleanly through the vault-excluded CDC projection (`project(ProductEvent)` returns all columns, nothing to exclude), the cdc_mirror destruction-oracle tier covers it for free, and erasure is free (subject key destruction renders `pae_actor_ref` unre-identifiable across live+mirror at once). This is exactly the privacy-correct-by-construction analytics incumbents can't offer for regulated B2B.
- **PII refusal at CAPTURE** applies the H-2/A1 default-deny discipline to the earliest boundary — a freeform string that could carry PII never reaches the ledger, so the CDC projection's structural guarantee is never even tested by a bad payload.
- **Kernel capture, web reads** — framework choke points emit at 0 vertical LOC; the operator read surface is a thin inherited page.

## 4 · Consequences

**Positive** — the analytics moat's foundation; feeds G17's activity factor and G6's experiment analysis; PII-safe by construction; verticals inherit emission at 0 LOC.

**Negative / accepted** — this is a SEED, not the analytics product. One thin Postgres-rollup funnel/retention read ships; arbitrary event exploration, paths, DAU/MAU, and ClickHouse activation are OUT OF SCOPE (design §7). `pae_event_name` is a bounded catalog (not arbitrary) — new events register an enum value + a `pae_props` schema, a deliberate governance cost.

**Neutral** — new `pae` + `paf` (rollup) abbrevs; `track/1` adds one best-effort write per instrumented action.

## 5 · Red paths

- **RP-A1 (AC-G12-2) PII refusal:** `track/1` refuses a payload whose prop classifies `:plaintext_pii` (dropped, logged, never persisted); bypassing the classifier FAILS the refusal test (a PII prop reaches `pae`). Anti-tautology: sabotage the classifier → the refusal test flips to fail → restore → green.
- **RP-A1 addendum — `entity_ref` refusal symmetry (B9 carry B7-P2-1, resolved 2026-07-14):** B7 shipped `entity_ref` with a SILENT SCRUB (a PII-shaped/vault-token ref persisted as `nil` while the rest of the row wrote) — asymmetric with the prop-value gate. Per the fail-closed ethos the scrub is replaced by REFUSAL: a PII-shaped, vault-token, or structured (map/list) `entity_ref` now refuses the WHOLE event (`{:error, :pii_rejected}`, logged), exactly like a PII-shaped prop value. A partial row that quietly drops the operator's stated linkage is a lie about what was captured; refusing loudly keeps capture honest and keeps the gates uniform.
- **AC-G12-3 token-blind:** `Cdc.Projection.project(ProductEvent)` returns all columns; a non-projected physical column on `pae` is a cdc_mirror oracle violation; `no_pii_columns` + `sink_schema` green.
- **AC-G12-5 erasure:** `pae_actor_ref` is a per-subject HMAC pseudonym; post-shred the subject is unrecoverable across live+mirror simultaneously.
