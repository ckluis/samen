# Gate — CRM enrichment (ADR-011)

**Date:** 2026-07-08 (RE-GATED after the fix round)
**Gate:** framework CRM enrichment — contact/company detail, activity timeline, outreach
(Marketing mount), prospecting, social — landed in `samen_web`, proven by Driftwood + PawChart.
**Decision:** **GO** — the mandatory cold-start blocker is FIXED and verified (200 cold on a fresh
BEAM, both verticals), the regression test is in CI, and all nice-to-haves (PawChart marketing
mount + activity/marketing seeds) shipped. All suites + all four ci.sh gates are green.

---

## RE-GATE — verification of the fix round (this pass)

### Mandatory fix 1 — cold-start 500 on `/marketing/campaigns` + `/marketing/segments` → FIXED
`Samen.Web.Mount` (`mount.ex`) now materializes the bounded, framework-owned label-key set as
**compile-time atom literals** (`@label_keys`, lines 148-157) and resolves deserialized label keys
through a `@label_key_strings` whitelist in `safe_label_key/1` (lines 169-174) BEFORE falling back
to `String.to_existing_atom/1` for anything outside the set (rejects cookie-injected garbage). The
atoms — `:crm_namespace` et al. — are therefore resident in ANY deserializing process regardless of
which LiveView loaded first, so `mount/3 → assign_mount → from_session → atomize_labels` cannot
raise on a cold BEAM. `scope_kind/1` is likewise an explicit map (lines 109-115), not
`to_existing_atom`.

**Live proof (the definitive check).** Booted a FRESH Driftwood BEAM (`PORT=4034`) and hit the
marketing pages in the exact order that used to 500 — campaigns/segments FIRST, before `LeadsLive`
ever loaded:
```
COLD  /marketing/campaigns  -> 200   (was 500)
      /marketing/segments   -> 200   (was 500)
      /marketing/leads      -> 200
```
Content is real, not an error page: `mkt-campaigns`, `campaign-row`, `Campaigns & sequences`, and
the `consent + suppression enforced on every send` plane note. Reproduced on PawChart too (below).

### Mandatory fix 2 — session-round-trip regression test → PRESENT + GREEN
`test/samen/web/marketing_session_roundtrip_test.exs` builds a session with `Mount.to_session/1`
carrying `crm_namespace: <Host>.Crm` (exactly how the router's `live_session` ships it) and calls
`CampaignsLive.mount/3`, `SegmentsLive.mount/3`, and `LeadsLive.mount/3` — the EXACT path the
`render_live/3` harness bypassed — asserting `{:ok, socket}` (a 200) and that the `crm_namespace`
label survived to the atom. It also asserts the `Mount`-level invariant: `from_session/1` resolves
EVERY `Mount.label_keys()` key through the whitelist. This closes both C1 and C2 for the marketing
scope (the crashing path is now driven directly, so the load-order atom bug can never be a green-
suite/red-production regression again).

### Nice-to-have (C3) — PawChart marketing mount + activity/marketing seeds → SHIPPED
- PawChart now mounts `:marketing` (`pawchart_web/router.ex:89`,
  `samen_module_routes(:marketing, PawChart.Marketing, …, labels: %{crm_namespace: PawChart.Crm})`)
  with ZERO PawChart LiveView code.
- `pawchart/lib/pawchart/seeds.ex` now seeds **CRM activities** (`seed_crm_activities/2`, 3 per
  contact over clinic-flavored templates → `PawChart.Crm.Activity`) AND a full **marketing set**
  (`seed_marketing/1`: template + segment + 6 subscribers + 1 suppression + campaign). DB verified:
  `vce_activity: 18`, `vmc_campaign: 1`, `vmg_segment: 1`, `vms_subscriber: 6`, `vmp_suppression: 1`,
  `vmt_template: 1`.
- **Live proof on the second vertical** (fresh PawChart BEAM, `PORT=4038`): marketing pages 200
  COLD (campaigns/segments first), branded "Happy Paws Clinic", with real `campaign-row`; the
  inherited contact timeline renders **3 real `tl-entry` rows** (no `tl-empty` — the C3 finding is
  resolved) with clinic subjects (onboarding packet / Partnership review / voicemail), the composer,
  and no masking bullets / `vt_` / `pii_` leak on the tenant plane. The outreach + consent + timeline
  inheritance is now PROVEN, not just asserted, on the clinic.

---

## What is verified (evidence, this pass)

### 1 · REAL CRM (not a rolodex) — booted Driftwood, live
- `/crm/contacts/:id?tab=activity` → **200**, screenshot confirms: header PII **in the clear**
  (name `Amara Boone`, email `amara.boone@riverbendpaper.example`, phone `+1-828-555-0153`), the
  **lifecycle pill** (`MQL`), the plane note `name / email / phone via PiiResolution · your org in
  the clear`, the **three tabs** (Overview/Activity/Deals), a working **log-activity composer**
  (`id="log-activity-form"` — type dropdown + subject + details + "Log activity"), and a real
  timeline entry (`EMAIL · Rate confirmation sent · completed`). `tl-rail` present, `tl-empty`
  absent, 3 `tl-entry` rows.
- `/crm/companies/:id` → **200 cold**.
- Cold-start CRM detail is clean (`contact_detail=200`, `company_detail=200` on a fresh BEAM).
- No masking bullets, no `vt_`/`pii_` token leak on the tenant plane (grep = 0).

### 2 · FRAMEWORK-LEVEL + REUSE — both verticals inherit it live
- ALL new code lives in `samen_web` (`Samen.UI.{timeline,lifecycle_pill,social_links}`,
  `Samen.Web.CRM.{ContactLive,CompanyLive}`, `Samen.Web.Marketing.*`, additive `Reads`). Hosts
  mount via `samen_module_routes/3`; PawChart renders the identical detail page + marketing surface
  with zero host LiveView code.
- **`samen_core` UNTOUCHED**: kernel suite **842 passed (833 tests, 9 properties)** under `--seed 0`.
  Only sanctioned change remains the append-only abbrev-registry rows.

### 3 · MASKING + CONSENT (load-bearing) — proven in tests + live
- `test/samen/web/crm_detail_render_test.exs`: OPERATOR plane on the SAME `ContactLive` asserts
  `••••`, **refutes** name/email/phone, **refutes** `vt_`/`pii_`, and **refutes** `log-activity-form`
  (composer hidden). `Reads.get_contact` returns a clear binary on tenant / `%Samen.Masked{}` on
  operator. A cross-org `person_id` FK is REFUSED by the kernel (`{:error, _}`).
- **Consent/suppression red path**: `test/samen/web/marketing_render_test.exs` proves
  `Reads.enqueue_send/3` REFUSES a suppressed subscriber (`{:error, :suppressed}`, no send row, no
  Oban job), the green path creates a send row, and a mixed batch surfaces per-recipient refusal.
  This framework-level fail-closed check sits AROUND the known kernel `send_checked` fail-open
  (hardcoded `msp_suppression`) — correct, without touching the kernel.

### 4 · GREEN — all suites + all four ci.sh gates
- **samen_web:** `107 passed` (was 102; +5 round-trip regression tests), compile
  `--warnings-as-errors` clean.
- **samen_core:** `842 passed (833 tests)` under `--seed 0`, untouched.
- **pawchart:** `35 passed`; **pawchart ci.sh:** ALL 17 steps PASSED (catalog_parity / prefixes /
  pii_reads / migrations / same_org_fk over the NEW marketing tables + microchip anti-tautology probe).
- **demo:** `403 passed (386 tests)`; **demo ci.sh:** ALL PASSED (9 verifiers).
- **driftwood ci.sh:** ALL 20 steps PASSED — the verifier gate over the marketing tables
  (catalog_parity / prefixes / pii_reads / same_org_fk / migrations), the 89-test suite, both PITR
  game-days, and the red-path probe (fails closed).

---

## Remaining (non-blocking)

- **C2 breadth (nice-to-have):** the session-round-trip test now covers the marketing scope; the
  other framework scopes (CRM/Billing/Support/Operator) still exercise only `load/*` via
  `render_live/3`, not `mount/3`. The load-bearing `from_session` invariant is proven at the
  `Mount` level for the full bounded label-key set, so a new label can't 500 in production; adding a
  per-scope `mount/3` smoke would be belt-and-suspenders. Not a blocker.
- **C4 (nice-to-have):** the one order-dependent flaky samen_core concurrency test — not observed
  this pass (`842 passed` under `--seed 0`); worth making deterministic but does not gate. Kernel is
  untouched, so nothing new introduced it.

---

## Verdict

The CRM enrichment is world-class and every enrichment lands in `samen_web` so both verticals
inherit it: real tabbed detail pages, a populated activity timeline with a working composer, a
lifecycle pill + social links, an outreach surface (campaigns/segments/leads) with a fail-closed
consent/suppression red path, airtight PII masking (operator `••••`, no token leak, composer hidden
— proven live + in a load-bearing test), and true framework inheritance (PawChart renders the
identical detail + marketing pages with zero host code). The kernel stayed untouched. The one prior
blocker — the cold-start 500 on the outreach pages — is FIXED (load-order-independent label
atomization) and locked by a CI regression test, verified 200 COLD on fresh BEAMs of BOTH verticals.
All nice-to-haves shipped. **GO.**
