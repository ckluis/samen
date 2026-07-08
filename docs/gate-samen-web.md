# GATE — samen_web framework extraction (ADR-009)

**Verdict: GO.** The inherited-80% product UI (component kit + CRM/Billing/Support
LiveViews + two-plane masking) is genuinely FRAMEWORK-level in the new `samen_web` lib.
Both driftwood and pawchart MOUNT the same modules; the driftwood-local copies are
DELETED; samen_core is UNTOUCHED and still web-dep-free (842 green). PawChart inherits
all three modules for ~zero code. Two-plane masking is proven live on BOTH verticals and
by construction (single PiiResolution chokepoint, no plaintext bypass). All CI gates green.

Date: 2026-07-08 · Reviewer: framework gate (world-class rigor)

---

## (1) FRAMEWORK-LEVEL — PASS

- **The lib exists and is real.** `/Users/clank/Desktop/projects/samen/samen_web`
  carries `Samen.UI` (`lib/samen/ui.ex`), the CRM/Billing/Support/Operator LiveViews
  (`lib/samen/web/{crm,billing,support,operator}/*.ex`), their reads
  (`lib/samen/web/{crm,billing,support}/reads.ex`), the parameterization seam
  (`Samen.Web.{Mount,Plane,Router,Live}`), and the CSS (`priv/static/assets/samen_ui.css`).
- **Driftwood-local copies DELETED (verified by `find`, all return nothing = GONE):**
  `ui_kit.ex`, `ui_kit_live.ex`, `crm_companies_live.ex`, `crm_contacts_live.ex`,
  `crm_pipeline_live.ex`, `billing_live.ex`, `billing_invoices_live.ex`,
  `billing_plans_live.ex`, `support_live.ex`, `support_ticket_live.ex`,
  `operator_dashboard_live.ex`, and the crm/billing/support `_reads.ex`. No lingering
  `DriftwoodWeb.UIKit` / `Driftwood.CrmReads` / `Driftwood.BillingReads` /
  `Driftwood.SupportReads` references remain. (The remaining `driftwood/lib/driftwood/reads.ex`
  is the FREIGHT read layer — the vertical 20%, correctly still local.)
- **Both hosts MOUNT the same modules.** `DriftwoodWeb.Router` and `PawChartWeb.Router`
  both `import Samen.Web.Router` and call `samen_module_routes(:crm|:billing|:support, ...)`.
  The mounted routes resolve to the framework's own `Samen.Web.*` LiveViews (bare `scope "/"`).
- **Single CSS source.** `driftwood_web/endpoint.ex` serves from
  `{:samen_web, "priv/static/assets"}` (resolved via `:code.priv_dir(:samen_web)`) — not a
  driftwood-local copy. Live: `GET /assets/samen_ui.css` → 200, 17179 bytes.
- **samen_core UNTOUCHED.** No web dep added: `samen_core/mix.exs` has NO `phoenix` /
  `phoenix_live_view` (only the PRE-EXISTING `phoenix_html` for the `%Masked{}` `Safe`
  protocol — that predates this workflow and is unchanged). The web deps
  (`phoenix`/`phoenix_live_view`/`phoenix_html`) live only in `samen_web/mix.exs`. The only
  change under `samen_core/` is 21 append-only `Samen.WebTest.*` rows in
  `priv/abbrev_registry.json` (a data file the ADR sanctions hosts appending to). **842 tests
  pass `--seed 0 --warnings-as-errors`.**

## (2) REUSE PROOF — PASS

- PawChart authored **0** CRM/Billing/Support LiveView modules (`find` = 0).
- PawChart inherits **3,284 lines** of framework UI (LiveViews + reads + `Samen.UI` +
  ui-kit catalog) via **3 `samen_module_routes` calls** in its router.
- Live: all 8 inherited pages return HTTP 200 over PawChart's data
  (`/crm/{companies,contacts,pipeline}`, `/billing`, `/billing/{invoices,plans}`,
  `/support`), branded "Happy Paws Clinic". The reuse ratio claim (~99.9% reduction vs a
  ~2,090-line hand-build) holds. **The thesis holds: the SAME code renders both verticals.**

## (3) TWO-PLANE + MASKING (load-bearing) — PASS

Proven three ways, all non-vacuous:

- **Live IEx over REAL data, both verticals, SAME `Samen.Web.CRM.Reads.contacts/2`:**
  - Driftwood (12 contacts): tenant plane `full_name`=`CLEAR:Amara Boone`, `emails`=CLEAR;
    operator plane `full_name`/`emails`/`phones` = `%Samen.Masked{}` (••••). Same 12 rows.
  - PawChart (6 contacts): tenant `full_name`=`CLEAR:Dr. Carlos Mendez`; operator = MASKED.
- **Live HTTP render (driftwood `/crm/contacts` tenant plane):** 12 contact-rows, real
  emails in the clear (amara.boone@…, cole.barrett@…), **0** masked bullets, "your org in
  the clear" note.
- **Framework render tests (host-independent, 43 pass):** tenant clear vs operator •••• on
  CRM contacts, Billing invoices/overview, Support ticket-body + agent-details; each asserts
  the masked sentinel present AND the plaintext ABSENT AND no `vt_`/`pii_` vault token leaks.
- **By construction — no plaintext bypass.** Grep of `samen_web/lib`: the only `Vault.reveal`
  occurrences are moduledoc lines asserting the module NEVER calls it. Every PII read routes
  through the single `Samen.Api.PiiResolution.resolve/4` chokepoint (CRM/Billing/Support). No
  LiveView has an "if operator show plaintext" branch. `Samen.Web.Plane` produces only the
  actor; the resolver returns `%Masked{}` on the operator plane; `%Masked{}` renders •••• via
  `Phoenix.HTML.Safe`. Resolver failure keeps `%Masked{}` (fail-safe, no downgrade).

## (4) GREEN — PASS (all suites + all gates)

| Gate | Result |
|---|---|
| samen_core `mix test --seed 0 --warnings-as-errors` | **842 passed** |
| samen_web `mix test --seed 0 --warnings-as-errors` | **43 passed** |
| samen_web `ci.sh` | **PASSED** (43) |
| driftwood `ci.sh` (20-step verifier + adversarial + T5.4/T5.5 game-days) | **ALL PASSED** (exit 0) |
| pawchart `ci.sh` (verifier + tests + microchip-vault red-path probe) | **ALL PASSED** (exit 0, 35) |
| demo `ci.sh` | **ALL PASSED** (exit 0, 52) |

`mix compile --warnings-as-errors` clean in samen_web, driftwood, and pawchart.

## (5) QUALITY — PASS

Screenshots of PawChart via the shared kit (`/tmp/pc_contacts.png`, `/tmp/pc_billing.png`)
render at mockup quality: branded sidebar (Happy Paws Clinic, V glyph, CRM/Billing/Support
nav), avatar-initial contact table, metric cards (MRR $99.00, active subscriptions), pill
status badges. No regression from the move — the CSS is byte-identical and served from the
shared source; the same polished UI now renders each host's own data.

---

## Fix tasks

**Mandatory (blockers): NONE.**

**Nice-to-have (non-blocking):**

1. Driftwood does not mount CRM/Billing/Support on the OPERATOR plane in its router (only
   tenant-plane CRM + the freight `/operator/impersonate` + framework `/operator/aggregate`).
   The operator-plane masking on the framework CRM/Billing/Support pages is proven by the
   host-independent render tests and by the live IEx probe over driftwood data, but NOT by a
   live HTTP driftwood route. Consider adding an operator-plane `samen_module_routes(..., plane:
   :operator)` mount so the two-plane thesis is dogfoggable end-to-end in a single host over
   HTTP (matches the vision doc's "operator CRM where accounts are tenant orgs").
2. `driftwood/lib/driftwood_web/operator_impersonation_live.ex` renders "denied" without a
   seeded impersonation session (correct fail-closed behavior), so the freight-operator masked
   view isn't visible from a bare local dogfood URL. A seeded demo impersonation grant (or a
   dogfood note in `docs/driftwood-dogfood.md`) would make that surface self-verifiable.
3. Stale-server footgun (process hygiene, not a code issue): a detached `phx.server` booted
   before recompile served empty tables / 404s until rebooted. Not a defect in the extraction;
   noting so future gate runs reboot cleanly after any compile.
