# ADR-013 Build — navigation / entry framework fixes + 5-tenant seed

Implements the ADR-013 contract: session-resolved current org (no dead-ends, no typed UUIDs),
a functional workspace switcher, the operator two-grade drill-in, the chat inbox default, the
resolved tenant-name header, and Driftwood's `/`→operator landing + 5-brokerage seed.

Status: GREEN. samen_web 184 tests + driftwood full CI gate + pawchart CI gate + demo CI gate
all pass; `--warnings-as-errors` clean; masking verified unaffected (tenant clear / operator ••••).

## Framework API (samen_web — every vertical inherits)

### `Samen.Web.CurrentOrg` (new — `lib/samen/web/current_org.ex`)
- `resolve(mount, params, session)` — the ONE resolution order: `params["org"]` → `session["samen_current_org"]` → `Mount.label(mount, :default_org_id)` → first-listable org → `nil`. Never raises; nil only on an unseeded DB.
- `list_orgs(mount)` — `[{org_id, name}, …]` from the mount's `:org_directory` MFA seam, or (operator/aggregate mounts) directly from `Operator.Reads.accounts/3`. `[]` when unwired → switcher hides.
- `name(mount, org_id)` — the resolved display name (directory → mount `:title` → `"Workspace"`). Fixes the "header says Workspace" bug.
- `no_org?(mount, org_id)` — seed-state rule: true only when no org resolved AND the directory is empty (never the type-a-UUID dead-end).
- `return_path(uri)` — the switcher's same-module return target (path, query stripped).
- Components: `switcher/1` (native `<details>` tenant picker → `/session/org/<id>?return_to=…` + a pinned "Driftwood Ops" entry; `compact` hides the name in sidebar headers), `acting_as_banner/1` ("You are viewing <tenant> · Return to Driftwood Ops"), `no_org_card/1` (the "run `mix driftwood.seed`" seed-state card).

### `Samen.Web.SessionController` (new — `lib/samen/web/session_controller.ex`)
- `put_current_org(conn, %{"org_id" => …})` — `GET /session/org/:org_id` — writes `session["samen_current_org"]` and redirects to a **same-origin-sanitized** `return_to` (default `/crm/contacts`; an off-site or `//host` value is refused → no open redirect).

### `Samen.Web.Router`
- `samen_session_routes(opts)` — one-line macro mounting the session-write endpoint.

### `Mount` label seams (data on the mount, not code)
- `:default_org_id`, `:org_directory` (the resolver/switcher/name seams), `:tenant_landing`, `:impersonate_path` (the operator two-grade drill-in) — all added to the session-safe label whitelist in `mount.ex`.

### Touched framework surfaces
- `Samen.UI.sidebar/1`: the dead `<div class="col">⌄</div>` chevron becomes a `:switcher` slot.
- Every tenant/shared LiveView (CRM ×5, Billing ×3, Support ×2, Marketing ×4, Chat ×2) now resolves the org via `CurrentOrg.resolve/3`, threads `return_to` into the switcher, renders the acting-as banner + seed-state card (the "No org selected. Append ?org=<uuid>" dead-ends are all deleted), and the header/crumb read `CurrentOrg.name/2`.
- `Operator.AccountsLive`: "Open account →" is now the act-as/clear session-write (`/session/org/<id>?return_to=<tenant_landing>`); a new "Impersonate (masked) →" link is the existing operator-plane drill-in (`impersonate_path?org=<id>`).
- `Operator.Live`: the operator sidebar footer gains the "Act as a tenant →" switcher launcher.
- CSS appended to `priv/static/assets/samen_ui.css`: `.ws-switcher*`, `.op-act-as`, `.acting-as-bar`.

## Driftwood wiring

- `DriftwoodWeb.PageController.index/2`: `/` → redirect to `/operator/accounts` (land as a Driftwood Ops employee). `/healthz` unchanged.
- `Driftwood.Directory.orgs/0` (new): `[{tenant_org_id, name}]` over the operator account Orgs — the `:org_directory` MFA.
- `DriftwoodWeb.Router`: `samen_session_routes()`; a `@current_org_labels` map (`default_org_id: Blue Ridge, org_directory: {Driftwood.Directory,:orgs,[]}`) merged onto the CRM/Billing/Support/Marketing/Chat mounts; the operator mount carries `tenant_landing: "/broker"` + `impersonate_path: "/operator/impersonate"`.
- `Driftwood.Seeds`: `@brokerages` (5 fixed-uuid specs) + `dev_seed/0` loops `DogfoodScenario.build/1` + `demo_all/1` over all five (each fully populated: freight + CRM + Billing + Support + Marketing + Chat), rebuilds the aggregate over 5 orgs.
- `Driftwood.OperatorSeeds`: `@accounts` → 5 (health per spec; #3 Gulf Stream + #5 Ironline past-due for dunning); `seed_leads/0` seeds 4 not-yet-customer prospects (operator-org CRM Persons, early-funnel lifecycle) so `/marketing/leads?org=<operator>` is populated.

## Verification (dev server, seeded DB)

- `/` → 302 `/operator/accounts`; dashboard shows 5 accounts, metrics band (Accounts 5 · Healthy 3 · At risk 2 · Platform MRR $6700.00), two-grade drill-in links, the "Act as a tenant →" switcher.
- `/crm/contacts` with NO `?org=` → renders Blue Ridge (default), 12 contacts, no dead-end.
- `/session/org/<summit>?return_to=/broker` → 302 `/broker`; then `/crm/contacts` (session cookie) → header + crumb read "Summit Freight Partners".
- Switcher dropdown lists all 5 brokerages under "Workspaces" + "← Driftwood Ops (operator)".
- `/chat` with NO `?org=` lists the seeded thread (no "no org selected").
- Masking unaffected: tenant `/crm/contacts` + tenant chat room CLEAR; `/operator/desk-chat/<id>` room `••••`.
- Operator Platform billing (5 subs, 2 dunning), Desk (10 SaaS tickets), Portfolio (token-blind ⊘ over 5), Leads (4 prospects) all populated.

## Gates

samen_web 184 (was 162; +22 new: `current_org_test.exs`, `session_controller_test.exs`, chat-inbox-default + resolved-name tests, updated operator two-grade test). driftwood full CI gate, pawchart CI gate, demo tests + CI gate — all green, warnings-as-errors clean. `samen_core` untouched.
