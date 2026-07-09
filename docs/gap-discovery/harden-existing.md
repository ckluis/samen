# Harden-What-Exists — depth gaps, residues & soft spots in the shipped Samen foundry

- **Date:** 2026-07-09
- **Scope:** a "harden what exists" pass — depth-vs-claim gaps, carried residues, deferred fixes,
  and test/verifier soft spots in the ALREADY-BUILT foundry (samen_core kernel, samen_web UI/scopes,
  driftwood + pawchart verticals, demo). NOT net-new modules.
- **Method:** read every gate report + risk-register-final + extraction-retro + ADR set FIRST (they
  index the debt), then spot-checked the code to confirm each residue still exists (several memory
  notes were stale — see "Already fixed" below). TODO/FIXME/HACK sweep across all `lib/`. Static
  reading only; no suites run; no files changed except this report.
- **Overall verdict:** **The kernel is as deep as the gates claim; the product surface is not.**
  The security substrate (crypto-shred, two-plane masking, append-only audit, aggregate floors,
  verifier gate + destruction oracle) is world-class-deep and the gate evidence is honest and
  non-vacuous. But the *SaaS-you-run* surface on top of it (the scopes' delivery adapters,
  list/search/pagination ergonomics, the primitives) is **demo-deep**: a real first tenant hits a
  wall in week one on outreach delivery, billing sync, list pagination, segment targeting, file
  upload, and API paging — every one an honestly-labeled stub/posture, none a breach.

---

## 0 · Already fixed since project memory was written (verified this pass — do NOT re-scope)

Memory carried these as open; the code shows them closed. Listed so downstream planning doesn't
re-open settled work:

- **"Detail-page header shows Workspace not tenant name"** — **FIXED.** `Samen.Web.CurrentOrg.name/2`
  (`samen_web/lib/samen/web/current_org.ex:186-203`) resolves the org's directory display name;
  `"Workspace"` is only the fallback when no org resolves. `crm/live.ex:6` documents the fix
  ("Driftwood shows 'Blue Ridge Logistics'…a bare mount shows 'Workspace'").
- **F4.2 (terminate live impersonation on suspension)** — **IMPLEMENTED** (with a bounded residue,
  see H-6). `Samen.Impersonation.Scope` (`impersonation/scope.ex:99-107`) calls
  `Suspension.suspended?/2` on every scope-continue; a suspended operator's live session dies on its
  NEXT request. Residue: it is next-request, not instantaneous revocation.
- **F4.3 (reason free-text = non-shreddable metadata)** — **PARTIALLY HARDENED** (residue, see H-7).
  `impersonation/sessions.ex:138-142` now runs `Samen.PiiReasonScan.check/2` and rejects a
  PII-shaped reason at the write boundary (`{:error, {:pii_shaped_reason, …}}`). Residue: best-effort
  shape match, explicitly "not a taint proof"; free-text PII in a benign-looking reason still lands
  and is non-shreddable.
- **F3 (operator/impersonate no-session 500)** — RETIRED at Gate 5 (fails closed, RP5b green).

---

## 1 · Ranked hardening backlog

Rank = (risk × joy-impact) ÷ effort. Each row: **claim · actual (cite) · delta · risk · joy · effort ·
fix-locus**. Fix-locus ∈ {kernel = samen_core · web = samen_web · vertical · operator-TODO}.

### H-1 · Marketing send delivery is a no-op stub — "sent" emails go nowhere
- **Claimed:** Marketing scope ships campaigns/sends as Oban jobs delivered via an adapter (scope
  table; ADR-011).
- **Actual:** `samen_core/lib/samen/scopes/marketing/send_worker.ex:27-47` — the default `perform/1`
  is a **stub** that marks the send delivered without dispatching anything; "In the demo/test
  environment the default stub is used." No real ESP adapter ships.
- **Delta:** A tenant runs a campaign, every send flips to `delivered`, zero email leaves the system.
- **Risk H · Joy H · Effort M · kernel** (behaviour + one real adapter + mount config). The seam is
  honest; the *default* silently-succeeds rather than fail-closed — consider making the unconfigured
  adapter mark `:blocked`/raise in non-test env so "delivered" can't lie.

### H-2 · CDC/aggregate PII classifier is a name+type heuristic — freeform strings pass as safe `:metadata`
- **Claimed:** "mask-unknown-by-default" classifier; the CDC projection "excludes plaintext PII BY
  CONSTRUCTION"; `no_pii_columns`/`pii_classify` verifiers are the correctness oracle (gate-6, N2).
- **Actual:** `Samen.Cdc.Projection.classify/3` (`cdc/projection.ex:140-146`) marks a column
  `:plaintext_pii` ONLY when `Context.plaintext_pii_type?(type)` is true (a TYPE check) or it is
  vault-routed; **everything else falls through `scalar_kind/1` and is bucketed `:metadata` → mirrored.**
  The `PiiClassify` verifier (`pii_classify.ex:290-301`) flags a `:string` column ONLY if its NAME
  matches `@pii_name_tokens` OR a seed value is PII-shaped — a benign-named freeform string
  (`drv_notes`, `owner_bio`, a dispatcher comment field) with NO seed value produces **empty reasons →
  not flagged, not vaulted, and mirrored into ClickHouse as `:metadata`.** "Mask-unknown-by-default"
  is true for unknown *types*, not for unknown *string contents*.
- **Delta:** The single biggest claim-vs-mechanism gap: the "provably non-PII" surface is a heuristic
  backstopped by a human `non_pii!` allowlist, not a proof. A tenant/operator who types a customer's
  name into a freeform note leaks it to the analytics tier, and no verifier fires.
- **Risk H · Joy M · Effort M · kernel.** Fix options: default freeform `:string` columns to
  `:plaintext_pii` (opt-OUT via `non_pii!`) instead of opt-in flagging; add a runtime value-shape
  scan on the CDC write path; or require every `:string` column to be explicitly classified (vault /
  non_pii! / bounded) or the build fails. This is the review's flagged `:provably_non_pii` soft spot,
  confirmed live.

### H-3 · No list pagination anywhere (CRM lists, API reads) — unbounded `read!`
- **Claimed:** CRM companies/contacts lists; "versioned public API" over freight (plan §I).
- **Actual:** CRM `Reads.companies/2` / `contacts/2` (`samen_web/lib/samen/web/crm/reads.ex`) run
  unbounded `.read!()` — no limit/offset/keyset. Driftwood + demo `json_api do` blocks
  (`driftwood/lib/driftwood/freight.ex:86,309`) declare NO `paginate`/`default_limit`, so AshJsonApi
  index routes return all rows.
- **Delta:** First tenant past a few hundred rows gets slow LiveView renders + a huge DOM, and an
  API client can pull the entire table in one unbounded GET.
- **Risk M · Joy H · Effort S/M · web + vertical.** Add keyset pagination to the CRM Reads + LiveView
  nav; add `default_limit`/`max_page_size` to the resource `json_api` blocks. Cheapest high-joy win.

### H-4 · `Send.:create_checked` hardcodes the `msp_suppression` table name — kernel/framework leak
- **Claimed:** the Marketing blueprint's suppression enforcement is scope-generic (mount under any
  abbrevs).
- **Actual:** `marketing/blueprint.ex:450-454` embeds a **literal SQL string** `SELECT 1 FROM
  msp_suppression WHERE msp_org_id=$1 AND msp_subscriber_id=$2 AND msp_active=true`. The `msp_` abbrev
  and table name are baked in. Driftwood only makes it work by threading its own host-abbrev-agnostic
  lookup at the vertical layer (`driftwood/lib/driftwood/marketing.ex:28`).
- **Delta:** A vertical mounting Marketing under different abbrevs (which the abbrev-registry design
  FORCES per ADR-006/N1) gets a suppression check that queries a non-existent table — either a crash
  or a silent suppression bypass, depending on how the query errors. This is the named kernel-fix
  candidate from memory, confirmed still present.
- **Risk M/H (suppression bypass is a compliance leak) · Joy M · Effort S · kernel.** Derive the
  suppression table/columns from the resource's declared abbrev (the registry knows it) instead of a
  literal string; add a red-path test that mounts under non-`msp` abbrevs.

### H-5 · Billing Stripe sync is a stub — local-only, no reconciliation
- **Claimed:** Billing ships a "Stripe-mirror shape"; hosts implement the sync behaviour (ADR-011).
- **Actual:** `samen_core/lib/samen/scopes/billing/sync_adapter.ex:107-163` — the default adapter
  records calls in process memory (`{:ok, %{stub: true, …}}`); no Stripe client, no webhook ingest,
  no pull-back.
- **Delta:** Platform billing shows MRR/invoices/dunning computed from local rows only; nothing
  reconciles against the real payment processor. Honest seam, but a foundry that "makes running a
  SaaS a joy" can't actually bill.
- **Risk M · Joy H · Effort M · kernel** (real adapter) **+ operator-TODO** (keys/webhooks).

### H-6 · Impersonation suspension is next-request, not immediate revocation
- **Claimed:** "suspending an operator terminates a live impersonation session" (F4.2).
- **Actual:** `impersonation/scope.ex:99-107` — the `suspended?/2` check runs on the next scope build;
  an in-flight request or a long-poll already inside the scope is not interrupted.
- **Delta:** Small window between suspension and effect. Documented honestly in the moduledoc; not a
  leak, an availability/latency-of-revocation posture.
- **Risk L · Joy L · Effort M · kernel.** Acceptable as-is; note for a "hard-revoke live sessions"
  enhancement if a real incident-response requirement lands.

### H-7 · Impersonation `reason` free-text remains a non-shreddable plaintext channel
- **Claimed:** all impersonation state is bounded tokens (shreddable).
- **Actual:** `impersonation/sessions.ex:37-50` — the operator-authored `reason` is plaintext in
  `imp_impersonation_session`; a `PiiReasonScan` best-effort shape guard rejects obvious email/SSN/
  phone shapes, but the moduledoc states it is "a best-effort belt, not a taint proof." A benign
  free-text reason naming a subject is not shreddable.
- **Delta:** A narrow, documented crypto-shred residue on one operator-plane column.
- **Risk L/M · Joy L · Effort M · kernel.** Options: hash/tokenize the reason, or add it to the
  destruction-oracle tier list as a known plaintext channel with a redaction-on-shred arm.

### H-8 · Vertical rollups bypass the cron worker (ADR-007) + Oban global concurrency (multi-node)
- **Claimed:** rollups refresh via `Samen.Jobs.RollupRefreshWorker` on a crontab; shred is
  single-concurrent.
- **Actual (rollups):** demo + driftwood materialize rollups with plain functions the test drives,
  carrying the identical "in production this would be an AshOban worker" comment
  (`demo/lib/demo/aggregate/rebuild.ex`, `driftwood/lib/driftwood/{broker_rollup,aggregate/rebuild}.ex`;
  extraction-retro A5). **Actual (Oban):** `Erasure.shred` unique/limit is per-node, NOT globally
  single-concurrent on a multi-node cluster — an open operator-TODO (gate-2-report.md:223: "Oban Pro
  global limits or a Postgres advisory lock").
- **Delta:** rollups are un-scheduled (a builder must wire cron themselves); on a multi-node deploy
  two nodes could run overlapping shreds. Both are honest, ADR'd/registered residues.
- **Risk M (multi-node shred race) · Joy M · Effort M · kernel/vertical + operator-TODO.** Execute
  ADR-007 spec bridge; add a Postgres advisory lock in `Erasure.shred` (cheap, node-agnostic) even
  before Oban Pro.

### H-9 · Support SLA breach is a silent state flip — no escalation/notification surface
- **Claimed:** SLA breach detection is a scheduled worker that marks tickets breached + emits an
  audit event (support blueprint).
- **Actual:** `samen_core/lib/samen/scopes/support/blueprint.ex` — the breach worker sets
  `breached=true` and writes an `aud_event`; there is NO notification, agent-UI alert, or escalation
  webhook. Nothing tells a human.
- **Delta:** The SLA timer is real but invisible; a breach is an internal boolean no one sees.
- **Risk L/M · Joy M · Effort M · web + kernel.** Wire the notification primitive on breach; surface
  an at-risk/breached badge in the Desk LiveView.

### H-10 · Primitives are scaffolds, not services — files (no storage), flags (no cache/rollout), search (index-only)
- **Claimed:** notifications · files · search · feature flags as scope primitives.
- **Actual:**
  - **Files** (`scopes/primitives/blueprint.ex`, `primitives.ex`): a metadata record holding
    `storage_key`; NO upload/download action, NO S3/GCS adapter. The host must populate `storage_key`
    itself.
  - **Feature flags:** Tier-0 config rows; NO `enabled?/2` helper, NO ETS cache, NO rollout-percentage
    evaluation — every gate check is a DB read the host writes by hand.
  - **Search:** a `SearchIndex` registry + a real `tsvector` column on the resource table
    (`primitives.ex:22-35`) — but NO `search/2` query helper; a host writes raw `to_tsquery` or Ash
    filters. (The PII-column-in-index red path IS enforced — that part is real.)
- **Delta:** These read as "batteries included" but are convention-only; a builder re-implements the
  actual service each time.
- **Risk L/M · Joy M · Effort M-L · kernel.** Provide thin real helpers (a `FileUpload` adapter
  behaviour with an S3 impl; `FeatureFlags.enabled?/2` with an ETS cache; a `Search.query/2` over the
  tsvector). None is load-bearing for security; all are joy multipliers.

### H-11 · Webhook payload storage-name guard drops legit catalog fields (A6 / over-strict)
- **Claimed:** webhooks carry the record's fields.
- **Actual:** `Samen.Webhook.Payload` guards on `~r/^[a-z]{3}_/`, dropping freight catalog names
  (`cdl_number`, `eld_provider`) that look like storage prefixes (extraction-retro A6; gate-6 caveat 4).
  Over-strict only — absent-by-omission, never a leak.
- **Delta:** A `driver.updated` webhook silently omits the CDL fields the tenant expects. (Note:
  webhooks DO have HMAC-SHA256 signing — `webhook/signer.ex` — and at-least-once delivery with DLQ;
  the signing gap flagged in early notes is NOT real.)
- **Risk L · Joy M · Effort S · kernel.** The precise fix is known (key on the declared abbrev, not
  a blanket regex); P1 backlog with a freight-catalog-name red path.

---

## 2 · Test / verifier soft spots (beyond H-2)

- **`PiiClassify` silent-pass on benign-named freeform strings (H-2)** — the core soft spot. The
  verifier is a heuristic whose miss mode is *silent* (empty reasons → pass), and the human `non_pii!`
  allowlist is the only backstop. Recommend inverting the default for freeform strings (opt-out).
- **CDC "excludes plaintext BY CONSTRUCTION" is construction-relative-to-the-classifier** — the
  claim inherits the H-2 heuristic's blind spot. The `assert_no_plaintext!` red path only fires on
  columns the classifier already calls `:plaintext_pii`; it cannot catch a mis-classified
  `:metadata` string.
- **Marketing send "delivered" is a tautological success** — the stub marks delivered
  unconditionally (H-1); any test asserting "send → delivered" is green against a no-op. A red path
  (adapter refuses → send NOT delivered) would make it non-vacuous.
- **Rollup workers are tested via plain functions, not the cron path (H-8)** — the scheduled-refresh
  guarantee has no test exercising the actual worker on vertical rollups.
- **CI determinism flake (gate-6 caveat 6)** — one of three full `ci.sh` runs exited non-zero with no
  reproducible cause; a spurious exit could mask a real one. P2: fixed seeds / serialized DB setup /
  a retry-once-then-surface-which-suite wrapper.

---

## 3 · Human-operator TODOs (list-only — not code fixes)

Real-cloud drills that are faithful local simulations + documented seams; do NOT attempt in code:
- **Real AWS-KMS + DynamoDB + S3 Object Lock** wiring — `kms/aws_kms_dynamo.ex` (stub delegates to
  InMemory; `# TODO` DescribeContinuousBackups / GetItem), `anchor/s3_object_lock.ex` (raises operator
  TODO when disabled). (R1/R9 residuals.)
- **Real Neon PITR drill + physical read replica** — `no_plaintext_pii/tiers/post_shred/{backup_pitr,
  db_content}.ex` record a documented seam. (R10 residual.)
- **Real ClickHouse / ClickPipes / `ecto_ch`** + a CI diff of the pipe allow-list against
  `Projection.project/1` — `cdc/click_house.ex:14-63`. (N2 residual.)
- **OTLP exporter + Prometheus** wiring — `tracer.ex`, `metrics.ex`, `wide_event/sinks/otlp.ex`.
- **Oban Pro global concurrency** for multi-node shred (or the advisory lock in H-8).
- **Stripe keys/webhooks** for H-5.
- **Commit the generator-appended abbrev-registry rows** per mount (N1 / ADR-006 ergonomic tax).

---

## 4 · What is genuinely world-class-deep (do not touch)

To keep the picture honest: the security kernel earns its gate claims. Confirmed non-vacuous this
pass by reading the mechanisms + their red-path/anti-tautology tests:
- Crypto-shred + key-outside-PITR (destruction oracle EXITs 0 with 15 attestations against a
  freshly-erased subject).
- Two-plane masking (`PiiResolution` by plane) — proven both directions live on the operator plane.
- Append-only hash-chained audit (`OperatorPlane.Migration` + DB trigger refusing UPDATE/DELETE, 10
  red-path tests + anti-tautology flip).
- Aggregate k-anon/l-diversity floors + the enforcing per-cohort read-count budget (collusion-aware
  unit). (The FORMAL ε-DP is honestly labeled posture-under-construction, N5 — not oversold.)
- The generator (`mix samen.gen.app`) producing a gate-green app correct-by-construction, and the
  LLM-grounding eval proving the gate catches an agent's five mistake classes (N4).

The delta is entirely on the **product surface**, not the substrate — which is exactly the shape
you'd expect from a kernel "extracted by the Rule of Three" before the SaaS-on-top was fully built.
