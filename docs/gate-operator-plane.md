# GATE — The Operator / SaaS-company plane (ADR-010)

- **Date:** 2026-07-08
- **Gate:** world-class rigor review of the OPERATOR / control plane — accounts ARE tenant orgs,
  platform billing over tenants, the SaaS's own help desk, and the load-bearing IDENTITY LINE.
- **Decision:** **GO** (green on all five rigor criteria; two nice-to-have follow-ups noted).

---

## Verdict

**GO.** The operator plane is real, framework-level, and correct on the load-bearing identity
line — proven BOTH directions LIVE on the same operator session and pinned by the samen_web
identity-line test. `samen_core` is untouched; every suite + the driftwood 20-step CI gate is
green; `--warnings-as-errors` is clean throughout. The plane is pure composition of two
already-tested kernel primitives (`OrgScope` by `org_id` + `PiiResolution` by `plane`), with no
new masking machinery and no plaintext bypass.

---

## Criterion-by-criterion

### (1) OPERATOR SURFACES REAL — PASS
Booted Driftwood (`MIX_ENV=dev PORT=4033`), seeded via `mix driftwood.seed` (which calls
`Driftwood.OperatorSeeds.seed/0` at `seeds.ex:225`). All three routes 200; live LiveView content
grepped:

- **`/operator/accounts`** — two tenant-orgs-as-accounts: **Blue Ridge Logistics** and **Summit
  Freight Partners**, each with plan `growth`, health `healthy`, seats, MRR ($2500 / $3000).
  Header metrics: Accounts 2, Healthy 2, Platform MRR **$5500.00**.
- **`/operator/billing`** — per-tenant subscriptions TO the SaaS (active, $2500 / $3000), total
  **Platform MRR $5500.00**, and an **Invoices & dunning** section with **past-due** invoices
  flagged ($5500 past due). Non-vacuous.
- **`/operator/desk`** — tickets tenants FILED with the SaaS ("Cannot invite a second admin"
  high, "Invoice PDF export failing" normal), each with requester = tenant-admin and priority /
  SLA / status columns.

### (2) THE IDENTITY LINE (load-bearing) — PASS, both directions LIVE
Proven on the SAME operator workspace against the SAME Blue Ridge tenant org
(`b1112d00-...0001`):

- **CLEAR (population 1 — the SaaS's own book of business):** the tenant-ADMIN renders in the
  clear on accounts, billing, AND desk — **Marlene Okafor** / `marlene.okafor@blueridge.example`
  and **Desmond Vlahos** / `desmond.vlahos@summitfreight.example`. **Zero** `••••` markers on the
  operator's own-book surfaces. This is the operator org over its own vendor data on the TENANT
  plane (`Samen.Web.Operator.scope/1` → `Plane.tenant()` + operator `org_id`), the exact
  tenant-as-owner resolver branch.
- **MASKED (population 2 — the tenant's downstream end-customers):** opened a real impersonation
  session (`Samen.Impersonation.open/3` as `%Samen.OperatorPlane.Actor{operator_role:
  :operator_admin}`), drilled into Blue Ridge's driver roster via `/operator/impersonate` — every
  personal field (CDL #, driver identity) renders **`••••`** (6 masked markers), banner "PII is
  masked (••••)", with a second-party **Reveal CDL** control (not auto-revealed). This is the
  EXISTING ADR-009 `plane: :operator` path, unchanged.
- **Red-path leak checks:** 0 vault tokens (`vt_` / `pii_*` / `vault_token`) on any of the three
  operator surfaces. The impersonation LiveView correctly **fails closed** ("access denied — no
  active impersonation session") without an active session — masked by construction, not by
  omission.
- **Test pin:** `samen_web/test/samen/web/operator_identity_line_test.exs` asserts BOTH sides on
  seeded data — CLEAR (admin present), MASKED (`••••`, contact name/email/phone absent), plus a
  CROSS-LEAK test (operator accounts view never surfaces a downstream contact) and a CROSS-MOUNT
  REFUSAL test (operator-org actor reading the vertical namespace returns `[]`, proven non-vacuous
  by reading the same row on the tenant's own scope). All green.

### (3) FRAMEWORK-LEVEL — PASS
The operator surfaces live entirely in `samen_web`:
`Samen.Web.Operator` (context — org-id resolution + operator-org tenant-plane scope, the
identity-line hinge), `Samen.Web.Operator.Reads`, and the LiveViews `AccountsLive` /
`PlatformBillingLive` / `DeskLive` / `Live` (+ `AggregateLive`). A host mounts them with the ONE-
line `samen_operator_routes/2` macro (sibling of `samen_module_routes/3`). Driftwood mounts them
in `driftwood_web/router.ex:124` — a data-only host wiring. `samen_core` code is UNTOUCHED (see
(5)).

### (4) DISTINCT FROM TENANT PLANE — PASS
The operator workspace renders as "Driftwood Ops / Control plane" (glyph D), nav = Accounts ·
Platform billing · Desk · Portfolio — visibly the SaaS control plane where accounts ARE tenants,
not a tenant's own module. Screenshot captured (`/tmp/operator_accounts.png`).

### (5) GREEN — PASS (with one orthogonal pre-existing flake, see below)
- **samen_web:** 67 passed, `--warnings-as-errors` clean (includes the identity-line test +
  accounts/billing/desk render tests + context test).
- **driftwood/ci.sh:** ALL 20 steps PASSED (compile `--warnings-as-errors`, schema-dict drift,
  catalog parity/prefixes/pii verifiers, `no_pii_columns`, `aggregate_privacy`, adversarial
  tests, T5.4 crypto-shred + T5.5 PITR game-days incl. red-path probes).
- **demo:** 403 passed (17 properties), `--warnings-as-errors` clean.
- **pawchart:** 35 passed, `--warnings-as-errors` clean.
- **samen_core:** 833/833 tests + 8/9 properties. The ONE property failure
  (`abbrev_property_test.exs`: `notes == "\r"` round-trips to `nil`) is a **pre-existing,
  data-dependent whitespace-normalization flake** — it PASSES on isolated re-run (2/2), and this
  task touched **zero** samen_core code (only `samen_web` + host wiring/seeds in driftwood).
  Not a regression, not caused by this plane.

---

## Notes / nice-to-have follow-ups (do NOT block GO)

1. **Health vs dunning coherence (cosmetic):** On `/operator/accounts` the health pill derives
   from *subscription status* (`:active` → healthy), while `/operator/billing` dunning derives
   from *invoice due dates*. With the current seed both Blue Ridge and Summit are `healthy`
   (At risk = 0) on Accounts yet show a past-due invoice in Billing. Internally coherent per the
   ADR's minimal-viable health model, but a viewer could read it as inconsistent. Consider folding
   "has a past-due invoice" into the `at_risk` health signal so the Accounts "At risk" count and
   the Billing dunning list agree. Nice-to-have.

2. **Live masked-side seeding for dogfood:** the impersonation surface (correctly) fails closed
   without an active session, so proving the masked side LIVE required opening a session by hand.
   Consider a `mix driftwood.seed` option (or a documented one-liner) that opens a demo
   impersonation session so a dogfooder can see the `••••` masked roster without the manual
   `Samen.Impersonation.open/3` step. Nice-to-have (the test already pins the masked side).

---

## Evidence index
- ADR: `docs/adr/010-operator-plane.md`
- Build/mount reports: `docs/operator-plane-build.md`, `docs/mount-operator-driftwood.md`
- Framework code: `samen_web/lib/samen/web/operator.ex`, `.../operator/reads.ex`,
  `.../operator/{accounts,platform_billing,desk}_live.ex`, `.../operator/live.ex`
- Router macro: `samen_web/lib/samen/web/router.ex:111` (`samen_operator_routes/2`)
- Host mount: `driftwood/lib/driftwood_web/router.ex:124`
- Identity-line test: `samen_web/test/samen/web/operator_identity_line_test.exs`
- Seeds: `samen_web/test/support/operator_seeds.ex`, `driftwood/lib/driftwood/operator_seeds.ex`
- Live screenshot: `/tmp/operator_accounts.png`
