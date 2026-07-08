# REWIRE DRIFTWOOD — report (ADR-009 Rewire phase)

**Status:** GREEN. Driftwood no longer forks the inherited-80% product UI. It now MOUNTS the
framework library `samen_web`: `Samen.UI` for components, `Samen.Web.{CRM,Billing,Support}`
LiveViews via the `samen_module_routes` router macro, and `Samen.Web.Operator.AggregateLive`
for the token-blind plane. The driftwood-local UI kit + all CRM/Billing/Support LiveViews +
reads + the `samen_ui.css` copy were DELETED (their coverage moved to the framework).

- `samen_core` UNTOUCHED — **842 tests still pass** (`--warnings-as-errors --seed 0`).
- All four app suites GREEN **before AND after**: driftwood 20-step CI, samen_web (43),
  demo (403 + CI gate), pawchart (17-step).
- `mix compile --warnings-as-errors` clean (dev + test).
- Booted the host, seeded, and read RENDERED text on the framework-mounted routes:
  `/crm/contacts` shows "Dana Whitfield" + email + phone IN THE CLEAR (tenant plane),
  `/billing` shows "Acme Manufacturing Inc", `/support` shows the inbox, `/operator/aggregate`
  shows "Token-blind aggregate plane." — all via the framework modules, zero `vt_`/`pii_`
  token leaks. `/assets/samen_ui.css` returns `200 text/css` from the `samen_web` priv.

---

## What was done (a–d)

### (a) `samen_web` path dep

`driftwood/mix.exs` — added `{:samen_web, path: "../samen_web"}`.

### (b) Components + CSS from the framework

- `broker_live.ex` + `operator_impersonation_live.ex` (the freight 20%, which STAY
  driftwood-local per ADR-009 §7.2) now `import Samen.UI` instead of the deleted
  `DriftwoodWeb.UIKit`.
- `broker_live.ex`'s sidebar: the freight "Operations" nav group is now passed as the
  framework `Samen.UI.module_nav`'s `:extra` slot (the inherited CRM/Billing/Support groups
  come from the framework component). The old `module_nav`'s hardcoded Operations group is
  gone; `broker_active/1` (dead) removed.
- `endpoint.ex` — `Plug.Static` now serves `from: {:samen_web, "priv/static/assets"}, only:
  ~w(samen_ui.css)` (the CSS ships inside the dep). `layouts.ex` comment updated.

### (c) Router mounts the framework modules

`router.ex` — replaced the 11 hand-written `live "/crm/…" | "/billing/…" | "/support/…"`
routes + `/operator/aggregate` + `/ui-kit` with:

```elixir
import Samen.Web.Router

scope "/" do                       # BARE scope — the mounted LiveViews are the framework's
  pipe_through(:browser)           # OWN fully-qualified Samen.Web.* modules (a DriftwoodWeb
  samen_module_routes(:crm,     Driftwood.Crm,     repo: Driftwood.Repo)  # alias would
  samen_module_routes(:billing, Driftwood.Billing, repo: Driftwood.Repo)  # wrongly prefix
  samen_module_routes(:support, Driftwood.Support, repo: Driftwood.Repo)  # them).
end
```

Three lines mount all 11 inherited pages over Driftwood's materialized `Driftwood.{Crm,
Billing,Support}.*` resources. `/broker` + `/operator/impersonate` stay under
`scope "/", DriftwoodWeb`.

The operator aggregate (`/operator/aggregate`) is mounted as a plain `live` under a
`live_session` carrying an operator-plane `Samen.Web.Mount` whose labels carry an
`aggregate_loader: {Driftwood.OperatorAggregate, :load, []}` MFA — the new
`lib/driftwood/operator_aggregate.ex` adapter maps `Driftwood.OperatorDashboard`'s MRR /
load-volume into the framework's generic `%{metrics:, groups:}` shape. The framework owns
the token-blind chrome; the vertical owns its projection shape.

### (d) Sidebar + tests

- Sidebar keeps the "Operations freight 20% + CRM/Billing/Support 80%" story working (verified
  in the booted broker console screenshot).
- The driftwood tests that referenced the deleted modules were rewired to hit the mounted
  framework, keeping every MASKING assertion (tenant clear / operator ••••):
  - `test/support/data_case.ex` gained `driftwood_mount/2` + `render_framework/4` — build the
    SAME `Samen.Web.Mount` the router builds and render a framework LiveView over Driftwood's
    resources, on either plane (the exact code path the mounted route runs).
  - `crm_ui_test.exs`, `billing_ui_test.exs`, `support_ui_test.exs` — rewritten as
    mounted-framework smokes: each page renders Driftwood's seeded rows; TENANT plane shows
    PII in the clear (Dana Whitfield / Acme / agent name + "disputing the charge" message
    body), OPERATOR plane shows •••• with the plaintext ABSENT and no `vt_` token. Cross-org
    isolation kept.
  - `ui_kit_test.exs` → renamed intent to a driftwood SIDEBAR-ASSEMBLY test: renders
    `BrokerLive` and asserts the freight "Operations" `:extra` group + the framework
    CRM/Billing/Support groups + every resolvable href. (The `Samen.UI` component + masking
    unit tests moved to samen_web's `ui/components_test.exs` + `ui/ui_masking_test.exs`.)
  - `web_red_paths_test.exs` RED PATH 3 + `dogfood_walkthrough_test.exs` step 9 — the aggregate
    render now targets `Samen.Web.Operator.AggregateLive` over the driftwood aggregate mount
    (data assertions via `Driftwood.OperatorDashboard` unchanged).

### Framework fix earned by the rewire (levels up the core)

Booting the real host surfaced a latent framework bug: `Samen.Web.Mount.from_session/1` used
`String.to_existing_atom("crm")` for `scope_kind`, which raised `ArgumentError` in a host
LiveView's mount process where the bare `:crm`/`:billing`/`:support` atom was not resident
(500 on every mounted CRM/Billing/Support route). Fixed at the FRAMEWORK level: `scope_kind`
is a bounded, framework-owned enum, so `from_session` now maps the known strings explicitly
(`"crm" -> :crm`, …) — robust in any deserializing process. samen_web's own 43 tests stay
green. Also silenced a dep-compile warning: `samen_web.test_setup` now resolves its
test-only repo via `Module.concat/1` so a host that pulls samen_web (and does not compile its
`test/support`) builds warning-free.

---

## Deleted from driftwood (proving it moved to the framework)

| Deleted file | Lines | Now inherited from |
|---|---:|---|
| `lib/driftwood_web/ui_kit.ex` (`DriftwoodWeb.UIKit`) | 495 | `Samen.UI` |
| `lib/driftwood_web/ui_kit_live.ex` (`/ui-kit`) | 206 | `Samen.Web.UIKitLive` |
| `lib/driftwood_web/crm_companies_live.ex` | 226 | `Samen.Web.CRM.CompaniesLive` |
| `lib/driftwood_web/crm_contacts_live.ex` | 297 | `Samen.Web.CRM.ContactsLive` |
| `lib/driftwood_web/crm_pipeline_live.ex` | 232 | `Samen.Web.CRM.PipelineLive` |
| `lib/driftwood_web/billing_live.ex` | 324 | `Samen.Web.Billing.OverviewLive` |
| `lib/driftwood_web/billing_invoices_live.ex` | 295 | `Samen.Web.Billing.InvoicesLive` |
| `lib/driftwood_web/billing_plans_live.ex` | 243 | `Samen.Web.Billing.PlansLive` |
| `lib/driftwood_web/support_live.ex` | 336 | `Samen.Web.Support.TicketsLive` |
| `lib/driftwood_web/support_ticket_live.ex` | 533 | `Samen.Web.Support.TicketLive` |
| `lib/driftwood_web/operator_dashboard_live.ex` | 202 | `Samen.Web.Operator.AggregateLive` |
| `lib/driftwood/crm_reads.ex` (`Driftwood.CrmReads`) | 153 | `Samen.Web.CRM.Reads` |
| `lib/driftwood/billing_reads.ex` | 261 | `Samen.Web.Billing.Reads` |
| `lib/driftwood/support_reads.ex` | 296 | `Samen.Web.Support.Reads` |
| `priv/static/assets/samen_ui.css` | 386 | `samen_web/priv/static/assets/samen_ui.css` (byte-identical, verified `diff -q`) |
| **Total deleted** | **4485** | |

## Line delta

- **Production code (lib/ + priv/):** −4485 deleted, +138 added (`operator_aggregate.ex` 106,
  router grew +32) = **net −4347 lines of driftwood-local product UI**, now inherited from the
  framework by every vertical (the ADR-004 inheritance story, finally true on the UI side).
- **Tests:** the four deep per-module suites (~1100 lines) were replaced by mounted-framework
  smokes (476 lines) + a shared 78-line DataCase helper; the DEEP render/masking coverage now
  lives in samen_web's 43-test suite (framework-local, vertical-independent). Net driftwood
  test lines dropped; the guarantee travels with the reusable code.

## Verification (before + after)

| Gate | Before | After |
|---|---|---|
| samen_core (`--seed 0 --warnings-as-errors`) | 842 passed | 842 passed (untouched) |
| samen_web `ci.sh` | 43 passed | 43 passed |
| driftwood `ci.sh` (20 steps + game-days) | ALL PASSED | ALL PASSED |
| demo (test + CI gate) | 403 passed / gate PASS | 403 passed / gate PASS |
| pawchart `ci.sh` (17 steps) | ALL PASSED | ALL PASSED |

Booted `MIX_ENV=dev PORT=4034 mix phx.server`, seeded org
`b1112d00-0000-4000-8000-000000000001` (`mix driftwood.seed`). All mounted routes return
200; `/assets/samen_ui.css` 200 `text/css` from the samen_web priv; `/crm/contacts` renders
the contact PII in the clear (tenant plane) with zero token leaks; the broker sidebar shows
the freight Operations 20% + the inherited CRM/Billing/Support 80% via the framework.
