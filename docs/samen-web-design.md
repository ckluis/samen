# samen_web — framework UI library: design + parameterization contract

**Status:** DESIGN (Build/Rewire phases follow this). Companion to **ADR-009**
(`docs/adr/009-samen-web.md`, supersedes ADR-008).

**One-line thesis:** the inherited-80% product UI (component kit + CRM/Billing/Support
LiveViews + the two-plane masking) becomes a framework library `samen_web` that EVERY vertical
inherits by mounting — not driftwood-local code a second vertical must copy. `samen_core` stays
the pure, web-dep-free kernel.

---

## 0 · The problem this fixes (concrete)

Today the inherited UI is forked into one vertical:

- `driftwood/lib/driftwood_web/ui_kit.ex` = `DriftwoodWeb.UIKit` (the component kit).
- `driftwood/priv/static/assets/samen_ui.css` (the design tokens/classes).
- 11 LiveViews: `crm_{companies,contacts,pipeline}_live.ex`,
  `billing_{,invoices,plans}_live.ex`, `support_{,ticket}_live.ex`, `operator_dashboard_live.ex`,
  `ui_kit_live.ex`.
- 3 reads modules that **hardcode host resources + repo**: `Driftwood.CrmReads` references
  `Driftwood.Crm.Person`, `Driftwood.Crm.Company`, `Driftwood.Repo`, etc.

`pawchart` mounts the Billing *scope* (`PawChart.Billing`) but **cannot render it** — the UI is in
driftwood. That is the ADR-004 inheritance thesis broken on the UI plane. `samen_web` fixes it.

---

## 1 · The library

New Mix project at `/Users/clank/Desktop/projects/samen/samen_web`, package `:samen_web`.

```elixir
# samen_web/mix.exs (deps)
defp deps do
  [
    {:phoenix_live_view, "~> 1.0"},
    {:phoenix_html, "~> 4.1"},
    {:phoenix_component, "~> 0.8"},   # (or via phoenix_live_view — pin explicitly)
    {:samen_core, path: "../samen_core"},
    # test-support host deps:
    {:ash, "~> 3.29"}, {:ash_postgres, ...}, {:jason, ...}, {:simple_sat, ...}, {:stream_data, ...}
  ]
end
```

`samen_core` gains **NO** web dep. The web dep lives here. Verify: `samen_core/mix.exs` deps are
unchanged by this workflow; its 842-test suite + verifier gate stay green (run root `ci.sh`
before/after).

Directory layout:

```
samen_web/
  lib/samen/ui.ex                          # Samen.UI — the component kit (was DriftwoodWeb.UIKit)
  lib/samen/web/mount.ex                   # Samen.Web.Mount — the host-parameterization struct
  lib/samen/web/plane.ex                   # Samen.Web.Plane — :tenant | :operator → actor
  lib/samen/web/router.ex                  # Samen.Web.Router — samen_module_routes/3 macro
  lib/samen/web/crm/{reads.ex,companies_live.ex,contacts_live.ex,pipeline_live.ex}
  lib/samen/web/billing/{reads.ex,overview_live.ex,invoices_live.ex,plans_live.ex}
  lib/samen/web/support/{reads.ex,tickets_live.ex,ticket_live.ex}
  lib/samen/web/operator/aggregate_live.ex
  lib/samen/web/ui_kit_live.ex             # /ui-kit living catalog
  priv/static/assets/samen_ui.css          # moved byte-identical
  test/support/{repo.ex,crm.ex,billing.ex,support.ex,seeds.ex}  # standalone host
  test/ .../ *_test.exs
  ci.sh                                    # compile --warnings-as-errors + render/masking tests
```

---

## 2 · The parameterization contract (THE deliverable)

### 2.1 `Samen.Web.Mount` — one struct carries host ownership

```elixir
%Samen.Web.Mount{
  scope_kind: :crm,            # | :billing | :support | :aggregate
  namespace:  Driftwood.Crm,   # host domain namespace (ADR-004 mount point)
  repo:       Driftwood.Repo,  # host's one Postgres — PiiResolution needs it
  domain:     Driftwood.Crm,   # host Ash domain (default == namespace)
  plane:      %Samen.Web.Plane{kind: :tenant},
  labels:     %{title: "Blue Ridge Logistics", glyph: "B", crumb_root: "..."}  # optional
}
```

**Resource derivation (the key move — no host module is ever hardcoded):**

```elixir
Samen.Web.Mount.resource(mount, Person)  #=> Module.concat(mount.namespace, Person)
                                         #   Driftwood.Crm.Person  (or PawChart.Billing.Customer, …)
```

This works because ADR-004's blueprint materializes resources at exactly
`Module.concat(namespace, Name)` (`samen_core/lib/samen/scopes/crm.ex`:
`company_mod = Module.concat(namespace, Company)`). The convention IS the contract. Resource
names per scope:

- **CRM:** `Company`, `Person`, `Pipeline`, `Opportunity`, `Activity`, `Attachment`.
- **Billing:** `Customer`, `Subscription`, `Plan`, `Price`, `Invoice`, `Payment`, `Usage`,
  `Entitlement`.
- **Support:** (verified from `samen_core/lib/samen/scopes/support.ex`) `Ticket`, `Conversation`,
  `Message`, `Agent`, `Sla`, `Macro`, `Csat`.

### 2.2 Transport — via `live_session` session

```elixir
live_session :samen_crm,
  session: %{"samen_mount" => Samen.Web.Mount.to_session(mount)} do
  live "/crm/companies", Samen.Web.CRM.CompaniesLive
  live "/crm/contacts",  Samen.Web.CRM.ContactsLive
  live "/crm/pipeline",  Samen.Web.CRM.PipelineLive
end
```

`to_session/1` serializes only atoms/strings (module atoms, plane atom, label strings) — no PII,
no live struct — safe to sign into the session cookie (mirrors `Samen.Scope`'s "bounded, safe to
log" posture). The LiveView `mount/3` reads it:

```elixir
def mount(_params, %{"samen_mount" => raw}, socket) do
  mount = Samen.Web.Mount.from_session(raw)
  {:ok, assign(socket, samen_mount: mount, org_id: nil)}
end
```

### 2.3 The reads layer — promoted + parameterized (masking chokepoint unchanged)

`Driftwood.CrmReads.contacts/1` → `Samen.Web.CRM.Reads.contacts/2` (takes the mount + scope):

```elixir
def contacts(mount, scope) do
  Samen.Web.Mount.resource(mount, Person)          # was: Driftwood.Crm.Person
  |> Ash.Query.ensure_selected([:full_name, :emails, :phones, :display_name, :job_title, :company_id])
  |> Ash.Query.sort(display_name: :asc)
  |> Ash.read!(scope: scope)
  |> Samen.Api.PiiResolution.resolve(
       Samen.Web.Mount.resource(mount, Person),
       scope.actor,
       repo: mount.repo)                            # was: repo: Driftwood.Repo
rescue
  _ -> []
end
```

Nothing else changes. `Samen.Api.PiiResolution.resolve/4` is already fully parameterized
(`resolve(records, resource, actor, repo: repo)` — `pii_resolution.ex:108`). The masking
invariant is untouched: the reads layer resolves through the single chokepoint and hands the
LiveView already-plane-resolved values; `%Masked{}` → `••••` via `Phoenix.HTML.Safe`. No plaintext
path is added; the resolver's fail-safe (failed decrypt keeps `%Masked{}`) rides along.

### 2.4 The router macro — 5-line host mount

```elixir
defmacro samen_module_routes(kind, namespace, opts \\ [])
# kind:      :crm | :billing | :support | :aggregate
# namespace: the host domain (Driftwood.Crm)
# opts:      repo: (req), domain: (default namespace), plane: :tenant|:operator (default :tenant),
#            path: (default "/crm" etc.), labels: (optional)
```

Host (Driftwood router):

```elixir
import Samen.Web.Router
scope "/", DriftwoodWeb do
  pipe_through :browser
  samen_module_routes :crm,     Driftwood.Crm,     repo: Driftwood.Repo
  samen_module_routes :billing, Driftwood.Billing, repo: Driftwood.Repo
  samen_module_routes :support, Driftwood.Support, repo: Driftwood.Repo
end
```

11 inherited pages in 3 lines. `plane:` defaults `:tenant`; an operator surface passes
`plane: :operator`.

---

## 3 · The component kit `Samen.UI`

- `DriftwoodWeb.UIKit` → `Samen.UI`, all 13 components verbatim (already domain-decoupled per
  ADR-008). `samen_ui.css` moved byte-identical.
- **`module_nav/1` splits:** the CRM/Billing/Support nav groups → `Samen.UI.module_nav/1`
  (framework, `org_id` + `active` + path-prefix params); the freight "Operations" group → a host
  `:extra` slot the vertical passes in. The inherited nav is the framework's; the 20% nav is the
  vertical's.
- **CSS served from the dep:** host `Endpoint` adds
  `plug Plug.Static, at: "/assets", from: {:samen_web, "priv/static/assets"}, only:
  ~w(samen_ui.css)` — `{:samen_web, …}` resolves via `:code.priv_dir(:samen_web)`, so both
  driftwood and pawchart get the identical stylesheet from the lib.
- **Masking invariant survives (LOAD-BEARING):** every `Samen.UI` component stays a dumb renderer;
  a `%Samen.Masked{}` → `••••`; no `Samen.Vault.reveal/3`, no token unwrap, no "show plaintext"
  branch. Asserted by moved ADR-008 tests.

---

## 4 · Two planes — same module, tenant clear vs operator ••••

`Samen.Web.Plane` produces the ACTOR; the actor's `:plane` key drives
`Samen.Api.PiiResolution`. The plane masks nothing itself — masking is the resolver's, by
construction.

| Plane | Actor (produced by `Samen.Web.Plane.scope/2`) | Resolver result |
|---|---|---|
| `:tenant` | `%{id: "broker:#{org}", org_id: org, role: :member, kind: :tenant, plane: :tenant}` | PII **clear** (org owns its data) |
| `:operator` (impersonation) | `%{id: "operator:#{op}", org_id: target, role: :member, kind: :operator, plane: :operator, impersonation: %{…}}` | PII **`••••`** (no reveal grant) |

These are exactly today's `CrmContactsLive.crm_scope/1` and `.operator_scope/1` — promoted to the
framework, not reinvented. **No LiveView has a masking branch.**

### "Accounts ARE tenant orgs" — the operator plane, staged

- **Now (Build-ready):** the operator opens a tenant org via `Samen.Impersonation` (T4.1); the
  SAME `Samen.Web.CRM/Billing/Support` LiveViews render that tenant's data masked (`plane:
  :operator`, `target_org_id`). Plus the token-blind `Samen.Aggregate.Actor` (T4.2) aggregate
  view (MRR/volume over tenants, no PII by construction). This proves one module renders both
  planes.
- **Phase 2 (seam defined, deferred):** a native operator CRM whose account LIST is
  `Samen.Scopes.Identity.Org` rows read on an operator-scoped plane (the SaaS company's own org
  whose customers are the tenant orgs), with per-account drill into that tenant's masked module.
  `Samen.Web.Plane` already carries `operator_id` + `target_org_id`; the account-list view is the
  Phase-2 deliverable. Deferred per the scope-decomposition rule (ship the seam, phase the rest).

---

## 5 · Standalone testability

`samen_web` ships a test-support host so its render tests have real resources + data with NO
driftwood dependency:

- `Samen.WebTest.Repo` — AshPostgres over throwaway DB `samen_web_test` (created/migrated by the
  suite; ADR-005 scratch-DB pattern).
- `Samen.WebTest.{Crm,Billing,Support}` — domains that `use Samen.Scopes.{Crm,Billing,Support}`
  with `otp_app: :samen_web`, `repo: Samen.WebTest.Repo`, `namespace: Samen.WebTest.Crm`, and
  **fresh abbrevs** (`swc/swp/…`, append-only registry rows — no `samen_core` code change).
- Copied `Samen.Migration` templates (ADR-004) run against `samen_web_test` → catalog rows +
  live vault routing.
- Seed helpers insert companies/contacts/customers/tickets.

Render tests (`Phoenix.LiveViewTest`):

1. **tenant clear** — `Samen.Web.CRM.ContactsLive` + tenant mount → seeded contact name/email in
   the clear.
2. **operator masked** — SAME LiveView + operator/impersonation mount → same contact `••••`, vault
   token **absent** from the DOM.
3. **UI unit** — moved ADR-008 kit tests (`%Masked{}` → `••••`, token absent) against `Samen.UI`.

The two-plane guarantee is thus a framework-local test — the proof lives with the reusable code.

---

## 6 · Migration map (exact)

**MOVE → `samen_web`** (see ADR-009 §7.1 table): `ui_kit.ex`→`Samen.UI`; `samen_ui.css`;
`crm_*_live.ex`, `billing_*_live.ex`, `support_*_live.ex`, `operator_dashboard_live.ex`,
`ui_kit_live.ex` → `lib/samen/web/**` (de-hardcoded via `Mount`); `crm_reads.ex`,
`billing_reads.ex`, `support_reads.ex` → `Samen.Web.{CRM,Billing,Support}.Reads`.

**STAYS driftwood-local (freight 20%):** `broker_live.ex`,
`operator_impersonation_live.ex` (renders freight `Driftwood.Reads`), `reads.ex`, `aggregate.ex`,
`context.ex`, freight resources.

**DELETE from driftwood after move:** all moved `*_live.ex` + `ui_kit.ex` + the 3 `*_reads.ex` +
`priv/static/assets/samen_ui.css`.

**Driftwood re-mount:** `mix.exs` += `{:samen_web, path: "../samen_web"}`; `endpoint.ex`
`Plug.Static` from `{:samen_web, …}`; `router.ex` replaces 11 `live` routes + `/operator/aggregate`
+ `/ui-kit` with `import Samen.Web.Router` + `samen_module_routes` one-liners. `/broker` +
`/operator/impersonate` stay. Moved page tests move to `samen_web`; driftwood keeps thin
route-boot smokes.

**PawChart adoption (the payoff):** add `phoenix`/`phoenix_live_view`/`phoenix_html`/`bandit`/
`phoenix_pubsub`/`{:samen_web, path}`; minimal `PawChartWeb.Endpoint` + root layout + router with
`samen_module_routes :billing, PawChart.Billing, repo: PawChart.Repo`. Result: `/billing*` renders
`PawChart.Billing.*` with the shared look, zero UI code. (Adopt-now vs registered-follow-up is a
Build-phase scoping call; the contract makes it ~30 lines either way.)

---

## 7 · Gates (keep green before AND after)

- Root `ci.sh`: spikes + samen_core (842) + demo gate + driftwood 20-step + pawchart 17-step —
  green before (baseline) and after (no regression). `samen_core` untouched → its gate is green by
  construction.
- New root `ci.sh` step: `samen_web` — `mix compile --warnings-as-errors` + render/masking tests
  against `samen_web_test`.
- Driftwood self-verify (booted, rendered text): `PORT=4031` boot; `/crm/contacts?org=<uuid>`
  tenant plane shows the seeded contact clear; operator/impersonation shows `••••`, token absent;
  `/assets/samen_ui.css` → 200 `text/css` from `samen_web` priv. Seed: `mix driftwood.seed`.

---

## 8 · Build-phase checklist (unambiguous work items)

1. Scaffold `samen_web` mix project + deps + `ci.sh`; wire into root `ci.sh`.
2. `Samen.Web.Mount` (struct + `resource/2` + `to_session/1` + `from_session/1`) + tests.
3. `Samen.Web.Plane` (struct + `scope/2` producing the two actors) + tests.
4. `Samen.UI` (move `DriftwoodWeb.UIKit`; split `module_nav`) + `samen_ui.css` move + moved
   masking tests.
5. `Samen.Web.{CRM,Billing,Support}.Reads` (promote the 3 reads; resource+repo from `Mount`).
6. CRM/Billing/Support/operator-aggregate LiveViews (move + de-hardcode; import `Samen.UI`).
7. `Samen.Web.Router.samen_module_routes/3` macro.
8. Test-support host (`Samen.WebTest.*`) + migrations + seeds + tenant/operator render tests.
9. Rewire driftwood (deps, endpoint, router; delete moved files); keep 20-step gate green +
   booted self-verify.
10. (Adopt-now or follow-up) pawchart web endpoint + `samen_module_routes :billing`.
```
