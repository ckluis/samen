# ADR-013 — Demo coherence: home, current-org resolution, workspace switcher, and the 5-tenant seed

- **Status:** Accepted (design; the Build phase implements this contract)
- **Date:** 2026-07-09
- **Task:** Make the Driftwood reference app a **coherent, navigable, richly-seeded** demo of
  Samen's three-plane model — so a person can SEE how it works without reading code. Fix the
  entry model: no page dead-ends on a missing `?org=`, no UUID is ever typed, the sidebar
  workspace chevron is a real tenant picker, the operator "Open account →" cleanly enters a
  tenant, `/chat` lists the current org's threads, and 5 named brokerages are fully populated.
- **Deciders:** opus (framework layer), grounded in the owner's mental model — OPERATOR =
  Driftwood Ops (SaaS-staff) dashboard over ALL tenant accounts (support + analytics + CRM/leads);
  TENANT = the freight-specific modules for ONE brokerage; SHARED = helpdesk/chat/billing, the
  same objects with a DIFFERENT PURPOSE per plane.
- **Builds on:**
  - **ADR-009** (`samen_web`, the two-plane pattern, `Samen.Web.{Mount,Plane,Router,Live}`,
    the framework CRM/Billing/Support LiveViews + `assign_mount/2`).
  - **ADR-010** (the operator plane; the **identity line** = `OrgScope` by `org_id` +
    `PiiResolution` by `plane`; `Samen.Web.Operator.{org_id/1, scope/1, impersonation_plane/3}`;
    the operator seat is the operator org on the **tenant** plane, clear).
  - **ADR-012** (the flagship cross-plane chat; `Samen.Web.Chat.{ThreadsLive,ThreadLive,Reads}`,
    the 3-state identity model).
- **Supersedes / touches:** nothing. **`samen_core` is UNTOUCHED** (842 green; the only
  sanctioned append remains abbrev-registry rows for existing scopes, and this ADR adds none).
  All framework mechanism (current-org resolution, the switcher, the chat inbox default,
  the tenant-name label) lands in `samen_web`. The demo landing (`/` → operator) and the
  5-tenant seed are **Driftwood-specific**.

---

## 1 · Context — the demo is correct but reads as broken

Every plane, mask, mount, and unfurl is *built* (ADR-009 → ADR-012). But a person opening the
app hits a wall of dead-ends, so the coherence is invisible:

1. **`/` is a bare HTML stub** (`DriftwoodWeb.PageController.index/2`) linking three raw paths.
   It is not the operator dashboard; it does not show the accounts; it is a boot-curl artifact.
2. **Every tenant + shared page reads the org from a query param and dead-ends without it.**
   `ContactsLive.mount/3`: `org_id = Map.get(params, "org")`; `load(socket, nil)` renders the
   "No org selected. Append `?org=<uuid>`" card. Same in `ThreadsLive` (the owner's exact
   complaint: "even /chat just says 'no org selected'"), and every CRM/Billing/Support/Marketing
   page. The demo requires **hand-typing a UUID** into the URL to see anything.
3. **The sidebar "workspace chevron" is a dead glyph.** `Samen.UI.sidebar/1` renders a static
   `<div class="col">⌄</div>` — it looks like a workspace switcher but does nothing.
4. **The operator "Open account →" is a bare query link** —
   `href={"/crm/contacts?org=#{a.tenant_org_id}"}` — it neither persists the choice (next click
   drops back to no-org) nor sets the impersonation session, so the drill-in is not the masked
   operator experience the model promises.
5. **The tenant page header says "Workspace", not the tenant's name.** `title`/`crumb_root`
   come from `Mount.label/3` **static** copy baked into the router (`title: "Blue Ridge
   Logistics"`), so when the current org is *Summit* the header still reads "Blue Ridge
   Logistics" (or the neutral "Workspace" default). The header does not track the current org.
6. **Only ~2 tenants are seeded, and one is sparse.** `dev_seed/0` fully populates Blue Ridge
   Logistics; the "second brokerage" (`b…002`) is freight-only (no CRM/billing/support/chat
   inherited rows). `OperatorSeeds` books exactly those two. The accounts list has two rows;
   four of the framework modules render for only one org.

The root cause of (2)–(5) is a single missing framework primitive: **there is no notion of a
"current org" resolved from the session.** `org_id` lives only in the URL. This ADR introduces
that primitive in `samen_web`, makes the switcher and the operator drill-in *write* it, defaults
it sensibly in dev, and seeds five real brokerages so every module is populated on every plane.

**Design invariant (do not violate):** the masking line is the plane line (ADR-010 §5). Nothing
here reads or writes a mask. Current-org resolution only decides *which org's data a page reads*;
`PiiResolution` still decides clear-vs-`••••` by `actor.plane`, unchanged. Verify after: tenant
plane clear, operator/impersonation plane `••••`.

---

## 2 · The mental model, stated once (the north star for the IA)

One BEAM node, one substrate, three planes. A person landing in the demo is a **Driftwood Ops
employee** (SaaS staff). The IA makes the three planes and their shared objects legible:

| Plane        | Whose seat        | What it is                                                                 | Org context                             | PII |
|--------------|-------------------|----------------------------------------------------------------------------|-----------------------------------------|-----|
| **OPERATOR** | Driftwood Ops     | Cross-tenant control plane: Accounts (all 5 brokerages) · Platform billing (MRR/dunning) · Desk (SaaS tickets) · Portfolio (token-blind aggregate) · Leads (operator CRM/prospects). | The **operator org** (Samen SaaS, Inc.) over its OWN book of business. | **clear** (the SaaS owns this data) |
| **TENANT**   | one brokerage     | Freight ops (broker console: carriers/shippers/loads/dispatch/settlement) + the inherited CRM · Billing · Support · Marketing for THAT brokerage. | ONE **tenant org** (the current org).   | **clear** (the org over its own data) |
| **SHARED**   | either plane      | Helpdesk/chat/billing objects — SAME resources, DIFFERENT purpose per plane (see §6). | inherits the acting plane's org.        | per plane |

The two ways the two planes connect:
- **Down (drill-in):** operator "Open account →" enters a tenant. Two grades — (a) *act-as* the
  tenant on the TENANT plane (clear, for filling out / QA'ing the demo), and (b) *impersonate*
  the tenant on the OPERATOR plane (masked `••••`, the real support drill-in). §5 specifies both.
- **Up (return):** a persistent "You are viewing **&lt;tenant&gt;** · Return to Driftwood Ops"
  banner + the switcher's "Driftwood Ops" entry take you back to the operator dashboard.

---

## 3 · (a) HOME / LANDING — `/` resolves to the OPERATOR dashboard

**Decision.** `/` renders the **operator plane** (Driftwood Ops), not a stub and not a tenant page.
You land as a Driftwood Ops employee looking at all five accounts. The operator plane needs **no
tenant org** — it is cross-tenant, scoped to the operator org itself (ADR-010: the operator seat is
the operator org on the tenant plane, clear).

- **Where:** Driftwood-specific. `DriftwoodWeb.PageController.index/2` is replaced by a redirect
  to `/operator/accounts` (the operator home). Keep `/healthz` returning `ok` (the boot-curl
  probe is unchanged). The operator routes are already mounted framework-side via
  `samen_operator_routes Driftwood.Operator` (ADR-010) — `/` just points at them.
- **Why a redirect, not a new dashboard LiveView:** the accounts page already IS the operator
  home — metrics band (Accounts · Healthy · At-risk · Platform MRR) over the accounts table, with
  the four-tab operator nav (Accounts · Platform billing · Desk · Portfolio). Redirecting reuses
  the ADR-010 surface verbatim; no duplicate landing to keep in sync. (If a future vertical wants
  a distinct splash, it overrides `/` locally — the framework does not force one.)
- **Operator home reachability:** the operator nav gains a **Leads** item (operator CRM/prospects,
  §6) and, in the operator sidebar footer, the workspace switcher (§5) so you can jump into any
  tenant from the home screen. The operator plane never dead-ends: it resolves its org via
  `Samen.Web.Operator.org_id/1` (mount label → app env → single seeded row), which the seed
  guarantees.

**Net:** open `/` → Driftwood Ops dashboard, five accounts visible, zero params typed.

---

## 4 · (b) CURRENT-ORG RESOLUTION — the key fix (framework, `samen_web`)

**The problem restated.** Tenant-plane + shared pages need to know *which tenant org* to read.
Today that is `Map.get(params, "org")` with a dead-end fallback. We need a **session-resolved
current org** with a sensible dev default, `?org=` still honored but optional, and no UUID ever
typed.

### 4.1 · The resolver — `Samen.Web.CurrentOrg` (new framework module)

A new `samen_web` module `Samen.Web.CurrentOrg` owns the resolution order. It is the single place
every tenant/shared LiveView asks "what org am I acting on?" — replacing the inline
`Map.get(params, "org")` + `load(socket, nil)` dead-end.

**Resolution order (first hit wins):**

1. **`params["org"]`** — an explicit `?org=<uuid>` in the URL. Still fully supported (deep links,
   the operator drill-in target, tests). When present it is also **written back to the session**
   (§4.3) so subsequent same-plane navigation keeps it without re-typing.
2. **`session["samen_current_org"]`** — the org last selected via the switcher or the operator
   drill-in (§5). This is what makes navigation sticky: pick Summit once, every CRM/Billing/
   Support/Chat page reads Summit until you switch.
3. **The mount's default-org seam** — `Mount.label(mount, :default_org_id, nil)`. A host may pin a
   default tenant org on the mount (data on the mount, not code). Driftwood sets this to the first
   seeded brokerage (Blue Ridge Logistics) in dev — see §4.4.
4. **First-tenant discovery** — if still nil, the resolver asks the mount for the host's tenant
   directory (§4.2) and takes the first org. This guarantees a *populated* page in any freshly
   seeded environment even if no default label was set. Fail-safe: empty directory → `nil` →
   the page renders an **empty-but-not-dead** state (§4.5), never the "type a UUID" card.

```
def resolve(mount, params, session) do
  params["org"]
  || session["samen_current_org"]
  || Mount.label(mount, :default_org_id, nil)
  || first_listable_org_id(mount)   # §4.2 directory, else nil
end
```

The operator/aggregate planes do **not** use this (they scope to the operator org via
`Samen.Web.Operator.org_id/1`); `CurrentOrg` governs only the **tenant** and **shared** planes.

### 4.2 · The tenant directory — `Samen.Web.CurrentOrg.list_orgs/1` (powers switcher + default)

The switcher and the first-tenant default both need "the list of tenant orgs this seat may act
on." Framework-side, this is the operator org's **accounts** — each account row is a tenant org
(ADR-010 `Reads.accounts/3`), carrying `tenant_org_id` (the real id in the vertical namespace) +
`name`. `list_orgs/1`:

- On a mount that can see the operator namespace (the operator/aggregate mounts carry
  `operator_org_id`), returns `[{tenant_org_id, name}, …]` from `Reads.accounts/3`.
- On a plain tenant/shared mount (CRM/Billing/Support/Chat), the accounts live in a *different*
  namespace (the operator's), so the mount exposes the directory through a **label seam**:
  `Mount.label(mount, :org_directory, {mod, fun, args})` — an MFA the host wires that returns
  `[{org_id, name}, …]`. Driftwood points it at a tiny local function over `Driftwood.Operator`
  accounts (§7). This keeps `samen_web` from hardcoding "the operator namespace" into the tenant
  mounts while still giving every tenant page the switcher list. Absent the seam, `list_orgs/1`
  returns `[]` and the switcher hides (graceful).

**Name resolution falls out of the directory:** the current org's display name is
`list_orgs(mount) |> List.keyfind(current_org_id, 0)` → the tenant name. This is what fixes the
"header says Workspace" bug (§4.6) — the header reads the *resolved* name, not a static label.

### 4.3 · Writing the current org — a tiny controller, not a LiveView param dance

A LiveView cannot set a cookie mid-mount (the session is established on the dead render). So the
**write** side is a plain Phoenix controller action, framework-side:

- `Samen.Web.SessionController.put_current_org/2` (new) — `POST/GET /session/org/:org_id` — sets
  `session["samen_current_org"] = org_id` and redirects to a `return_to` (default `/crm/contacts`).
  This is the switcher's target and the operator drill-in's target.
- Mounted by a one-line host helper `samen_session_routes()` in `Samen.Web.Router` (like the other
  route macros), so every vertical inherits the endpoint.
- Rule of thumb (kept from ADR-010): reads happen in LiveViews; the **one** state-changing nav
  (choose current org) goes through a controller so the cookie is set on a real HTTP response.

`?org=<uuid>` deep links also write-back: when `CurrentOrg.resolve/3` takes the param branch, the
LiveView issues a `push_patch`-free assign and the next controller-routed nav persists it; simplest
correct form — a deep link with `?org=` shows that org immediately AND the sidebar links carry it,
so within-session it sticks even before any controller hit. (`?org=` remains a pure read; the
controller is the durable write.)

### 4.4 · The sensible dev default (Driftwood)

Driftwood, in dev, wants "open any tenant page → see Blue Ridge Logistics fully populated" with
zero setup. Two data-on-the-mount lines in the router accomplish it:

- `labels: %{default_org_id: Driftwood.Seeds.blue_ridge_org_id(), org_directory: {Driftwood.Directory, :orgs, []}}`
  on the CRM/Billing/Support/Marketing/Chat mounts.

`default_org_id` is resolution step 3; `org_directory` powers the switcher + name. If neither were
set, step 4 (first-listable) still lands on a populated org. Result: **no dead-end, no UUID, sane
default** — exactly the mandate.

### 4.5 · The empty state replaces the dead-end (framework)

The "No org selected. Append `?org=<uuid>`" card is deleted from every LiveView. Two outcomes only:

- **Resolved org (the common case):** render the module, populated.
- **No org resolvable at all** (empty directory, unseeded DB): render a friendly **"No tenant
  accounts yet — run `mix driftwood.seed`"** card with a link back to the operator dashboard. This
  is a *seed-state* message, not a *type-a-UUID* instruction, and it never appears once seeded.

### 4.6 · Header + crumb read the resolved tenant name (fixes "Workspace")

`crm_sidebar/1`, `topbar` crumbs, and the chat header currently use `Mount.label(mount, :title,
"Workspace")` — static router copy. They switch to the **resolved current-org name**
(`CurrentOrg.name(mount, org_id)`, §4.2), falling back to the mount label, falling back to
"Workspace". So on Summit's contacts page the header reads **"Summit Freight Partners"**, on Blue
Ridge's it reads **"Blue Ridge Logistics"** — the header tracks the switcher. (The mount's static
`:title` becomes a *fallback* only, used when the directory can't name the org.)

---

## 5 · (c) WORKSPACE SWITCHER + operator drill-in (framework)

### 5.1 · The sidebar chevron becomes a real tenant picker

`Samen.UI.sidebar/1`'s dead `<div class="col">⌄</div>` becomes a real control. The sidebar gains a
`:switcher` slot; the CRM/Billing/Support/Chat sidebars fill it with a **workspace switcher**
component (`Samen.Web.CurrentOrg.switcher/1`, framework):

- Renders the current org's name + the chevron; on click, a dropdown lists `list_orgs(mount)`
  (all 5 brokerages) plus a pinned **"Driftwood Ops"** entry (return to the operator plane).
- Each brokerage row is a link to `GET /session/org/<tenant_org_id>?return_to=<current_path>`
  (§4.3) — sets the session current org, redirects back to the same module for the newly chosen
  org. Pick Summit on `/crm/contacts` → land on `/crm/contacts` showing Summit, header now
  "Summit Freight Partners".
- The **"Driftwood Ops"** row links to `/operator/accounts` — the clean way back up.
- Implemented once in `samen_web`; every tenant/shared vertical inherits it. On the **operator**
  sidebar the same switcher renders in the footer as an "act as a tenant →" launcher (the down
  path), plus the operator entry is the current highlight.

Interaction is a plain `<details>`/link dropdown (no JS beyond native disclosure) so it works on
the dead render and needs no new hooks — matching the ADR-012 "works before the socket connects"
posture.

### 5.2 · Operator "Open account →" — two clean grades of entry

The bare `href={"/crm/contacts?org=#{tenant_org_id}"}` is replaced by an explicit entry with the
right plane. On the operator Accounts row, two actions:

1. **"Open account →" (act-as / clear):** `GET /session/org/<tenant_org_id>?return_to=/broker` —
   sets the session current org and lands you in that tenant's freight console + inherited modules
   on the **TENANT plane (clear)**. This is the "fill out and see how it works" path the owner
   wants: you become that brokerage and every module is populated and legible. The persistent
   "viewing &lt;tenant&gt; · Return to Driftwood Ops" banner (§5.3) makes the context obvious.
2. **"Impersonate (masked) →":** the EXISTING ADR-009/010 path —
   `/operator/impersonate?org=<tenant_org_id>` (Driftwood-local, freight-shaped) and the
   `/operator/desk-chat?org=<tenant_org_id>` operator-desk chat — reads the tenant's world on the
   **OPERATOR plane (`••••`)**, the real support drill-in. Unchanged masking; this ADR only makes
   the link explicit and labels the two grades so the demo shows *both* the clear act-as and the
   masked impersonation of the same tenant, side by side.

Both set (or carry) the current org; grade (1) writes the session (durable), grade (2) uses
`?org=` on the operator-plane mount (the plane, not the session, is what masks). The masking
correctness is exactly ADR-010's — **verify after: (1) clear, (2) `••••`.**

### 5.3 · Operator ⟷ tenant ⟷ operator, cleanly

- **Operator → tenant:** switcher "act as →" or Accounts "Open account →" (session current org set).
- **While in a tenant:** a framework top-of-page banner "You are viewing **&lt;tenant&gt;** (acting
  as tenant) · **Return to Driftwood Ops**" renders whenever the session current org is set AND the
  plane is tenant. The link clears the intent and returns to `/operator/accounts`.
- **Tenant → operator:** the banner link or the switcher's "Driftwood Ops" row.
- **Switching tenants:** the switcher — no return-to-operator round trip needed.

The current org is session state; "return to Driftwood Ops" simply navigates to the operator plane
(which ignores the session current org — it is cross-tenant). No mode flag to get stuck in.

---

## 6 · (d) THE THREE PLANES, made visibly coherent

The nav itself teaches the model. Two distinct sidebars, and the SHARED modules show their
tenant-purpose vs operator-purpose in copy:

### 6.1 · Operator sidebar (the Driftwood Ops seat)

Group **"Operator plane"**: Accounts · Platform billing · Desk · Portfolio · **Leads** (new). Plus
the switcher footer ("act as a tenant →"). Copy frames each as cross-tenant:

- **Accounts** — all 5 brokerages (the operator CRM of *customers*).
- **Platform billing** — the brokerages' subscriptions TO Driftwood (MRR, dunning) — operator
  purpose of Billing.
- **Desk** — tickets brokerages filed WITH Driftwood support — operator purpose of Support.
- **Portfolio** — token-blind cross-tenant aggregate (freight lanes/tiers, `⊘` suppression).
- **Leads** — the operator's OWN CRM prospects/pipeline (brokerages not yet customers). Reuses the
  framework CRM/Marketing LiveViews scoped to the operator org on the tenant plane (clear) — same
  code, operator data. (ADR-011 Marketing/Leads generalizes cleanly; no new LiveView.)

### 6.2 · Tenant sidebar (one brokerage seat)

The switcher header (current brokerage + chevron) → freight "Operations" group (Driftwood 20%,
local) → inherited **CRM · Billing · Support · Marketing · Chat** groups (framework). Copy frames
each as this-brokerage:

- **CRM** — the brokerage's carriers/shippers/contacts/pipeline.
- **Billing** — the brokerage's OWN customers/invoices (freight settlements) — tenant purpose.
- **Support** — the brokerage's OWN helpdesk tickets from its carriers/shippers — tenant purpose.
- **Chat** — the brokerage talking TO Driftwood support (the tenant side of the cross-plane chat).

### 6.3 · SHARED modules: one object, two purposes (the crux)

| Object   | Tenant purpose (brokerage seat)                          | Operator purpose (Driftwood Ops seat)                        |
|----------|----------------------------------------------------------|--------------------------------------------------------------|
| Billing  | the brokerage's invoices to ITS carriers/shippers        | the brokerage's subscription TO Driftwood (MRR/dunning)      |
| Support  | the brokerage's helpdesk (its carriers file tickets)     | tickets the brokerage filed WITH Driftwood (SaaS desk)       |
| Chat     | the brokerage → Driftwood support (clear, its own side)  | Driftwood desk → the brokerage's threads (masked `••••`)     |

The same LiveViews render both; the plane + org context (this ADR's current-org + ADR-010's
operator scope) select which. The nav copy + the "acting as" banner make the *purpose* explicit so
a viewer never confuses "the brokerage's billing" with "the brokerage's bill from us."

---

## 7 · (e) CHAT inbox — `/chat` lists the current org's threads

**Decision.** `Samen.Web.Chat.ThreadsLive` stops reading `Map.get(params, "org")` with the
"no org selected" dead-end and instead resolves via `Samen.Web.CurrentOrg.resolve/3` (§4). On the
seeded dev DB `/chat` immediately lists the current brokerage's threads (the ADR-012 seeded
cross-plane thread + the new per-tenant threads from §8). The header reads the resolved tenant name
(§4.6), the plane note stays ("your org in the clear" / "operator desk · masked"), and the new-
conversation + disclosure controls stay tenant-plane-only.

- **Where:** framework (`ThreadsLive`, `ThreadLive`, and the thread-path helper all go through
  `CurrentOrg`). The `?org=` deep link still works (resolution step 1). The operator-desk chat
  (`/operator/desk-chat`) keeps its `?org=<tenant>` operator-plane behavior for the masked drill-in.
- **Net (the owner's exact complaint, fixed):** `/chat` shows an inbox with threads by default,
  never "no org selected."

Every other module's `no_org` dead-end is removed the same way in the same pass (CRM
companies/contacts/pipeline, Billing overview/invoices/plans, Support tickets, Marketing
campaigns/segments/leads) — one shared resolver, one shared empty state (§4.5).

---

## 8 · (f) THE 5-TENANT SEED PLAN

**Decision.** Seed **five named freight brokerages**, each **fully populated across every module
and plane**, plus the operator org's book of business over all five. This is Driftwood-specific
(the vertical proves the framework); the framework contributes only the resolver/switcher/inbox
that make the seed navigable.

### 8.1 · The five brokerages (fixed uuids so dev links + tests are stable)

| # | Org id (`b1112d00-…`) | Name                        | Lane      | Tier/MRR    | Health (for the accounts band) |
|---|-----------------------|-----------------------------|-----------|-------------|--------------------------------|
| 1 | `…001`                | **Blue Ridge Logistics**    | TX→CA     | growth $2,500 | healthy                      |
| 2 | `…002`                | **Summit Freight Partners** | IL→GA     | growth $3,000 | healthy                      |
| 3 | `…003`                | **Gulf Stream Carriers**    | FL→NY     | scale  $4,800 | at-risk (1 past-due invoice) |
| 4 | `…004`                | **Cascade Freightways**     | WA→AZ     | starter $1,200 | healthy                      |
| 5 | `…005`                | **Ironline Brokerage**      | OH→TX     | scale  $5,200 | at-risk (dunning)            |

Names/lanes/tiers vary so the accounts table, Portfolio aggregate, and dunning surface look alive
(mixed health, mixed MRR, ≥2 orgs per cohort for the k-anon floor).

### 8.2 · Per-brokerage population (TENANT plane — every module non-empty)

For EACH of the five, `dev_seed/0` runs the full stack (today only #1 gets this; #2 is freight-only):

- **Freight ops** — `DogfoodScenario.build/1`: carriers/shippers/drivers/loads/dispatch/settlement
  + broker rollup (the 20% vertical), with the org's own lane/tier/MRR.
- **CRM** — companies (that brokerage's carriers/shippers/factoring partner), contacts (dispatchers/
  reps, PII), activities, pipeline opportunities across stages.
- **Billing (tenant purpose)** — the brokerage's OWN customers (its shippers), plans/prices,
  subscriptions, invoices (a mix of paid/open), payments.
- **Support (tenant purpose)** — the brokerage's helpdesk tickets from its carriers/shippers,
  conversations, messages, agents, SLA, CSAT.
- **Marketing** — campaigns/segments/leads (ADR-011), subscriber PII.
- **Chat (tenant side)** — ≥2 threads per org talking to Driftwood support, incl. one seeded
  cross-plane thread (ADR-012) with an object unfurl, mixed disclosure states.

Generalize the existing single-org helpers (`demo_all/1`, `seed_marketing/1`, `seed_chat/1`,
`DogfoodScenario.build/1`) to run over a **list** of the five org specs. The idempotency markers
already key on `org_id`, so re-running `mix driftwood.seed` stays safe. This is the bulk of the
work and it is all Driftwood-local.

### 8.3 · The operator org's book of business OVER all five (OPERATOR plane)

`OperatorSeeds` extends its `@accounts` from 2 to all 5 specs. Per account (ADR-010 shape):

- an operator-side ACCOUNT `Identity.Org` (slug = the tenant_org_id back-reference),
- its tenant-ADMIN `Identity.User` (PII the SaaS owns — clear) + admin membership,
- a `Billing.Customer/Subscription/Plan/Price/Invoice` — the brokerage's **subscription to
  Driftwood** (MRR per the tier); orgs #3 and #5 carry a **past-due** invoice for the dunning
  surface,
- 2 desk `Support.Ticket`s the brokerage filed WITH Driftwood (requester = the tenant-admin),
- **operator CRM Leads/prospects** — a handful of *not-yet-customer* brokerages (operator-org CRM
  contacts/opportunities on the tenant plane, clear) so the operator **Leads** surface (§6.1) is
  populated. New, small, operator-org-scoped.

Result: `/operator/accounts` shows 5 rows with mixed health; Platform billing shows 5 subscriptions
+ 2 dunning; Desk shows 10 SaaS tickets; Portfolio aggregates 5 orgs across cohorts; Leads shows the
prospect pipeline. The operator plane is a real book of business, not two rows.

### 8.4 · Framework vs Driftwood split (explicit)

| Concern                                                        | Layer                | Where |
|---------------------------------------------------------------|----------------------|-------|
| Current-org resolver (`CurrentOrg.resolve/3`, name, directory) | **framework**        | `samen_web/lib/samen/web/current_org.ex` |
| Session write endpoint (`SessionController` + `samen_session_routes`) | **framework**  | `samen_web/lib/samen/web/session_controller.ex`, `router.ex` |
| Workspace switcher component + sidebar `:switcher` slot         | **framework**        | `samen_web` `ui.ex` + `current_org.ex` |
| "Acting as &lt;tenant&gt; · Return to Ops" banner              | **framework**        | `samen_web` (shared component) |
| Remove `no_org` dead-ends; header/crumb read resolved name; chat inbox default | **framework** | all `Samen.Web.*Live` |
| `/` → operator redirect                                        | **Driftwood**        | `DriftwoodWeb.PageController` |
| The 5-brokerage seed (freight + CRM + billing + support + mktg + chat) | **Driftwood** | `driftwood/lib/driftwood/{seeds,operator_seeds}.ex` |
| `org_directory` MFA + `default_org_id` labels on the mounts    | **Driftwood**        | `DriftwoodWeb.Router`, small `Driftwood.Directory` |
| Operator Leads/prospect seed                                   | **Driftwood**        | `driftwood/lib/driftwood/operator_seeds.ex` |

Every mechanism that "every vertical inherits" (resolver, switcher, session endpoint, banner, inbox
default, tenant-name header) is framework. Only the demo landing choice and the concrete 5-tenant
data are Driftwood.

---

## 9 · Consequences

**Positive.**
- `/` lands on a populated operator dashboard; every tenant/shared page resolves an org from the
  session with a sane default — **no dead-ends, no typed UUIDs**. The owner's core complaint is
  gone.
- The chevron is a real switcher; the operator "Open account" cleanly enters a tenant (clear
  act-as) with the masked impersonation offered explicitly alongside; operator⟷tenant navigation is
  a two-click loop with a persistent "acting as" banner.
- Headers/crumbs track the current org (Summit reads "Summit Freight Partners"); `/chat` lists
  threads by default; all five brokerages are fully populated on every plane — the three planes are
  visibly coherent.
- Every fix that generalizes lives in `samen_web`, so PawChart / any future vertical inherits the
  navigable entry model for free. `samen_core` untouched.

**Negative / risks & mitigations.**
- **Masking regression risk** — a session current org must never grant clear PII on the operator
  plane. Mitigation: `CurrentOrg` governs only tenant/shared mounts; the operator/impersonation
  masking is untouched (plane, not org, masks). **Verify after:** tenant contacts clear, operator
  impersonation `••••`, operator-desk chat `••••`.
- **Session-vs-URL ambiguity** — `?org=` (step 1) overrides the session (step 2). Intentional
  (deep links win), documented; the switcher writes the session so normal nav is sticky.
- **Seed size / runtime** — 5× the seed volume. Mitigation: idempotency markers per org; keep row
  counts modest (demo, not load test); `mix driftwood.seed` stays a few seconds.
- **Empty-directory edge** — before seeding, pages show the "run `mix driftwood.seed`" card, not a
  dead-end. Acceptable and self-explaining.

**Test/CI posture (unchanged gates).** Keep all suites + `ci.sh` green before AND after (samen_web,
driftwood 20-step, demo, pawchart), `--warnings-as-errors` clean. New framework tests: resolver
order (param > session > default > first > empty), switcher lists orgs + writes session, header
shows resolved name, chat inbox lists seeded threads, and the masking verification above. Driftwood
tests: 5 orgs seeded + each module non-empty + operator accounts/billing/desk/portfolio/leads
populated.

---

## 10 · Build order (unambiguous handoff to the Build phase)

1. **Framework — `Samen.Web.CurrentOrg`** (`resolve/3`, `list_orgs/1`, `name/2`, `switcher/1`) +
   the `Mount` label seams (`:default_org_id`, `:org_directory`). No behavior change until wired.
2. **Framework — `Samen.Web.SessionController.put_current_org/2` + `samen_session_routes` macro.**
3. **Framework — swap every tenant/shared LiveView** from `Map.get(params, "org")` + `no_org`
   dead-end to `CurrentOrg.resolve/3` + the empty-state card; header/crumb read `CurrentOrg.name/2`.
   (CRM ×5, Billing ×3, Support ×2, Marketing ×3, Chat ×2.)
4. **Framework — `sidebar/1` `:switcher` slot + the switcher component + the "acting as" banner.**
5. **Driftwood — `/` → `/operator/accounts` redirect;** `Driftwood.Directory.orgs/0`; router mount
   labels (`default_org_id`, `org_directory`); operator "Open account" / "Impersonate" two-grade
   links.
6. **Driftwood — the 5-brokerage seed:** generalize `demo_all/1` + `DogfoodScenario.build/1` +
   marketing/chat seeds over the 5 specs; extend `OperatorSeeds.@accounts` to 5 + operator Leads.
7. **Verify:** boot `PORT=4036`, `mix driftwood.seed`, browse `/` → operator (5 accounts), switch
   to Summit, walk CRM/Billing/Support/Chat (populated, header = Summit), "Open account" clear +
   "Impersonate" masked; screenshot; grep for `••••` on the operator paths and clear names on
   tenant paths. Run all four `ci.sh` suites green, warnings-as-errors clean.

---

## 11 · What this ADR deliberately does NOT do

- It does not add auth/login (the seat is still the dev Driftwood-Ops employee; a real deploy
  derives the operator identity + the allowed tenant set from an authenticated session — the
  resolver's session read is the seam that real auth writes to later).
- It does not change any masking rule, vault path, or `PiiResolution` behavior.
- It does not touch `samen_core` (no kernel change; no abbrev-registry append — the five orgs reuse
  the existing scopes' tables).
- It does not build a bespoke operator "home" LiveView (the Accounts page IS the home; `/` redirects
  to it).
