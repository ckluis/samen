# ADR-009 — `samen_web`: the framework UI library + the two-plane mountable-module pattern

- **Status:** Accepted (design; Build/Rewire phases follow this contract)
- **Date:** 2026-07-08
- **Task:** Framework-layer DESIGN — stand up `samen_web`, the two-plane module pattern, the
  host-parameterization contract, and the migration map off the driftwood-local UI.
- **Deciders:** opus (framework layer), grounded in the vision doc
  (`docs/samen-foundry.txt` — "The inherited 80%", "operator CRM where accounts are tenant
  orgs; billing/MRR over tenants; tickets tenants file with the SaaS"), ADR-004 (scope
  packaging: library-authored blueprint, host-materialized resources), ADR-005 (helper emits
  the body, host owns the module), and the Rule-of-Three trigger ADR-008 pre-registered.
- **Supersedes:** **ADR-008** (the driftwood-local UI kit). ADR-008 explicitly pre-registered
  this extraction ("when demo or pawchart adopts the kit, move `ui_kit.ex` + `samen_ui.css`
  into a shared path-dep lib"). The trigger has fired for a stronger reason than a third CSS
  consumer: the *entire* inherited product UI (kit **plus** CRM/Billing/Support LiveViews) was
  built driftwood-local, which is exactly the "paper-thin, vertical-local" mistake this
  workflow exists to fix. ADR-009 promotes all of it to the framework.

---

## 1 · Context — the mistake ADR-008 encoded, and why it must be reversed

Samen's thesis (ADR-004) is that every vertical **inherits** the universal scopes as real Ash
resources — "the inherited 80%." Phase 3–6 made the *data* side of that real: CRM/Billing/Support
ship as blueprint macros in `samen_core`, and a host materializes them with one
`use Samen.Scopes.X`. Driftwood, PawChart, and the demo all mount the same canonical scope
definitions; a field added in `samen_core` reaches every host on a dep bump.

The **UI** side did not follow. ADR-008 put the component kit (`DriftwoodWeb.UIKit` +
`samen_ui.css`) driftwood-local under a Rule-of-Three deferral, and the CRM/Billing/Support
LiveViews (`crm_*_live.ex`, `billing_*_live.ex`, `support_*_live.ex`) were written driftwood-local
too. The result is an inversion of the thesis: the inherited-80% *data* is framework-level, but
the inherited-80% *product surface that renders it* is forked into one vertical. PawChart today
has **no** CRM/Billing/Support UI at all — it mounts the Billing scope but cannot show it,
because the pages live in `driftwood_web`. A second vertical that wants "Billing as plain
subscriptions, with a UI" would have to copy 11 LiveViews.

That is the drift ADR-004 spent an entire ADR avoiding on the data side. ADR-009 closes it on
the UI side: **the inherited product UI must be framework-level so every vertical inherits it,
not re-implements it.**

### The two constraints that shape the whole design

1. **`samen_core` must stay web-dep-free.** It is the pure kernel (self-qualifying storage,
   machine catalog, PII vault) with an 842-test suite + a standalone verifier gate. ADR-008 §(i)
   already rejected dragging `phoenix_live_view`/`phoenix_component` into the kernel, and that
   reasoning is unchanged. The kernel depends on `phoenix_html` ONLY for the `%Masked{}`
   `Phoenix.HTML.Safe` impl. **The web dep goes in a NEW lib, never in `samen_core`.**

2. **The LiveViews render a HOST's materialized resources without hardcoding module names.**
   Today `DriftwoodWeb.CrmContactsLive` aliases `Driftwood.CrmReads`, which hardcodes
   `Driftwood.Crm.Person`, `Driftwood.Crm.Company`, and `Driftwood.Repo`. Moved verbatim into a
   shared lib, that code would render *Driftwood's* resources inside *PawChart*. The central
   design problem of ADR-009 is the **parameterization seam**: how a framework LiveView learns
   which resources + repo + domain to read, per host, cleanly.

---

## 2 · Decision (overview)

**Stand up `samen_web` (package `:samen_web`), a new Mix lib depending on
`phoenix_live_view` + `phoenix_html` + `phoenix_component` + `samen_core` (path). `samen_core`
gains NO web dep.** `samen_web` ships four things:

- **`Samen.UI`** — the ADR-008 component kit, moved + renamed (`DriftwoodWeb.UIKit` → `Samen.UI`),
  plus the `samen_ui.css` asset relocated to `samen_web/priv/static/assets/`. A host serves the
  CSS via a scoped `Plug.Static` from `{:samen_web, "priv/static"}`.
- **`Samen.Web.CRM` / `Samen.Web.Billing` / `Samen.Web.Support`** — the CRM/Billing/Support
  LiveViews, moved + de-hardcoded, reading a host's materialized resources through a
  **`Samen.Web.Mount` config struct** threaded via `live_session`.
- **`Samen.Web.Router`** — a `samen_module_routes/3` router macro so a host mounts a module's
  pages in ~5 lines.
- **`Samen.Web.Plane`** — the two-plane abstraction (`:tenant` vs `:operator`) that drives PII
  resolution (`Samen.Api.PiiResolution`) and is the single seam where "accounts ARE tenant orgs"
  will deepen in Phase 2.

The rest of this ADR specifies each precisely — this is the contract the Build/Rewire phases
follow.

---

## 3 · The parameterization contract (the load-bearing decision)

Three options were considered for how a framework LiveView learns the host's resources/repo:

- **(A) A behaviour the host implements** (`@behaviour Samen.Web.Host` with
  `crm_person/0`, `crm_company/0`, `repo/0`, …). Rejected: it forces every host to write a
  callback module of ~20 boilerplate functions per scope, and it re-introduces a *named module*
  the LiveView must be told about — pushing the "which module?" problem up one level, not solving
  it. It also can't be threaded through `live_session` cleanly (it's a compile-time contract, not
  a per-session value).

- **(B) Values threaded via `live_session` session/assigns, ad hoc.** Rejected as *primary*:
  it's the right *transport* but with no *shape* it becomes a bag of loose keys each LiveView
  reads defensively — exactly the "easy to forget → leak" hazard `Samen.Scope` was created to
  avoid (Scope moduledoc §"Why a scope, not a bare actor").

- **(C, CHOSEN) A `Samen.Web.Mount` config struct, built once by the router macro from the
  host's `namespace` + `repo` + `domain`, threaded via `live_session`, read by the framework
  LiveViews.** This is the UI analogue of ADR-004's blueprint decision and `Samen.Scope`: one
  struct carries the host-ownership facts, so no LiveView hardcodes a module name and no host
  writes boilerplate.

### 3.1 Why a struct built from `namespace` is enough (the key realization)

A scope mounts at a **namespace** (`Driftwood.Crm`), and ADR-004's blueprint materializes its
resources as `Module.concat(namespace, Company)`, `Module.concat(namespace, Person)`, … — a
**stable, predictable naming convention** (`samen_core/lib/samen/scopes/crm.ex`:
`company_mod = Module.concat(namespace, Company)`). So a host does **not** need to enumerate its
resource modules: given `namespace: Driftwood.Crm`, the framework derives `Driftwood.Crm.Person`,
`Driftwood.Crm.Company`, `Driftwood.Crm.Pipeline`, etc. by the same `Module.concat`. The host
supplies three facts; the struct derives the rest.

### 3.2 The `Samen.Web.Mount` struct

```elixir
defmodule Samen.Web.Mount do
  @moduledoc """
  The host-parameterization struct for a mounted samen_web module. Carries the three
  irreducibly-host facts (namespace, repo, domain) + the plane, and DERIVES each resource
  module by the ADR-004 naming convention (Module.concat(namespace, Resource)). A framework
  LiveView reads resources ONLY through this struct — it never names a host module.
  """
  @enforce_keys [:scope_kind, :namespace, :repo, :domain, :plane]
  defstruct [
    :scope_kind,   # :crm | :billing | :support — which blueprint is mounted
    :namespace,    # e.g. Driftwood.Crm — the host domain namespace (ADR-004)
    :repo,         # e.g. Driftwood.Repo — the host's one Postgres (PiiResolution needs it)
    :domain,       # e.g. Driftwood.Crm — the host Ash domain (usually == namespace)
    :plane,        # %Samen.Web.Plane{} — :tenant | :operator (drives masking)
    :labels        # optional UI copy overrides (workspace title, brand glyph, crumbs root)
  ]

  @doc "Derive a resource module by the ADR-004 Module.concat(namespace, name) convention."
  def resource(%__MODULE__{namespace: ns}, name), do: Module.concat(ns, name)
end
```

`labels` is optional (host branding: workspace title "Blue Ridge Logistics", glyph "B", crumb
root). If absent, the framework renders neutral defaults ("Workspace", "S"). This is the ONLY
place vertical-specific copy lives, and it's data, not code.

### 3.3 The reads seam becomes framework-level and mount-parameterized

`Driftwood.CrmReads` (which hardcodes `Driftwood.Crm.Person`/`Company` + `Driftwood.Repo`) is
**promoted** to `Samen.Web.CRM.Reads` — the same functions, but every hardcoded module becomes
`Samen.Web.Mount.resource(mount, Person)` and every `repo: Driftwood.Repo` becomes
`repo: mount.repo`. The PII chokepoint is unchanged: `Samen.Api.PiiResolution.resolve/4` is
already fully parameterized (`resolve(records, resource, actor, repo: repo)` —
`samen_core/lib/samen/api/pii_resolution.ex:108`). The masking invariant is preserved by
construction: the reads layer resolves through the single chokepoint and hands the LiveView
already-plane-resolved values; a `%Masked{}` renders `••••` via `Phoenix.HTML.Safe`.

So the promotion is mechanical and complete: no plaintext path is added, no vault call is added,
and the resolver's fail-safe (a failed decrypt keeps `%Masked{}`, never plaintext) rides along
unchanged.

### 3.4 The router macro — a host mounts CRM in ~5 lines

```elixir
defmodule Samen.Web.Router do
  @doc """
  Mount a samen_web module's LiveView pages under a host router scope. Builds the
  Samen.Web.Mount struct from the host's namespace/repo/domain, threads it through a
  live_session, and declares the module's routes. `plane:` selects tenant vs operator.
  """
  defmacro samen_module_routes(kind, namespace, opts \\ []) do
    # kind in [:crm, :billing, :support]; opts: repo:, domain:, plane:, path:, labels:
    quote do
      # expands to: live_session <name>, session: %{"samen_mount" => encoded_mount} do
      #   live "<path>/companies", Samen.Web.CRM.CompaniesLive
      #   live "<path>/contacts",  Samen.Web.CRM.ContactsLive
      #   live "<path>/pipeline",  Samen.Web.CRM.PipelineLive
      # end
    end
  end
end
```

Host usage (Driftwood router, tenant plane):

```elixir
import Samen.Web.Router

scope "/", DriftwoodWeb do
  pipe_through :browser
  samen_module_routes :crm,     Driftwood.Crm,     repo: Driftwood.Repo, plane: :tenant
  samen_module_routes :billing, Driftwood.Billing, repo: Driftwood.Repo, plane: :tenant
  samen_module_routes :support, Driftwood.Support, repo: Driftwood.Repo, plane: :tenant
end
```

Three lines mount all 11 inherited pages. PawChart mounts Billing with the identical
one-liner (`samen_module_routes :billing, PawChart.Billing, repo: PawChart.Repo, plane: :tenant`)
and inherits the Billing UI it currently cannot show.

### 3.5 Why the Mount travels in `live_session`, not the socket assigns alone

`live_session` `session: %{"samen_mount" => …}` puts the mount in the signed session, so it is
present on the **initial dead render AND the websocket reconnect** — both mount passes see it
without a round-trip to re-derive it. The framework LiveView's `mount/3` reads it once:

```elixir
def mount(_params, %{"samen_mount" => raw} = _session, socket) do
  mount = Samen.Web.Mount.from_session(raw)  # rebuilds the struct (modules are atoms, safe)
  {:ok, assign(socket, samen_mount: mount, org_id: ...)}
end
```

The session value carries only atoms/strings (namespace, repo, domain as module atoms; plane as
an atom; labels as strings) — no PII, no live struct, safe to sign into a cookie. This mirrors
`Samen.Scope`'s "actor is bounded IDs, safe to log" posture.

---

## 4 · `Samen.UI` — the component kit + CSS asset

### 4.1 The move

`DriftwoodWeb.UIKit` → **`Samen.UI`**, verbatim component bodies (the kit is already
domain-decoupled — ADR-008 §"Honest dep-boundary statement": "nothing imports a Driftwood domain
module"), namespace renamed. All 13 components move: `app_shell/1`, `sidebar/1`, `nav_group/1`,
`nav_item/1`, `topbar/1`, `button/1`, `tabs/1`+`tab/1`, `data_table/1`, `pill/1`, `progress/1`,
`metric/1`, `mask_bar/1`, `token_blind_bar/1`.

**`module_nav/1` splits.** In `DriftwoodWeb.UIKit` there is a `module_nav/1` that hardcodes the
freight "Operations" group + the CRM/Billing/Support hrefs. This is the one component with
vertical coupling. It splits:

- The **CRM/Billing/Support** nav groups move to `Samen.UI.module_nav/1` (framework — every
  vertical shows the same inherited-module nav), parameterized by `org_id` + `active` (already
  are) and by the mount path prefix.
- The **"Operations" (freight)** group stays driftwood-local as a `:extra` slot the host passes
  into `Samen.UI.module_nav/1`. A vertical's own 20% nav is the vertical's business; the
  inherited-80% nav is the framework's.

### 4.2 The CSS asset + how a host serves it

`driftwood/priv/static/assets/samen_ui.css` → **`samen_web/priv/static/assets/samen_ui.css`**
(byte-identical; it's already tokens + component classes with no vertical coupling).

A host serves it with a scoped `Plug.Static` pointed at `samen_web`'s priv:

```elixir
# in the host Endpoint (documented in the samen_web README + moduledoc):
plug Plug.Static, at: "/assets", from: {:samen_web, "priv/static/assets"}, only: ~w(samen_ui.css)
```

`from: {:samen_web, "priv/static/assets"}` resolves via `:code.priv_dir(:samen_web)`, so the CSS
ships **inside the dependency** — driftwood and pawchart both get the identical stylesheet from
the lib, not a per-vertical copy. The root layout links `<link rel="stylesheet"
href="/assets/samen_ui.css">` exactly as today. Driftwood's current
`plug Plug.Static, ..., from: {:driftwood, "priv/static"}, only: ["assets"]` is replaced by the
`{:samen_web, …}` form; the driftwood-local `samen_ui.css` is deleted.

### 4.3 The masking invariant survives the move unchanged (LOAD-BEARING)

The move changes namespace only, not behaviour. Every `Samen.UI` component remains a **dumb
renderer**: `pill/1`, `data_table/1` cells, `progress/1` labels, `metric/1` values render
whatever value the caller hands them. A `%Samen.Masked{}` renders `••••` via
`Phoenix.HTML.Safe`. `Samen.UI` never calls `Samen.Vault.reveal/3`, never pattern-matches a token
out of a `%Masked{}`, and has no "show plaintext" branch. This is asserted by moved-and-renamed
versions of the ADR-008 tests: a `%Masked{}` handed straight to `pill/1` / a `data_table` cell /
`progress/1` renders `••••`, and the token string is absent from the rendered output.

---

## 5 · Two-plane abstraction — `Samen.Web.Plane`

The thesis: **the same module renders tenant-plane (org's own data, PII clear) vs operator-plane
(accounts ARE tenant orgs, PII masked `••••`).** ADR-009 defines the minimal seam now; deeper
operator surfaces are Phase 2.

### 5.1 The struct

```elixir
defmodule Samen.Web.Plane do
  @moduledoc """
  Which of the two planes a mounted module is rendering on. Drives PII resolution
  (Samen.Api.PiiResolution) via the ACTOR the plane produces. Masking is BY CONSTRUCTION:
  the plane produces the actor; the actor's :plane key drives the resolver; the resolver
  returns %Masked{} on the operator plane.
  """
  @enforce_keys [:kind]
  defstruct [:kind, :operator_id, :target_org_id, :impersonation]

  # kind: :tenant   — the org acts over its OWN data. actor.plane = :tenant. PII CLEAR.
  # kind: :operator — the SaaS company acts; a tenant org IS its account. PII ••••.
end
```

### 5.2 How the plane drives masking (the by-construction chain)

The plane does **not** mask anything itself. It produces the **actor**, and the actor's `:plane`
key is what `Samen.Api.PiiResolution` reads (`pii_resolution.ex`: `plane_of(actor)` →
`Map.get(actor, :plane)`):

- **`:tenant`** → actor `%{id: "broker:#{org_id}", org_id: org_id, role: :member, kind: :tenant,
  plane: :tenant}` (exactly today's `CrmContactsLive.crm_scope/1`). The resolver's `:tenant`
  branch reveals the org's own PII in the clear.
- **`:operator`** (impersonation) → actor `%{id: "operator:#{operator_id}", org_id:
  target_org_id, role: :member, kind: :operator, plane: :operator, impersonation: %{…}}`
  (exactly today's `CrmContactsLive.operator_scope/1`). The resolver's `:operator` +
  `impersonated?` branch returns `%Masked{}` → `••••`, because the session carries no reveal
  grant.

The framework LiveView calls `Samen.Web.Plane.scope(plane, org_id)` to build the `%Samen.Scope{}`
and passes it to the reads layer. **No LiveView has a masking branch.** Masking is the resolver's,
driven by the plane's actor. This is the ADR-008 invariant generalized: the plane cannot produce
plaintext on the operator path because the resolver won't.

### 5.3 Operator plane — "accounts ARE tenant orgs" (the minimal seam now)

The vision doc's operator CRM says: "accounts are tenant orgs; billing/MRR over tenants; tickets
tenants file with the SaaS." Two operator data-contexts already exist in the kernel and are the
seam ADR-009 wires:

1. **Per-tenant masked impersonation** (`Samen.Impersonation`, T4.1) — the operator opens ONE
   tenant org and reads its real CRM/Billing/Support UI with `••••` PII. `Samen.Web.Plane`
   `kind: :operator` + `target_org_id` produces exactly the impersonation actor above. This is
   the seam that makes "operator opens an account (= a tenant org) and sees its tickets/customers
   masked" work with the SAME `Samen.Web.CRM`/`Billing`/`Support` LiveViews — no operator-specific
   views. **This is fully specified and Build-ready.**

2. **Token-blind cross-tenant aggregate** (`Samen.Aggregate.Actor`, T4.2 — `operator_aggregate`,
   no `org_id`) — the operator's MRR/volume-over-tenants view. This reads the aggregate domain
   with the singleton actor (no PII by construction — no `pii_` column exists to mask). The
   existing `OperatorDashboardLive` moves to `Samen.Web.Operator.AggregateLive` reading through a
   mount whose `namespace` points at the host's aggregate domain (`Driftwood.Aggregate`). Same
   `Module.concat` derivation, same struct.

**What is Phase 2 (the minimal seam, explicitly deferred):** a *native operator CRM* where the
operator's accounts list is literally `Samen.Scopes.Identity.Org` rows read on an operator-scoped
plane (the SaaS company's own org whose "customers" are the tenant orgs), with per-account drill
into that tenant's masked CRM/Billing/Support. ADR-009 defines the seam — `Samen.Web.Plane`
`kind: :operator` already carries `operator_id` + `target_org_id`, and the mount already threads
the namespace — but the operator-CRM *account list view* (reading Identity.Org as accounts via an
operator-scoped read) is a Phase-2 deliverable. Today's Build ships (1) + (2) over the existing
impersonation + aggregate kernel actors, which is enough to prove one module renders both planes.

---

## 6 · Testability — `samen_web` tested standalone

`samen_web` cannot render CRM pages without real CRM resources + data, and it must not depend on
driftwood. So `samen_web` ships a **test-support host** in `test/support/`:

- **`Samen.WebTest.Repo`** — a real AshPostgres repo against a throwaway test DB
  (`samen_web_test`), created + migrated by the suite (the ADR-005 pattern: a standalone lib
  exercising DB effects owns a scratch DB).
- **`Samen.WebTest.Crm` / `.Billing` / `.Support`** — Ash domains that `use Samen.Scopes.Crm`
  (etc.) with `otp_app: :samen_web, repo: Samen.WebTest.Repo, namespace: Samen.WebTest.Crm`, and
  **fresh abbrevs** reserved in the global registry (`swc/swp/…`, the same collision-avoidance
  every host does — Driftwood `Driftwood.Crm` moduledoc). This gives `samen_web` its OWN
  materialized resources, so the framework LiveViews have something real to read.
- **Migrations** — copied `Samen.Migration` templates for the three scopes (ADR-004 pattern),
  run against `samen_web_test`, so catalog rows exist and PII vault routing is live.
- **Seed helpers** — insert a handful of companies/contacts/customers/tickets so the render tests
  assert real rows.

The render tests use `Phoenix.LiveViewTest`:

- **tenant plane** — mount `Samen.Web.CRM.ContactsLive` with a tenant-plane mount over
  `Samen.WebTest.Crm`, assert a seeded contact's name/email render **in the clear**.
- **operator plane** — mount the SAME LiveView with an operator/impersonation-plane mount, assert
  the same contact renders `••••` and the vault token is **absent** from the DOM.
- **UI unit** — the moved ADR-008 kit tests (`%Masked{}` → `••••`, token absent) run against
  `Samen.UI` directly.

This makes the two-plane guarantee a `samen_web`-local test, independent of any vertical — the
proof that the framework module masks correctly lives with the framework, not with driftwood.

The abbrev registry is global (`samen_core/priv/abbrev_registry.json`), so `samen_web`'s
test-support mounts reserve their own abbrevs (append-only rows) — no `samen_core` code changes,
consistent with every host mount to date.

---

## 7 · Migration map — exact files, and how driftwood + pawchart mount the result

### 7.1 MOVE into `samen_web` (de-hardcode where noted)

| From (driftwood-local) | To (`samen_web`) | Change |
|---|---|---|
| `lib/driftwood_web/ui_kit.ex` (`DriftwoodWeb.UIKit`) | `lib/samen/ui.ex` (`Samen.UI`) | rename ns; split `module_nav` (freight group → host `:extra` slot) |
| `priv/static/assets/samen_ui.css` | `priv/static/assets/samen_ui.css` | byte-identical |
| `lib/driftwood_web/crm_companies_live.ex` | `lib/samen/web/crm/companies_live.ex` | de-hardcode via `Samen.Web.Mount`; import `Samen.UI` |
| `lib/driftwood_web/crm_contacts_live.ex` | `lib/samen/web/crm/contacts_live.ex` | de-hardcode |
| `lib/driftwood_web/crm_pipeline_live.ex` | `lib/samen/web/crm/pipeline_live.ex` | de-hardcode |
| `lib/driftwood_web/billing_live.ex` | `lib/samen/web/billing/overview_live.ex` | de-hardcode |
| `lib/driftwood_web/billing_invoices_live.ex` | `lib/samen/web/billing/invoices_live.ex` | de-hardcode |
| `lib/driftwood_web/billing_plans_live.ex` | `lib/samen/web/billing/plans_live.ex` | de-hardcode |
| `lib/driftwood_web/support_live.ex` | `lib/samen/web/support/tickets_live.ex` | de-hardcode |
| `lib/driftwood_web/support_ticket_live.ex` | `lib/samen/web/support/ticket_live.ex` | de-hardcode |
| `lib/driftwood/crm_reads.ex` (`Driftwood.CrmReads`) | `lib/samen/web/crm/reads.ex` (`Samen.Web.CRM.Reads`) | resource+repo from `Mount` |
| `lib/driftwood/billing_reads.ex` | `lib/samen/web/billing/reads.ex` | from `Mount` |
| `lib/driftwood/support_reads.ex` | `lib/samen/web/support/reads.ex` | from `Mount` |
| `lib/driftwood_web/operator_dashboard_live.ex` | `lib/samen/web/operator/aggregate_live.ex` | mount over host aggregate domain |
| `lib/driftwood_web/ui_kit_live.ex` (`/ui-kit` preview) | `lib/samen/web/ui_kit_live.ex` | rename ns (living catalog) |

### 7.2 STAYS driftwood-local (the freight 20% — vertical-specific)

- `lib/driftwood_web/broker_live.ex` — the freight dispatch board / load board / driver roster.
  This is Driftwood's vertical UI (freight-shaped), not an inherited scope. It KEEPS its
  hand-rolled markup or optionally imports `Samen.UI` components — out of scope for ADR-009's
  "inherited UI" mandate.
- `lib/driftwood_web/operator_impersonation_live.ex` — reads `Driftwood.Reads` (freight driver
  roster / load board), which are vertical resources. The *masked-impersonation plane* concept is
  framework (§5), but this specific view renders freight resources, so it stays driftwood-local
  for now; the CRM/Billing/Support pages already render masked under `plane: :operator` via the
  framework LiveViews, which is the reusable proof.
- `lib/driftwood/reads.ex`, `aggregate.ex`, `operator_dashboard.ex`, `context.ex`, freight
  resources — all vertical.

### 7.3 DELETE from driftwood after the move

- `lib/driftwood_web/ui_kit.ex`, `crm_*_live.ex`, `billing_*_live.ex`, `support_*_live.ex`,
  `operator_dashboard_live.ex`, `ui_kit_live.ex` — deleted (now inherited from `samen_web`).
- `lib/driftwood/crm_reads.ex`, `billing_reads.ex`, `support_reads.ex` — deleted (promoted).
- `priv/static/assets/samen_ui.css` — deleted (served from `samen_web`'s priv).

### 7.4 How driftwood mounts the result

- **`mix.exs`**: add `{:samen_web, path: "../samen_web"}`.
- **`endpoint.ex`**: `Plug.Static` `from: {:samen_web, "priv/static/assets"}, only:
  ~w(samen_ui.css)`.
- **`router.ex`**: replace the 11 hand-written `live "/crm/…"` / `"/billing/…"` / `"/support/…"`
  routes + `/operator/aggregate` + `/ui-kit` with `import Samen.Web.Router` and the
  `samen_module_routes` one-liners (§3.4). `/broker` and `/operator/impersonate` stay.
- The driftwood LiveView **tests** for the moved pages either move to `samen_web` (the render
  logic is now there) or become thin route-smoke tests asserting the mounted route boots 200 with
  the driftwood mount — the deep masking assertions live in `samen_web`.

### 7.5 How pawchart mounts the result (the payoff)

PawChart has no web layer today. It gains the inherited Billing UI it currently cannot show:

- **`mix.exs`**: add `phoenix`, `phoenix_live_view`, `phoenix_html`, `bandit`, `phoenix_pubsub`,
  and `{:samen_web, path: "../samen_web"}` (pawchart currently has none of these — this is the
  new adopter that proves the framework isn't driftwood-shaped).
- Add a minimal `PawChartWeb.Endpoint` + root layout (linking `/assets/samen_ui.css`) +
  `PawChartWeb.Router` with `samen_module_routes :billing, PawChart.Billing, repo:
  PawChart.Repo, plane: :tenant`.
- Result: PawChart serves `/billing`, `/billing/invoices`, `/billing/plans` over ITS
  `PawChart.Billing.*` resources with the identical look — zero UI code, one router line. This is
  the ADR-004 inheritance story finally true on the UI side.

Adding a web endpoint to pawchart expands its `ci.sh` (a route-boot smoke step), but its existing
17-step verifier gate is unchanged (no scope/data change). Whether pawchart adopts in this
workflow or is a registered follow-up is a Build-phase scoping call; the contract here makes it a
~30-line adoption either way.

---

## 8 · Consequences

**Positive**

- The inherited-80% product UI is now framework-level: every vertical inherits CRM/Billing/Support
  pages + the component kit + the two-plane masking by mounting `samen_web`, not by copying 11
  LiveViews. This is the thesis ("every proof feature levels up the core framework, not stays
  vertical-local") made real on the UI plane.
- `samen_core` is untouched — the web dep lives in `samen_web`. Its 842-test suite + verifier gate
  stay green by construction (no kernel change).
- The masking invariant is preserved by construction and now *tested in the framework* (§6), so
  the guarantee travels with the reusable code, not with one vertical.
- One canonical UI definition: a component fix or a new inherited page ships to every vertical on a
  `samen_web` dep bump — the same anti-drift posture ADR-004/ADR-005 won on the data side.

**Negative / accepted**

- A new Mix project (`samen_web`) + its own `ci.sh` wiring (compile-warnings-as-errors, the
  standalone render tests against `samen_web_test`, the `Samen.UI` masking tests). Accepted: this
  is the ceremony ADR-008 deferred, now earned by the full inherited-UI promotion (not just a CSS
  file). Root `ci.sh` gains a `samen_web` step.
- The `Samen.Web.Mount` struct + router macro are indirection the current direct-reference code
  lacks. Mitigated by the struct being tiny + fully test-covered, and by the payoff (a 5-line host
  mount) being the whole point.
- The two operator surfaces shipped now (impersonation over CRM/Billing/Support + token-blind
  aggregate) are the seam, not the full operator CRM; the native "accounts = Identity.Org list"
  view is Phase 2 (§5.3), explicitly deferred to keep this change unambiguous
  (feedback_scope_decomposition memory: ship the seam + phase the rest, don't attempt the 50-file
  refactor).

**Neutral**

- `broker_live.ex` and `operator_impersonation_live.ex` stay driftwood-local (freight-shaped);
  they may optionally consume `Samen.UI` components but are not "inherited scopes."
- The abbrev registry stays global; `samen_web`'s test-support mounts reserve their own abbrevs
  (append-only, no kernel code change) — consistent with every host to date.

## 9 · Verification (the gate the Build/Rewire phases must keep green)

- **Before + after:** the root `ci.sh` (spikes + samen_core 842 tests + demo gate + driftwood
  20-step gate + pawchart 17-step gate) stays green. Run before the change to capture the baseline,
  after to prove no regression.
- **`samen_web` standalone:** `mix compile --warnings-as-errors` clean; the render tests (tenant
  clear / operator `••••` / token absent) + the `Samen.UI` masking tests green against
  `samen_web_test`. Added as a new root `ci.sh` step.
- **Driftwood self-verify (booted, rendered text):** boot the host, seed an org, and read rendered
  text on the framework-mounted routes:
  `"$BIN" goto "http://127.0.0.1:4031/crm/contacts?org=<uuid>"; "$BIN" text | grep` the seeded
  contact in the clear (tenant plane); the operator/impersonation route shows `••••` and the vault
  token is absent. `/assets/samen_ui.css` returns 200 `text/css` from the `samen_web` priv.
- **PawChart (if adopted this workflow):** `/billing?org=<uuid>` boots 200 and renders
  `PawChart.Billing.*` rows with the shared look — the same-look, zero-UI-code proof.
