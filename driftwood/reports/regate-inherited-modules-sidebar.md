# Re-gate — Inherited CRM / Billing / Support modules (sidebar fix round)

**Date:** 2026-07-08
**Decision: GO** (mandatory fix closed; one nice-to-have display defect remains, non-gating)

## Scope of this re-gate

Prior round's single MANDATORY directive:

> Expose CRM, Billing, and Support in the `/broker` tenant-console sidebar (and add
> cross-module nav on each module page) so all three inherited modules are reachable
> from the sidebar without typing URLs.

Re-ran: coverage + masking-per-plane + full gate/suites + live boot-and-grep.

## Fix verification — Defect C2 CLOSED

The fix landed as a single shared component
`DriftwoodWeb.UIKit.module_nav/1` (`lib/driftwood_web/ui_kit.ex:170`) rendering four
`nav_group`s — Operations (freight 20%) + CRM + Billing + Support (inherited 80%) — with
every href threaded through the `?org=` selector. It is rendered by:

- `lib/driftwood_web/broker_live.ex:174` (the primary `/broker` tenant console)
- all six module pages: `crm_companies_live.ex:215`, `crm_contacts_live.ex:257`,
  `crm_pipeline_live.ex:221`, `billing_live.ex:313`, `billing_invoices_live.ex:284`,
  `billing_plans_live.ex:232`, `support_live.ex:325`, `support_ticket_live.ex:522`

So all three inherited modules are reachable from every page (including the default landing
console) without typing URLs, and cross-module nav works everywhere.

Regression test: `test/dogfood_walkthrough_test.exs` — *"the /broker tenant console sidebar
exposes CRM, Billing, AND Support (thesis in nav)"* — asserts the three group labels + seven
real module hrefs + the freight `Operations` group and `/broker?panel=loads` href in the
rendered `/broker` HTML.

## Live verification (PORT=4021, /healthz=200)

Seeded org `b1112d00-0000-4000-8000-000000000001` (Blue Ridge Logistics) via `mix driftwood.seed`.

- `/broker?org=…` sidebar text renders: `Operations / Dispatch board / Loads / Drivers /
  Settlements / CRM / Companies / Contacts / Pipeline / Billing / Customers / Invoices /
  Plans / Support / Tickets`. The CRM (`/crm/companies?org=…`), Billing (`/billing?org=…`),
  Support (`/support?org=…`) links each `is visible`.
- `/billing?org=…` (a module page) renders the SAME four groups — cross-module nav confirmed.

## Masking per plane — LOAD-BEARING — PASS

- Tenant plane (live): `/crm/contacts` renders "Amara Boone" / "Dana Whitfield" in the clear;
  `/billing` renders "Acme Manufacturing Inc" + `ap@acmemfg.example` in the clear; `/support`
  renders ticket rows. NO `vt_` / `vault:` / `Masked` token leaks on any page (grep-verified).
- Operator plane: covered by the module masking suites (CRM/Billing/Support) which assert
  `••••` present AND plaintext absent on `plane: :operator` — all pass inside the gate's
  step 17 default suite, and the `no_plaintext_pii` verifier (step 6) passes over the new
  `pii_fbc_*` / `pii_fsa_*` / `pii_fsm_body` surfaces.

## Gate + suites — PASS

- `driftwood/ci.sh` — **ALL 20 steps PASSED** (`==> driftwood CI gate: ALL PASSED`, exit 0):
  compile --warnings-as-errors, schema.dict.json drift, catalog_parity, prefixes, pii_reads,
  pii_classify, no_plaintext_pii, migrations, sink_schema, metric_labels,
  vault_declared_parity, tnt_catalog, tnt_boundary, api_contract v1, same_org_fk,
  no_pii_columns, aggregate_privacy, never_read_current, default suite, adversarial suite,
  T5.4 crypto-shred game-day, T5.5 PITR game-day + red-path probe.
  - The `pii_reads` `LAUNDERED` lines (render helpers on `/crm/contacts`, `/billing`,
    `/support/tickets`) are advisories on the sink-schema allow-list, not failures.
- App suites — all green:
  - samen_core: 842 passed (9 properties, 833 tests)
  - demo: 403 passed (17 properties, 386 tests), 52 excluded
  - driftwood: 110 passed (1 property, 109 tests), 4 excluded  [+5 vs prior 105]
  - pawchart: 19 passed
- `mix compile --warnings-as-errors` clean (test + dev).

## Remaining (non-gating)

Defect C1 (nice-to-have, still OPEN): `/crm/contacts` Email/Phone columns render no address.
`render_email/1` / `render_phone/1` in `lib/driftwood_web/crm_contacts_live.ex` (lines
215/228) match only `when is_list(...)`, but the tenant-plane resolver returns a JSON-string
shape, so the columns fall to `—`. Contact NAMES resolve correctly (they use
`render_full_name/1`, which `Jason.decode`s). Display-only, fails safe, no PII leak — does
not gate. Fix: mirror `render_full_name/1`'s `Jason.decode` in the two helpers.

## Files touched this round

- `docs/gate-inherited-modules.md` — updated to GO; C2 marked CLOSED, thesis clause (4)
  marked fully realized, suite counts refreshed, fix-tasks updated.
- (Fix code from the prior round already in tree: `lib/driftwood_web/ui_kit.ex` `module_nav/1`,
  all LiveViews calling it, `config/config.exs` mounting `Driftwood.Billing` + `Driftwood.Support`,
  `lib/driftwood/billing.ex`, `lib/driftwood/support.ex`, the router routes, and
  `test/dogfood_walkthrough_test.exs` regression test.)
