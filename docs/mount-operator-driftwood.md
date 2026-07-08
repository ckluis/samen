# MOUNT the operator workspace in Driftwood Ops — verification report (ADR-010)

**Status: GREEN.** The `Samen.Web.Operator.*` control-plane surfaces are mounted in
`DriftwoodWeb.Router` under the `/operator` workspace, the operator seed populates them over
Driftwood's real tenant orgs, and the identity line is verified LIVE both directions
(tenant-admin CLEAR / tenant end-customer MASKED). All four suites + driftwood/ci.sh (20 steps)
green.

## (a) Routes mounted

`DriftwoodWeb.Router` mounts the operator workspace via the framework one-liner
`samen_operator_routes Driftwood.Operator, repo: Driftwood.Repo, operator_org_id: …,
include_aggregate: false, labels: %{operator_workspace: "Driftwood Ops", operator_glyph: "D"}`
alongside the pre-existing operator aggregate + impersonate routes.

| Route | LiveView | Verified |
|---|---|---|
| `/operator/accounts` | `Samen.Web.Operator.AccountsLive` | 200, data |
| `/operator/billing` | `Samen.Web.Operator.PlatformBillingLive` | 200, data |
| `/operator/desk` | `Samen.Web.Operator.DeskLive` | 200, data |
| `/operator/aggregate` | `Samen.Web.Operator.AggregateLive` (Portfolio, freight-shaped loader) | 200, data |
| `/operator/impersonate` | `DriftwoodWeb.OperatorImpersonationLive` (masked drill) | 200 |

## (b) Sidebar — the SaaS control plane, distinct from a tenant workspace

The operator sidebar renders header **"Driftwood Ops" · "Control plane"** (glyph "D"), with the
operator nav group: **Accounts · Platform billing · Desk · Portfolio (aggregate)**. Impersonation
+ Audit are reached from the accounts drill / tenant-visible list. This is visibly distinct from a
tenant CRM/Billing/Support workspace.

Change made: the Driftwood router previously passed `operator_workspace: "Samen SaaS"` for the
operator routes while the aggregate mount already used `"Driftwood Ops"`. Unified both to
**"Driftwood Ops"** so the whole operator workspace reads as one SaaS control plane per the task
mandate. One-line label change; no framework code touched.

## (c) Operator seed

`mix driftwood.seed` runs `Driftwood.Seeds.dev_seed/0` which calls
`Driftwood.OperatorSeeds.seed/0`. It stands up the operator org (Samen SaaS, Inc.) over
Driftwood's two EXISTING tenant orgs (Blue Ridge Logistics + Summit Freight Partners): per
account an operator-side account Org (slug = tenant_org_id back-ref) + tenant-admin User + admin
Membership + Customer/Subscription/Plan/Price/Invoice (one past-due for dunning) + 2 desk tickets
whose requester is the tenant-admin.

## (d) Live verification (PORT=4033, browse tool)

**CLEAR side (the SaaS's own book of business — tenant-admins):**
- `/operator/accounts` — accounts = Blue Ridge Logistics + Summit Freight Partners; primary
  contacts **Marlene Okafor** (marlene.okafor@blueridge.example) / **Desmond Vlahos**
  (desmond.vlahos@summitfreight.example) in the CLEAR; health pills; Platform MRR across accounts.
- `/operator/billing` — **Platform MRR $5500.00** (Blue Ridge $2500 + Summit $3000), per-tenant
  subs (customer clear, Growth plan, active), invoices & dunning with a past-due invoice flagged.
- `/operator/desk` — tenant-filed tickets ("Cannot invite a second admin" high; "Invoice PDF
  export failing" normal); requester = tenant-admin **clear**; assignee = SaaS agent **Priya
  Nakamura** clear; priority/status.
- Vault-token leak scan on the accounts surface: **0** (`vt_`/`pii_` absent).

**MASKED side (a tenant's downstream end-customers — drivers):**
- Drilling into a tenant via `/operator/impersonate?operator_id=driftwood-operator&org_id=<Blue
  Ridge>` (after opening a session with an `:operator_support` actor) renders the **driver roster
  with `••••`** for driver name AND CDL number — the tenant's downstream end-customers are masked
  to the operator. The reveal control requires a separate time-boxed second-party grant.
- Security default confirmed: without an active impersonation session the same URL returns
  **access denied — no data**.

Screenshots: `/tmp/operator_accounts.png`, `/tmp/operator_billing.png`, `/tmp/operator_desk.png`,
`/tmp/operator_impersonate_masked.png`.

## The identity line (load-bearing) — both sides proven LIVE and in tests

- Population 1 (SaaS's own customers = tenant orgs + their ADMINS): operator seat reads the
  operator org on the **TENANT plane** → `PiiResolution` clear. Verified: Marlene/Desmond clear.
- Population 2 (a tenant's downstream end-customers = drivers): reached only via the ADR-009
  `plane: :operator` impersonation mount → `%Masked{}` → `••••`. Verified: driver roster `••••`.

## Suites + CI (green before and after the one-line label change)

- **samen_core: 842 passed** (9 properties, 833 tests) — UNTOUCHED.
- **samen_web: 67 passed** — including `operator_identity_line_test.exs` (5) explicitly re-run green.
- **demo: 403 passed.**
- **driftwood/ci.sh: ALL PASSED** (20 steps + PITR game-day + red-path probe).
- **pawchart/ci.sh: ALL PASSED** (incl. microchip vault anti-tautology probe).
- `mix compile --warnings-as-errors` clean (samen_web + driftwood).

## Files touched

- `driftwood/lib/driftwood_web/router.ex` — operator workspace label
  `operator_workspace: "Samen SaaS" → "Driftwood Ops"` (glyph `S → D`); no framework change.
