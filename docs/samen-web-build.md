# samen_web — BUILD report (ADR-009)

**Status:** GREEN. The framework UI library `samen_web` is built exactly per ADR-009 +
the design contract. `mix compile --warnings-as-errors` clean; **43 samen_web tests pass**;
**samen_core untouched + still 842 green** (verified `--seed 0 --warnings-as-errors`).

The library is at `/Users/clank/Desktop/projects/samen/samen_web`.

---

## What shipped (deliverables a–e)

### (a) Mix project + deps + standalone test-support host

- `samen_web/mix.exs` — package `:samen_web`, deps `phoenix` + `phoenix_live_view` +
  `phoenix_html` + `{:samen_core, path: "../samen_core"}` + (test) `ash`/`ash_postgres`/
  `simple_sat`. **samen_core gains NO web dep** — the web dep lives here.
- `config/{config,dev,test}.exs` — wires the scratch repo into every samen_core repo seam
  PiiResolution needs (`vault_repo`/`reveal_grant_repo`/`impersonation_repo`/…), mirroring
  driftwood.
- **Test-support host** in `test/support/`: `Samen.WebTest.Repo` (AshPostgres over the
  throwaway `samen_web_test` DB), and `Samen.WebTest.{Crm,Billing,Support}` — real Ash
  domains that `use Samen.Scopes.{Crm,Billing,Support}` with fresh abbrevs
  (`swc/swp/…`, `wbc/…`, `wsk/…`). This materializes `samen_web`'s OWN CRM/Billing/Support
  resources so the render tests read real rows against a real vault — with NO driftwood dep.
- Migrations `priv/repo/migrations/`: the foundational stack copied from driftwood
  (ash_functions, oban, vault_tables, reveal_grants, erasure, catalog_tables, aud_event,
  migration_meta, tnt_field — module prefix renamed, host-agnostic) + two scope-mount
  migrations (`use Samen.Migration` + `catalog_sync`) for CRM and Billing+Support.
- `lib/mix/tasks/samen_web.test_setup.ex` — drops/creates/migrates `samen_web_test`; run by
  the `mix test` alias, so the gate is one self-contained command.
- The abbrev registry gained 21 append-only rows for the `Samen.WebTest.*` mounts (data
  file, ADR-009 §6 — "no samen_core code changes"; all four existing apps still compile).

### (b) `Samen.UI` — the full component kit + CSS + serving helper

- `lib/samen/ui.ex` (`Samen.UI`) — all 13 components moved verbatim from
  `DriftwoodWeb.UIKit` (`app_shell`, `sidebar`, `nav_group`, `nav_item`, `topbar`, `button`,
  `tabs`/`tab`, `data_table`, `pill`, `progress`, `metric`, `mask_bar`, `token_blind_bar`).
- **`module_nav/1` generalized (the one vertically-coupled component):** the CRM/Billing/
  Support nav groups are framework-level, parameterized by `org_id` + `active` + per-module
  path prefixes; the freight "Operations" group is OUT — a host passes its own 20% nav via
  the new `:extra` slot.
- `priv/static/assets/samen_ui.css` — byte-identical copy (verified `diff -q`), served from
  the dep via `plug Plug.Static, from: {:samen_web, "priv/static/assets"}, only:
  ~w(samen_ui.css)`. `Samen.UI.stylesheet_path/0` is the documented on-disk helper
  (verified it resolves via `:code.priv_dir(:samen_web)`).
- Masking invariant preserved by construction — a `%Samen.Masked{}` handed to any component
  renders `••••` via `Phoenix.HTML.Safe`; the kit code has no `Vault`/`reveal`/token-unwrap
  path (asserted by a source-scan test).

### (c) `Samen.Web.{CRM,Billing,Support}` — generalized LiveViews (both planes)

Reads promoted + parameterized (resource + repo from the mount, masking chokepoint
unchanged): `Samen.Web.CRM.Reads`, `Samen.Web.Billing.Reads`, `Samen.Web.Support.Reads`.

LiveViews (host-agnostic; sidebar branding from `mount.labels` with neutral defaults):
- CRM: `CompaniesLive`, `ContactsLive` (🔒 PII), `PipelineLive`
- Billing: `OverviewLive`, `InvoicesLive`, `PlansLive`
- Support: `TicketsLive`, `TicketLive` (🔒 PII: agent name/email + message body)
- Operator: `Operator.AggregateLive` (token-blind stub — banner + `⊘` chrome; host supplies
  the projection via an `aggregate_loader:` MFA on the mount labels) + `UIKitLive` (`/ui-kit`
  living catalog).

**Two-plane, no masking branch in any LiveView:** `mount.plane` produces the actor via
`Samen.Web.Plane.scope/2`; the reads resolve through `Samen.Api.PiiResolution`; a
`%Masked{}` → `••••`. Tenant plane clear, operator/impersonation plane masked — same
module, same code path, differing only in the actor's `:plane`.

### (d) The router macro + parameterization structs

- `Samen.Web.Mount` — carries `{scope_kind, namespace, repo, domain, plane, labels}`;
  `resource(mount, Name)` derives the host module by `Module.concat(namespace, Name)` (the
  ADR-004 convention IS the contract); `to_session/1`/`from_session/1` are a lossless,
  cookie-safe (atoms/strings only) round-trip.
- `Samen.Web.Plane` — `:tenant` / `:operator`; `scope/2` produces the two actors verbatim
  from the old inline `crm_scope/1` / `operator_scope/1`.
- `Samen.Web.Router.samen_module_routes/3` — a host mounts a module's pages in one line;
  the macro builds the mount, threads it through a `live_session` session, and declares the
  routes. `Samen.Web.Live.assign_mount/2` reads it in each LiveView's `mount/3`.

### (e) samen_web's OWN test suite — 43 tests

| Suite | Tests | Covers |
|---|---:|---|
| `ui/ui_masking_test.exs` | 5 | `%Masked{}` → `••••` in pill/data_table/progress/metric; token absent; no unmask path in code |
| `ui/components_test.exs` | 7 | shell/button/pill render; `module_nav` inherited groups + custom paths + `:extra` slot |
| `web/mount_test.exs` | 6 | `resource/2` derivation per host; session round-trip (tenant + operator); cookie-safe |
| `web/plane_test.exs` | 3 | the two actors; the `:plane` key the resolver reads |
| `web/router_test.exs` | 4 | route tables; a real host router compiles via the macro |
| `web/crm_render_test.exs` | 5 | companies/pipeline render; **tenant clear / operator `••••` / token-absent red path** |
| `web/billing_render_test.exs` | 5 | overview/plans/invoices; **tenant clear / operator masked / no-leak** |
| `web/support_render_test.exs` | 5 | inbox + detail; agent PII + message body **tenant clear / operator masked / no-leak** |
| `web/operator_render_test.exs` | 3 | token-blind aggregate chrome + `⊘`; `/ui-kit` catalog |

The render tests mount the framework LiveViews over the `Samen.WebTest.*` host on both
planes and assert against real seeded PII sentinels (`Aurelia Sentinelson`,
`Meridian Plaintext Holdings`, `Bartholomew Clearname`, a plaintext message body):
**present on tenant, ABSENT + `••••` on operator, and no `vt_`/`pii_` token ever in the DOM.**

---

## How a host mounts each module (the module API)

CSS (host Endpoint):

```elixir
plug Plug.Static, at: "/assets", from: {:samen_web, "priv/static/assets"}, only: ~w(samen_ui.css)
```

Routes (host router — needs `Phoenix.LiveView.Router` imported, which `use MyAppWeb, :router`
provides):

```elixir
import Samen.Web.Router

scope "/", DriftwoodWeb do
  pipe_through :browser
  samen_module_routes :crm,     Driftwood.Crm,     repo: Driftwood.Repo
  samen_module_routes :billing, Driftwood.Billing, repo: Driftwood.Repo
  samen_module_routes :support, Driftwood.Support, repo: Driftwood.Repo
end
```

Three lines mount all 11 inherited pages. `plane: :operator, operator_id:, target_org_id:`
selects the masked operator surface over the same LiveViews. `labels:` overrides workspace
title/glyph/crumb-root (data, not code). PawChart adopts Billing with the identical
one-liner (`samen_module_routes :billing, PawChart.Billing, repo: PawChart.Repo`) — the
payoff, zero UI code.

---

## Gates

- `samen_web/ci.sh` — `mix compile --warnings-as-errors` + `mix test --warnings-as-errors`
  (runs `samen_web.test_setup` first). Wired into the root `ci.sh` as a new step after
  samen_core.
- samen_core: **842 passed** (`--seed 0 --warnings-as-errors`) — untouched code; only the
  registry data file gained append-only rows.
- driftwood / demo / pawchart: all compile clean `--warnings-as-errors` with the appended
  registry (the abbrev verifier passes for all).

---

## Explicitly deferred (the Rewire phase — ADR-009 §7)

Per ADR-009's own Build/Rewire split and the scope-decomposition rule (ship the seam, phase
the cross-cutting refactor), the following are the follow-on **Rewire phase**, NOT part of
"BUILD samen_web":

1. **Driftwood rewire** — add `{:samen_web, path: "../samen_web"}`; swap the Endpoint
   `Plug.Static` to `{:samen_web, …}`; replace the 11 hand-written `live` routes + `/ui-kit`
   with `samen_module_routes` one-liners; DELETE `driftwood_web/ui_kit.ex`, the 9 moved
   `*_live.ex`, and the 3 `*_reads.ex`; delete the local `samen_ui.css`. Driftwood keeps
   thin route-boot smokes (the deep masking assertions now live in samen_web).
2. **PawChart adoption** — add the web deps + a minimal `PawChartWeb.Endpoint`/router with
   `samen_module_routes :billing, PawChart.Billing, repo: PawChart.Repo` — the "same look,
   zero UI code" proof.

The operator NATIVE CRM (accounts = `Identity.Org` list on an operator-scoped plane) remains
the ADR-009 §5.3 Phase-2 deliverable; the seam (`Samen.Web.Plane` operator kind +
impersonation over the SAME CRM/Billing/Support LiveViews) is shipped and proven by the
operator-masked render tests.
