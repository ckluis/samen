# ADR-011 — CRM enrichment: contact/company detail, activity timeline, email/sequences, prospecting, social — a real CRM in `samen_web`

- **Status:** Accepted (design; Build phase follows this contract, staged)
- **Date:** 2026-07-08
- **Task:** Framework-layer DESIGN of the CRM enrichment that turns today's three list pages
  (companies · contacts · pipeline) into a WORLD-CLASS CRM — contact & company **detail pages**
  with tabs, an **activity timeline** (over the existing `Activity` resource) with a
  **log-activity** composer, **email / sequences** (mounting the existing but unmounted
  Marketing scope) with consent/suppression enforced, **prospecting** (leads + a lifecycle
  stage), and **social** handles — every feature landing in `samen_web` so EVERY vertical
  (Driftwood + PawChart) inherits it; the vertical only proves it.
- **Deciders:** opus (framework layer), grounded in the owner mandate ("a real CRM, not a
  rolodex; every feature LEVELS UP the framework") and the vision doc's scope table
  (`company · person🔒 · opportunity · pipeline · activity · attachment` for CRM;
  `campaign · segment · subscriber🔒 · template · send · email_event · suppression` for Marketing).
- **Builds on:**
  - **ADR-009** (`samen_web`; the two-plane pattern; `Samen.Web.{Mount,Plane,Router}`; the
    framework CRM/Billing/Support LiveViews + reads; `Samen.UI` kit). The enrichment reuses the
    EXACT seams ADR-009 established — nothing new is invented at the plumbing layer.
  - **ADR-010** (operator plane; the identity line via `Samen.Api.PiiResolution`; the tabbed
    ticket-detail LiveView `Samen.Web.Support.TicketLive` — the structural template for a
    tabbed CRM detail page).
  - **ADR-004** (library-authored scope blueprints, host-materialized resources). The CRM
    `Activity`/`Attachment` and the whole Marketing scope ALREADY EXIST in `samen_core` as
    blueprints — this ADR MOUNTS and SURFACES them, it does not author kernel resources.
  - The kernel's `Samen.Api.PiiResolution` (`plane_of/1` + `impersonated?/1`) — the single
    vault chokepoint; and `Samen.Scopes.Marketing.Send`'s `:create_checked` action + its
    `SendWorker` (Oban, `:webhooks_out`) — the suppression red path already built and tested.
- **Supersedes / touches:** nothing. `samen_core` is **UNTOUCHED** (~833 green; the ONLY
  sanctioned change is append-only rows in `priv/abbrev_registry.json` for the Marketing mount).
  ALL new code is framework-level in `samen_web`; the Driftwood vertical only PROVES it (adds a
  `Marketing` domain module + seeds). `Samen.Web.Router.__routes__/2` gains two CRM detail routes
  and a `:marketing` route table — additive, no existing route changes.

---

## 1 · Context — the gap and the realization

Today `Samen.Web.CRM` is three **list** pages (`CompaniesLive`, `ContactsLive`, `PipelineLive`)
reading through `Samen.Web.CRM.Reads`. There is NO detail page, NO activity timeline, NO
email/outreach, NO prospecting, NO social. That is a rolodex, not a CRM.

The realization that makes this whole ADR fall out cheaply: **almost every resource this needs
already exists in the kernel and is already correctly PII-safe.** The design work is *surfacing*,
not *authoring*:

| Enrichment | Kernel substrate (ALREADY EXISTS) | This ADR adds (framework `samen_web`) |
|---|---|---|
| Contact detail | `<ns>.Person` (🔒 name/emails/phones + `job_title` + `custom` bag) | `Samen.Web.CRM.ContactLive` (tabbed) |
| Company detail | `<ns>.Company` | `Samen.Web.CRM.CompanyLive` (tabbed) |
| Activity timeline | `<ns>.Activity` (type `note/call/email/meeting/task`, subject/body/status/due_at, FKs → company/person/opportunity) | `Samen.UI.timeline/1` + `activities_for_*` reads + `log_activity` composer |
| Email / sequences | Marketing scope (7 resources, suppression-enforced `Send.:create_checked`, `SendWorker` Oban) — **built + tested, just UNMOUNTED** | `:marketing` route table + `Samen.Web.Marketing.*` LiveViews + `Reads` |
| Prospecting | `Person.custom` jsonb (Tier-1 bag) + `Segment` | `lifecycle_stage` custom field convention + a Leads view |
| Social | `Person.custom` jsonb (Tier-1 bag) | `social` custom-field convention rendered on contact detail |

The two 🔒 objects (`Person`, `Subscriber`) are already vault-routed; the masking invariant is
already enforced by construction through `Samen.Api.PiiResolution`. This ADR NEVER bypasses it
and adds a masking test on the one NEW PII surface (contact detail: tenant clear / operator ••••).

### 1.1 · The staging discipline (per feedback/scope-decomposition memory)

The full mandate touches ~6 feature areas. Rather than one 40-file drop, this ADR stages it into
**five phases**, each independently shippable, each keeping ALL suites green (§10). Phase 1 is the
spine (detail pages + timeline); Phases 2–5 layer on. §9 is the phase plan; §11 is the minimal
Phase-1 acceptance so `status: green` means "the Phase-1 contract is unambiguous."

---

## 2 · The invariants this ADR is bound by (restated so the Build phase cannot drift)

1. **`samen_core` code is untouched.** Every resource used here already exists. The ONLY kernel
   change is APPEND-ONLY rows in `samen_core/priv/abbrev_registry.json` for the host's Marketing
   mount (ADR-006 scoping) — a data file, not code.
2. **Framework-first.** Every LiveView/component/read is `Samen.Web.*` / `Samen.UI` in `samen_web`.
   Driftwood adds only a `Driftwood.Marketing` domain (one `use Samen.Scopes.Marketing`) + seed
   rows + zero LiveView code. PawChart inherits identically.
3. **Masking by construction.** No LiveView calls `Samen.Vault.reveal/3`, unwraps a `%Masked{}`,
   or has a "show plaintext" branch. PII reaches a page only if `PiiResolution` already resolved
   it. Tenant plane → clear; operator plane → `%Masked{}` (••••). A NEW PII surface (contact
   detail) ships with a masking test (tenant clear / operator ••••).
4. **Consent/suppression enforced on any send.** A send to a suppressed/opted-out subscriber
   REFUSES (`{:error, :suppressed}` — no row, no Oban job). This is already the kernel's
   `Send.:create_checked` red path; the UI must route ALL sends through it and surface the refusal.
5. **All suites + `ci.sh` (samen_web, driftwood 20-step, demo, pawchart) green before + after;
   `--warnings-as-errors` clean.**

---

## 3 · How detail pages mount via the EXISTING Mount seam (no new plumbing)

The Mount seam is already parameterized for detail pages — the support ticket detail
(`/support/tickets/:id`) already proves the pattern. Two facts make this a ~5-line change:

**(a) The route table gains two CRM detail routes.** `Samen.Web.Router.__routes__(:crm, path)`
today returns three list routes. It gains two `:id` routes (additive):

```elixir
def __routes__(:crm, path) do
  [
    {"#{path}/companies",     Samen.Web.CRM.CompaniesLive},
    {"#{path}/companies/:id", Samen.Web.CRM.CompanyLive},   # NEW
    {"#{path}/contacts",      Samen.Web.CRM.ContactsLive},
    {"#{path}/contacts/:id",  Samen.Web.CRM.ContactLive},   # NEW
    {"#{path}/pipeline",      Samen.Web.CRM.PipelineLive}
  ]
end
```

No host change: Driftwood's `samen_module_routes(:crm, Driftwood.Crm, repo: Driftwood.Repo)`
already loops this table, so the two detail routes mount automatically under the same
`live_session` (same signed `samen_mount` in the session → present on dead render AND reconnect).
PawChart inherits the same way.

**(b) The detail LiveView reads exactly like the list LiveViews.** `mount/3` calls
`assign_mount(socket, session)`, reads `org` + `:id` from params, builds
`scope = Mount.scope(mount, org_id)`, and reads the single record via `Mount.resource(mount, Person)`
filtered by id (mirroring `Samen.Web.Support.Reads.get_ticket/3`). The row's PII is resolved by
`Samen.Web.CRM.Reads` through `PiiResolution` — the plane is carried in the mount, so the detail
page is masked/clear by construction with ZERO masking code in the LiveView.

**Linking in.** The list rows link to detail exactly as the ticket list links
(`"#{crm_path(mount)}/contacts/#{p.id}?org=#{org_id}"`). The `crm_path/1` helper already exists on
the mount (labels-driven, default `/crm`). No hardcoded host path.

---

## 4 · (a) CONTACT DETAIL & COMPANY DETAIL — framework LiveViews

### 4.1 · `Samen.Web.CRM.ContactLive` (`/crm/contacts/:id`) — 🔒 PII surface

Structural template: `Samen.Web.Support.TicketLive` (header card + `Samen.UI.tabs` + per-tab
panes + `switch_tab` event). The masking helpers are copied VERBATIM in posture from
`ContactsLive` (render `%Masked{}` as-is; only reshape a plaintext string) — same MASKING
INVARIANT block.

**Header** (a `.card`, matching the ticket-detail header):
- Avatar (initials from resolved name, or `··` when masked) + **name** (`full_name`,
  🔒 resolved; masked → ••••) as the H1.
- **Company** (resolved `company_id` → company name via a small map, exactly as `ContactsLive`
  does today) + **title** (`job_title`, non-PII).
- **Email / phone** chips (`emails`/`phones`, 🔒 resolved).
- A `lifecycle_stage` pill (§7) and **social** icon-links (§8) — both read from `Person.custom`.
- Plane note ("your org in the clear" / "operator plane · masked") reusing `ContactsLive`'s
  `plane_note/1`.

**Tabs** (`Samen.UI.tabs` + `Samen.UI.tab`, href `?org=…&tab=…`, `switch_tab` event — the exact
ticket-detail mechanism):
- **Overview** — a details table (title, company, lifecycle stage, source, created-at, the
  `custom` bag rendered as key/value) + social handles. Non-PII except the header echo.
- **Activity** — the `Samen.UI.timeline/1` component (§6) over
  `Reads.activities_for_person(mount, scope, person_id)` + the **log-activity composer** (§6.3).
- **Deals** — the person's linked opportunities. In Phase 1 this is opportunities whose
  `company_id` matches the contact's company (a `Reads.opportunities_for_company/3`); a direct
  person↔opportunity link is a Phase-3 note (§9), NOT gold-plated now.

`page_title`, crumbs (`[crumb_root, "CRM", "Contacts", name]`), and the back-to-list action
reuse the existing `crm_sidebar` + `topbar`.

### 4.2 · `Samen.Web.CRM.CompanyLive` (`/crm/companies/:id`) — non-PII

Same skeleton, no 🔒 surface (company has no PII).

**Header:** company name (H1) + industry/size/website/domain badges (`Samen.UI.pill`).

**Tabs:**
- **Overview** — company details table + the `custom` bag (Driftwood carries `company_role`
  here) rendered read-only.
- **Activity** — `timeline/1` over `Reads.activities_for_company(mount, scope, company_id)` +
  the log-activity composer scoped to this company.
- **Deals** — the company's opportunities (`Reads.opportunities_for_company/3`) with value +
  stage pills.

**Contacts on the company** are a Phase-1 nicety, optional: a small list of this company's people
(names 🔒 resolved) linking to their contact detail. If it lands in Phase 1 it MUST route through
`Reads.contacts_for_company/3` (PII-resolved) — never a raw read.

---

## 5 · The read layer — extend `Samen.Web.CRM.Reads` (no new module for Phase 1)

All new reads are additive functions on the EXISTING `Samen.Web.CRM.Reads`, following its exact
shape: `Mount.resource(mount, Name)` + `Ash.Query.ensure_selected` + `Ash.read!(scope: scope)`,
wrapped in `rescue → []`/`:error`, and — for PII resources — `|> resolve_pii(mount, Name, scope)`.

New functions (Phase 1 + 3):
- `get_contact(mount, scope, id)` → `{:ok, person}` | `:error` — filtered read + `resolve_pii`
  (🔒 name/emails/phones plane-resolved). **This is the new PII surface** (masking test target).
- `get_company(mount, scope, id)` → `{:ok, company}` | `:error` — non-PII.
- `activities_for_person(mount, scope, person_id)` → `[activity]` sorted `inserted_at: :desc`
  (`filter(person_id == ^id)`). Non-PII (activity rows carry opaque FKs + bounded fields).
- `activities_for_company(mount, scope, company_id)` → `[activity]`.
- `opportunities_for_company(mount, scope, company_id)` → `[opportunity]` with its pipeline stage
  joined (reuse the `pipeline` read's stage-by-id map).
- `contacts_for_company(mount, scope, company_id)` → `[person]` (PII-resolved) — optional Phase 1.
- `create_activity(mount, scope, attrs)` → `{:ok, activity}` | `{:error, reason}` — the composer
  write path (§6.3): `Mount.resource(mount, Activity) |> Ash.Changeset.for_create(:create, attrs,
  scope: scope) |> Ash.create()`. `attrs` = `%{type, subject, body, person_id?, company_id?,
  opportunity_id?, status: :completed, org_id}`. The kernel's `SameOrgFk` change already guards
  cross-org FKs; `OrgScope` + `RoleAtLeast(:member)` already gate the create in the blueprint.

**Masking invariant** is inherited verbatim: `Reads` already NEVER calls the vault or unwraps a
`%Masked{}`; the new PII reads use the SAME `resolve_pii/4` helper (fail-safe: resolver error →
records stay `%Masked{}`, no plaintext downgrade).

---

## 6 · (b) ACTIVITY TIMELINE — over the EXISTING `Activity` resource

### 6.1 · The activity model (read from the blueprint — nothing new authored)

`<ns>.Activity` (`samen_core/lib/samen/scopes/crm/blueprint.ex` `define_activity/8`) already is:

| Field | Type | Notes |
|---|---|---|
| `type` | atom, required | one_of `[:call, :email, :meeting, :note, :task]` — the exact timeline types |
| `subject` | string | the "who/what" line |
| `body` | string | the note/detail body |
| `status` | atom | one_of `[:pending, :completed, :cancelled]` |
| `due_at` | utc_datetime | for `:task` items |
| `completed_at` | utc_datetime | when it happened |
| `custom` | map | Tier-1 bag |
| `company_id` / `person_id` / `opportunity_id` | uuid FKs (nullable) | links to any CRM object |
| `org_id`, `inserted_at`, `updated_at` | injected by base | org-scoped; timeline sort key |

Org-scoped by `OrgScope`; writes gated at `RoleAtLeast(:member)`; `SameOrgFk` guards the three
FKs. **No PII in the activity row itself** — the FKs are opaque IDs, `subject`/`body` are free
text authored by the org's own users on the tenant plane. (If a vertical wants activity bodies
vaulted, that is a Tier-1 decision on a future scope, out of scope here.)

**Timeline model** = the activity stream for a subject (person or company), each entry rendering
`type` (icon + label), `subject` (title), `body` (detail), `status`, and `who/when` (author +
`completed_at || inserted_at`). "Who" in Phase 1 is the acting member; a first-class
`actor_user_id` on activity is a Phase-3 note (the kernel `Activity` has no author FK today — do
NOT add one to the kernel; carry the author in `custom.author` if needed, or defer).

### 6.2 · `Samen.UI.timeline/1` — the framework timeline COMPONENT

A new function component in `Samen.UI` (the kit), host-agnostic, purely presentational — it takes
already-resolved data and renders it. Signature:

```elixir
attr :entries, :list, required: true   # [%{type, subject, body, status, at, who}]
attr :empty, :string, default: "No activity yet."
slot :composer                          # optional log-activity form slot
def timeline(assigns)
```

Rendering: a vertical rail (left gutter with a per-type glyph: 📞 call · ✉ email · 📅 meeting ·
📝 note · ✓ task, drawn as inline SVGs matching the kit's stroke style), each entry a row with
title (`subject`), timestamp (`format_dt`, reused from ticket-detail), a `Samen.UI.pill` for
`status`, and the `body` as wrapped text. The `:composer` slot renders above the rail so the
detail page drops the log-activity form in without the component knowing about writes. Pure
component → trivially unit-testable and inherited by every vertical.

Type→glyph/label and status→pill-variant are small private helpers in `Samen.UI` (bounded enums).

### 6.3 · The LOG-ACTIVITY composer — create an activity from the detail page

A composer form rendered in the timeline's `:composer` slot on both detail pages:
- Fields: **type** (select over the 5 enum values), **subject** (text), **body** (textarea),
  and an implicit **status: :completed** + `completed_at: now` (logging = it already happened;
  a `:task` with a `due_at` is a Phase-3 refinement).
- The person/company id is fixed by the page (the composer is scoped to THIS subject) — the LV
  injects `person_id` (contact page) or `company_id` (company page) + `org_id` from the scope.
- On submit → `handle_event("log_activity", params, socket)` → `Reads.create_activity/3` →
  on `{:ok, _}` re-load the timeline (re-read `activities_for_*`) and clear the form; on
  `{:error, cs}` surface a field error. Org-scoped write through Ash (OrgScope + member gate +
  SameOrgFk enforced by the kernel — the LV adds no policy of its own).

Org-scoped, tenant-plane only. (On the operator/impersonation plane the composer is READ-ONLY —
an operator does not author activity into a tenant's timeline; the plane note already signals it.
Phase-1 rule: hide the composer when `mount.plane.kind == :operator`.)

---

## 7 · (c) EMAIL / SEQUENCES — mount the Marketing scope

The Marketing scope is fully built and tested in `samen_core` (7 resources, suppression-enforced
`Send.:create_checked`, `SendWorker` Oban in `:webhooks_out`) but **mounted nowhere**. This ADR
mounts it as the framework's `:marketing` module and surfaces a minimal outreach UI.

### 7.1 · Mounting (Phase 4) — the host adds ONE domain + the framework a route table

**Host side (Driftwood — proves it):** a new `Driftwood.Marketing` domain, one `use`:

```elixir
defmodule Driftwood.Marketing do
  use Ash.Domain, validate_config_inclusion?: false
  use Samen.Scopes.Marketing,
    otp_app: :driftwood, repo: Driftwood.Repo, namespace: Driftwood.Marketing,
    abbrevs: %{campaign: "fmc", segment: "fmg", subscriber: "fms",
               template: "fmt", send: "fmn", email_event: "fme", suppression: "fmp"}
end
```

Fresh abbrevs (the global registry already owns `mca/msg/msu/…` for the demo mount — same finding
as ADR/Driftwood.Crm). **Append-only rows** in `samen_core/priv/abbrev_registry.json` under
`Driftwood.Marketing.*` (the ONLY sanctioned kernel change — a data file).

**Framework side:** `Samen.Web.Router` gains a `:marketing` case in `default_path` (`/marketing`),
`session_name`, and a `__routes__(:marketing, path)` table:

```elixir
def __routes__(:marketing, path) do
  [
    {"#{path}/campaigns",     Samen.Web.Marketing.CampaignsLive},   # sequences/campaigns list
    {"#{path}/campaigns/:id", Samen.Web.Marketing.CampaignLive},    # compose + send
    {"#{path}/segments",      Samen.Web.Marketing.SegmentsLive}     # leads/segments (§8 prospecting)
  ]
end
```

Host mounts it in one line alongside the others:
`samen_module_routes(:marketing, Driftwood.Marketing, repo: Driftwood.Repo)`.
The `Samen.Web.Mount.t` `scope_kind` type + the `scope_kind/1` deserializer in `Mount` gain
`:marketing` (bounded framework enum — a one-line append, framework code, allowed).

### 7.2 · The minimal outreach surface

- **`CampaignsLive`** — a campaigns/sequences list: name, status (`draft/scheduled/sending/
  sent/cancelled` pills), scheduled_at, a send-count metric (from `email_event`/`send` reads).
  Non-PII. Links each row to `CampaignLive`.
- **`CampaignLive`** (compose/send) — the load-bearing surface:
  - Pick a **template** (Tier-0 `Template`: subject_line + body_html) and a **segment**
    (the audience). Non-PII selects.
  - A **"Send to segment"** action → `handle_event("send_campaign", …)` → for each subscriber in
    the segment, call `Reads.enqueue_send(mount, scope, %{subscriber_id, campaign_id,
    template_id, org_id})` which invokes the kernel's `Send.:create_checked`. That action:
    (1) confirms the subscriber is same-org (kernel `SameOrgFk`), (2) checks the suppression
    table, (3) if suppressed → `{:error, :suppressed}` **no row, no Oban job**; else inserts the
    send row + enqueues `SendWorker` in the SAME Ecto.Multi (kernel `enqueue_in_tx/3`).
  - The UI **surfaces the refusal**: a per-subscriber result line ("queued" / "suppressed —
    skipped"), so an operator SEES that opted-out subscribers were refused. The refusal is
    enforced by the KERNEL, not the LiveView — the LiveView cannot bypass it (there is no default
    `:create` on `Send`).
  - **`email_event` tracking**: a delivery/open/click/bounce/unsubscribe read
    (`Reads.email_events(mount, scope, campaign_id)`) renders a small events table / counts. The
    `SendWorker` stub marks sends `:delivered`; real delivery + events are a host adapter (kernel
    already has the `SendWorker.Adapter` seam) — out of scope for the framework UI.

### 7.3 · How contact emails (vault PII, tenant-clear) feed a send WITHOUT leaking on operator

This is the load-bearing privacy question. The answer is **the send never carries the email —
only the opaque `subscriber_id`** (ADR job-args rule: token-only args; §SendWorker moduledoc):

1. **Subscribers are the emailing surface, not CRM people directly.** A `Subscriber` row carries
   the 🔒 `email` in the vault (`pii_msu_email`). A CRM `Person` → `Subscriber` mapping is how a
   contact enters an audience. Phase-4 minimal: a **"Add to audience"** action on the contact
   detail (tenant plane only) creates a `Subscriber` from the contact's resolved email. The email
   is read CLEAR on the tenant plane (the org owns its contacts' PII), written into the vault on
   the subscriber row, and NEVER stored anywhere in clear again.
2. **The send + the Oban job carry only `subscriber_id` (opaque UUID) + `org_id`.** No email in
   the send row, no email in job args. The `SendWorker` resolves the email at delivery time via
   the vault reveal path under a grant — the standard chokepoint, never job-args plaintext.
3. **Operator plane is masked by construction.** The Marketing LiveViews resolve `Subscriber.email`
   through `PiiResolution` exactly like `ContactsLive` resolves `Person.emails`: tenant plane →
   clear, operator/impersonation plane → `%Masked{}` (••••). So an operator viewing a tenant's
   campaign sees `••••` for every recipient, and — critically — the SEND ITSELF leaks nothing
   because it never held the email. The masking test for the Marketing PII surface (Phase 4)
   asserts `Subscriber.email` renders clear on tenant / •••• on operator, same rig as §11.

**Net:** contact email (tenant-clear) → subscriber vault → send (opaque id) → worker (vault
reveal under grant). At no hop does plaintext cross the operator plane or enter job args.

---

## 8 · (d) PROSPECTING — leads/segments view + a lifecycle stage

- **Lifecycle stage on `Person`.** The kernel `Person` (via CorePerson) already carries a `custom`
  jsonb Tier-1 bag. `lifecycle_stage` is a **Tier-1 custom-field convention** —
  `person.custom["lifecycle_stage"]` in a bounded set (`lead → mql → sql → customer →
  churned`), NOT a kernel schema change (no `samen_core` edit). The framework defines the bounded
  set + a `lifecycle_pill/1` helper in `Samen.UI`; a vertical can override the set via labels. It
  renders on the contact-detail header (§4.1) and drives the Leads filter.
  - *Rationale for custom-field over a Tier-0 enum:* adding a `lifecycle_stage` attribute to the
    kernel `Person` is a `samen_core` code change (forbidden) and over-commits every vertical to
    one funnel. The `custom` bag is the sanctioned Tier-1 seam (memory: "custom-field over kernel
    edit"). A future ADR MAY promote it to a Tier-0 attribute if every vertical converges — noted,
    not done.
- **Leads / Segments view** (`Samen.Web.Marketing.SegmentsLive`, Phase 5, reuses the Marketing
  mount): lists `Segment` rows (name, description, `subscriber_count`, filter criteria summary).
  A **Leads** lens is a filtered contacts read (`Reads.contacts/2` narrowed to
  `custom["lifecycle_stage"] in [:lead, :mql, :sql]`) rendered as a table with the lifecycle pill
  and a "Log activity" / "Add to audience" quick action. Org-scoped; PII-resolved (tenant clear /
  operator ••••).

---

## 9 · (e) SOCIAL — social handles on `Person`

- **Social handles are a Tier-1 custom-field convention**, same reasoning as lifecycle:
  `person.custom["social"] = %{"linkedin" => url, "twitter" => handle, "github" => handle}`.
  No `samen_core` change. The framework defines the recognized keys + a `social_links/1`
  presentational helper in `Samen.UI` (icon-links per known network; unknown keys rendered as
  plain labeled links). Social handles are **non-PII business-directory data** (a public LinkedIn
  URL), so they are NOT vault-routed and render on both planes — but they live in `custom`, which
  is the tenant's own data, so they follow OrgScope like any other field.
- **Rendered on contact detail** (§4.1 header + Overview tab). A tiny inline editor to set social
  handles is a Phase-5 nicety (writes to `custom` via a person update) — deferred, not gold-plated.

---

## 10 · (f) Framework `Samen.Web.*` vs `Samen.UI` — the split, and the mount/migration/seed map

### 10.1 · Component vs LiveView split

| Piece | Layer | Why |
|---|---|---|
| `timeline/1` | **`Samen.UI`** | Pure presentation, inherited by every vertical + reusable outside CRM (e.g. a future account timeline). |
| `lifecycle_pill/1`, `social_links/1`, timeline type-glyph/status helpers | **`Samen.UI`** | Small bounded-enum presentational helpers. |
| `ContactLive`, `CompanyLive` | **`Samen.Web.CRM`** | Host-parameterized pages (read via Mount). |
| `CampaignsLive`, `CampaignLive`, `SegmentsLive` | **`Samen.Web.Marketing`** | New framework module family, same Mount pattern. |
| `Samen.Web.CRM.Reads` additions, new `Samen.Web.Marketing.Reads` | **`Samen.Web`** | Read layer, Mount-derived resources, PII via `PiiResolution`. |
| The log-activity composer form | **`Samen.Web.CRM`** (in the detail LV) | It performs an org-scoped write; the pure `timeline/1` only slots it. |

### 10.2 · Mount / migration / seed map

**Mounts:**
- CRM detail routes: **no host change** — `__routes__(:crm, …)` gains two `:id` rows; existing
  `samen_module_routes(:crm, …)` picks them up.
- Marketing: host adds `Driftwood.Marketing` domain + `samen_module_routes(:marketing,
  Driftwood.Marketing, repo: Driftwood.Repo)` (one line). `Mount` `scope_kind` enum + `Router`
  `default_path`/`session_name`/`__routes__` gain `:marketing` (framework code appends).

**Migrations (host `mix ash.codegen` / ecto):** the CRM `Activity` table ALREADY exists (no new
migration for the timeline). The Marketing mount generates 7 new tables (`fmc_campaign` …
`fmp_suppression`) in the host — a standard `use Samen.Scopes.Marketing` codegen, same mechanics
as the existing scopes. `lifecycle_stage`/`social` are `custom` jsonb — NO migration.

**Seeds (`mix driftwood.seed`, wraps `Driftwood.Seeds.dev_seed/0`):**
- **Phase 1/3:** seed a handful of `Driftwood.Crm.Activity` rows per person/company (mix of
  `note/call/email/meeting/task`, `status: :completed`, `completed_at`) so the timeline renders
  real freight-flavored check-calls (Driftwood re-identifies `Activity` as **CheckCall**). Set
  `person.custom["lifecycle_stage"]` + `person.custom["social"]` on the existing seeded people.
- **Phase 4:** seed `Driftwood.Marketing.{Template, Segment, Subscriber, Suppression}` — a couple
  templates, one segment, subscribers built from the seeded contacts' emails (vaulted), and at
  least ONE `Suppression` row so the "send refuses a suppressed subscriber" path is provable in
  the dogfood + covered by a test.
- Idempotency guarded by markers, matching the existing seed conventions.

---

## 11 · Phase plan (staged, minimal-viable per scope-decomposition)

| Phase | Scope | Ships | Green gate |
|---|---|---|---|
| **1** | Detail spine | `ContactLive` + `CompanyLive` (Overview/Activity/Deals tabs), `timeline/1`, `Reads.get_contact/get_company/activities_for_*/opportunities_for_company`, log-activity composer, CRM `:id` routes, seed activities. **Masking test on contact detail.** | §12 |
| **2** | Polish | Company→contacts list, social_links + lifecycle_pill on header, timeline glyph polish. | suites green |
| **3** | Deals/tasks | Person↔opportunity direct link consideration (custom or defer), `:task` `due_at` in composer, activity author via `custom`. | suites green |
| **4** | Email/sequences | Mount Marketing (host domain + registry rows + `:marketing` route table), `CampaignsLive`/`CampaignLive`, `enqueue_send` via `:create_checked`, email_event tracking, **subscriber masking test + suppression-refusal test**, seed. | suites green |
| **5** | Prospecting/social edit | `SegmentsLive` + Leads lens, inline social/lifecycle editor. | suites green |

Phases 2/3/5 are additive nicety; 1 and 4 carry the load-bearing contracts (a real detail+timeline
CRM; consent-safe outreach). Each phase keeps ALL four suites + `ci.sh` green and `--warnings-as-errors`
clean.

---

## 12 · Phase-1 acceptance (so `status: green` = the contract is unambiguous)

A build implementing Phase 1 is DONE when:

1. `GET /crm/contacts/:id?org=<uuid>` (tenant plane) renders the contact header with name/email/phone
   **in the clear**, three tabs, and an Activity timeline with seeded entries + a working
   log-activity composer that creates a `<ns>.Activity` and re-renders the timeline.
2. The SAME route on the **operator plane** renders name/email/phone as **••••** (masked), and the
   composer is **hidden** — proven by a masking test asserting `%Masked{}` / clear via the SAME rig
   as the existing `contacts_live` masking test (tenant scope → binary; operator scope → `%Samen.Masked{}`).
3. `GET /crm/companies/:id?org=<uuid>` renders company header + Overview/Activity/Deals; the
   company timeline + composer work (activity scoped to `company_id`).
4. `timeline/1` is a `Samen.UI` component with a unit test (renders entries + empty state + slots a
   composer) — inherited, not CRM-coupled.
5. New `Reads` functions are covered (get_contact/get_company/activities_for_*/create_activity),
   including `create_activity` respecting OrgScope + SameOrgFk (a cross-org FK is refused by the
   kernel change — a negative test).
6. Driftwood seed produces ≥3 activities on ≥1 contact and ≥1 company; the driftwood 20-step
   dogfood renders the detail pages (self-verify: goto `/crm/contacts/:id?org=<uuid>`, grep the
   name, screenshot).
7. ALL suites (samen_web, driftwood 20-step, demo, pawchart) + `ci.sh` green before and after;
   `--warnings-as-errors` clean; `samen_core` code untouched (only Marketing abbrev rows are a
   Phase-4 append, not Phase 1).

---

## 13 · Consequences

**Positive:** the framework becomes a real CRM (detail + timeline + outreach) with ONE new
`Samen.UI` component and two new LiveView families — every vertical inherits it, the vertical
proves it. The masking invariant and the suppression red path are REUSED (kernel-enforced), not
re-implemented, so the privacy guarantees are the same ones already tested. Staging keeps every
drop green.

**Negative / accepted:** `lifecycle_stage` + `social` live in the `custom` bag (Tier-1), so they
are stringly-typed until/unless a future ADR promotes them to Tier-0 — accepted per the "no kernel
edit" invariant. Activity has no first-class author FK (who-logged-it rides `custom`) — accepted;
promoting it is a kernel change deferred to a future scope revision. Real email delivery + event
ingestion is a host adapter (the framework ships the UI + the suppression-safe enqueue + the stub
worker) — accepted; the kernel already exposes the `SendWorker.Adapter` seam.

**Follow-ups (noted, not gold-plated now):** person↔opportunity direct relationship; Tier-0
promotion of lifecycle_stage; activity author FK; a real ESP adapter; timeline pagination for
large accounts.
