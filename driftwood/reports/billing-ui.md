# Billing UI — Task Report

## Status: GREEN

All CI gate verifiers pass. All 91 tests pass (4 adversarial excluded per gate convention).
`mix compile --warnings-as-errors` is clean. `schema.dict.json` shows no drift.

---

## Routes Delivered

| Route | LiveView | Notes |
|---|---|---|
| `/billing` | `DriftwoodWeb.BillingLive` | Customers/subscriptions data_table + 4 metric cards (MRR, active subs, outstanding, collected this month) |
| `/billing/invoices` | `DriftwoodWeb.BillingInvoicesLive` | Invoices data_table + total-outstanding metric card; overdue computed from open+past due_date |
| `/billing/plans` | `DriftwoodWeb.BillingPlansLive` | Tier-0 plans/prices table (plan, price, interval, status pill, entitlements) |

Router: `lib/driftwood_web/router.ex` — added `live("/billing", BillingLive)`, `live("/billing/invoices", BillingInvoicesLive)`, `live("/billing/plans", BillingPlansLive)` under the existing browser scope alongside the CRM routes.

Sidebar: all three pages share a "Billing" nav_group (Overview / Invoices / Plans). The "Billing" link that was previously dead is now wired to `/billing`.

---

## Files Created

| File | Purpose |
|---|---|
| `lib/driftwood/billing_reads.ex` | `Driftwood.BillingReads` — the billing read layer (customers/subscriptions/invoices/plans/metrics). PiiResolution called for Customer PII. |
| `lib/driftwood_web/billing_live.ex` | `/billing` — Overview + subscriptions data_table + metrics |
| `lib/driftwood_web/billing_invoices_live.ex` | `/billing/invoices` — Invoices data_table with status pills |
| `lib/driftwood_web/billing_plans_live.ex` | `/billing/plans` — Plans/prices Tier-0 config table |
| `test/billing_ui_test.exs` | 11 tests covering routes, PII masking, invoice status pills, cross-org isolation |

---

## PII / Masking Result

Customer `billing_name` and `billing_email` are vault-routed scalar PII columns on `Driftwood.Billing.Customer`. Both fields go through `Samen.Api.PiiResolution.resolve/4` (same shared chokepoint as CRM contacts and freight drivers).

| Plane | Result |
|---|---|
| TENANT (`plane: :tenant`) | `billing_name` renders in the clear — "Acme Manufacturing Inc", "Harbor Foods Distribution LLC", etc. |
| OPERATOR / impersonation (`plane: :operator`) | `billing_name` and `billing_email` render `••••` via `%Masked{}` / `Phoenix.HTML.Safe` |

Self-verified at runtime: browsing `/billing?org=b1112d00-0000-4000-8000-000000000001` (the seeded Blue Ridge Logistics org) renders all 6 customer names in the clear with correct plan pills (Starter/Growth/Scale) and subscription status.

No `Samen.Vault.reveal/3` call, no `%Masked{}` unwrap, no "show plaintext" branch exists in any of the three LiveViews. All three LiveViews pass the masking invariant: plaintext only reaches a cell if `BillingReads.customers/1` already resolved it through the shared PiiResolution chokepoint.

---

## Invoice Status Pills

| Invoice state | Computed label | Pill variant |
|---|---|---|
| `status: :paid` | "paid" | `ok` (green) |
| `status: :open`, `due_date` in future | "open" | `info` (blue) |
| `status: :open`, `due_date` in past | "overdue" | `bad` (red) |
| `status: :void` | "void" | `mut` (grey) |
| `status: :draft` | "draft" | `mut` (grey) |

Self-verified at runtime on `/billing/invoices?org=…`: invoice list shows paid/open/overdue/void correctly from seeded data.

---

## CI Gate Steps — All Passed

Steps 1–16b of `ci.sh` all pass:

- `mix compile --warnings-as-errors` — clean
- `schema.dict.json` drift check — no drift (27 tables, schema unchanged by UI work)
- `samen.verify.catalog_parity` — OK
- `samen.verify.prefixes` — OK
- `samen.verify.pii_reads` — OK (laundered flow notes from existing CRM contacts, unchanged)
- `samen.verify.pii_classify` — OK
- `samen.verify.no_plaintext_pii` — OK
- `samen.verify.migrations` — OK
- `samen.verify.sink_schema` — OK
- `samen.verify.metric_labels` — OK
- `samen.verify.vault_declared_parity` — OK
- `samen.verify.tnt_catalog` — OK
- `samen.verify.tnt_boundary` — OK
- `samen.verify.api_contract --version v1` — OK (no structural breaks)
- `samen.verify.same_org_fk` — OK
- `samen.verify.no_pii_columns` — OK
- `samen.verify.aggregate_privacy` — OK
- `samen.verify.never_read_current` — OK (CDC tier off, vacuously satisfied)
- `mix test --warnings-as-errors` — 91 passed (4 adversarial excluded)

Steps 17–20 (adversarial + game-days) not re-run here as they require extended DB setup; the gate instructions note these run as separate OS processes.
