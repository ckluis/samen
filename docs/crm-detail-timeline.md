# CRM detail pages + activity timeline (ADR-011 Phase 1) — Build report

**Task:** Build the framework CRM detail spine per ADR-011 Phase 1 — contact/company detail
pages, an activity timeline over the existing kernel `Activity` resource, a log-activity
composer, list→detail links, social handles + lifecycle stage. Framework-level in `samen_web`;
the Driftwood vertical only proves it. `samen_core` untouched.

**Status:** GREEN — Phase-1 acceptance (ADR-011 §11/§12) met. All suites green
(samen_web 86, driftwood default 82, demo 403, pawchart 35); `--warnings-as-errors` clean;
`samen_core` code + abbrev registry untouched (Phase 1 needs no registry append — that is a
Phase-4 Marketing concern).

## Routes added (framework `Samen.Web.Router.__routes__(:crm, path)`)

- `GET {crm_path}/contacts/:id` → `Samen.Web.CRM.ContactLive` (🔒 PII surface)
- `GET {crm_path}/companies/:id` → `Samen.Web.CRM.CompanyLive` (non-PII)

Additive — no host change. Driftwood's existing `samen_module_routes(:crm, Driftwood.Crm, …)`
loops the table and mounts the two `:id` routes automatically under the same signed
`live_session`; PawChart + demo inherit identically (verified: their suites pass with the two
new routes present).

## What shipped (all in `samen_web`, the framework)

- **`Samen.UI.timeline/1`** — a pure, host-agnostic activity-timeline component (vertical rail,
  per-type inline-SVG glyphs call/email/meeting/note/task, subject/status-pill/body/who-when,
  empty state, optional `:composer` slot). Plus `Samen.UI.lifecycle_pill/1` and
  `Samen.UI.social_links/1` (Tier-1 presentational helpers). Unit-tested in isolation.
- **`Samen.Web.CRM.ContactLive`** (`/crm/contacts/:id`) — header (avatar, 🔒 name/email/phone,
  title, company, lifecycle pill, social icon-links, plane note), tabs Overview/Activity/Deals,
  the activity timeline, and the log-activity composer (tenant plane only; hidden on operator).
- **`Samen.Web.CRM.CompanyLive`** (`/crm/companies/:id`) — non-PII header + Overview
  (details + this company's contacts, PII-resolved) / Activity (timeline + composer) / Deals.
- **`Samen.Web.CRM.Reads`** additions: `get_contact/3` (the NEW PII surface, `resolve_pii`),
  `get_company/3`, `contacts_for_company/3` (PII-resolved), `activities_for_person/3`,
  `activities_for_company/3` (newest-first), `opportunities_for_company/3` (stage-joined), and
  `create_activity/3` (composer write path — org-scoped Ash create; the kernel's OrgScope +
  `RoleAtLeast(:member)` + `SameOrgFk` gate it, this module adds no policy).
- **List → detail links**: contact + company list rows link to their detail page via
  `Mount.label(mount, :crm_path, "/crm")` (no hardcoded host path).
- **Social + lifecycle** on the contact detail: Tier-1 custom-field conventions on
  `Person.custom`. Because the kernel custom bag has NO `:map` type and rejects
  whitespace/PII-shaped values, social handles are FLAT string keys (`social_linkedin`,
  `social_twitter`, `social_github` — whitespace-free profile URLs, non-PII);
  `lifecycle_stage` is a bounded string set (`lead → mql → sql → customer → churned`).

## Driftwood (proves it — no LiveView code)

- Seed (`Driftwood.Seeds`): 36 activities (3 per contact, all 5 types, `status: :completed`),
  `lifecycle_stage` + `social_linkedin`/`social_twitter` on every seeded person, and the
  matching `tnt_field` registrations for `fpr_person` (so the custom-bag validated-at-write
  accepts them). Driftwood re-identifies Activity as "CheckCall" (freight check-calls).

## Masking guarantee — the load-bearing test

`test/samen/web/crm_detail_render_test.exs`, mirroring the existing `contacts_live` rig
(tenant scope → binary clear / operator scope → `%Samen.Masked{}`):

- **TENANT** `/crm/contacts/:id` renders name/email/phone IN THE CLEAR, three tabs, the
  seeded timeline, and the composer.
- **OPERATOR** — the SAME `ContactLive` renders the SAME contact `••••` (masked), with
  `refute html =~ Seeds.contact_full_name()/email()/phone()`, `refute html =~ "vt_"` /
  `"pii_"` (no vault token leak), and the composer HIDDEN.
- `Reads.get_contact` returns a clear binary on tenant, `%Samen.Masked{}` on operator.
- The masking key assertion (operator plane):

  ```elixir
  mount = build_mount(:crm, plane: :operator, target_org_id: org_id)
  html = render_live(Samen.Web.CRM.ContactLive, mount, [org_id, contact_id])
  assert html =~ "••••"
  refute html =~ Seeds.contact_full_name()
  refute html =~ Seeds.contact_email()
  refute html =~ Seeds.contact_phone()
  refute html =~ "vt_"
  refute html =~ "pii_"
  ```

The LiveViews never call `Samen.Vault.reveal/3`, never unwrap a `%Masked{}`, and have no
"show plaintext" branch — PII reaches a page only if `PiiResolution` resolved it.

## Other tests

- `Samen.UI.timeline/1` / `lifecycle_pill/1` / `social_links/1` component unit tests
  (typed entries, empty state, composer slot, `%Masked{}` verbatim, known/unknown stage,
  flat social keys) — `test/samen/ui/components_test.exs`.
- Timeline renders seeded activities; log-activity creates + re-renders in the timeline
  (`handle_event("log_activity", …)` → `create_activity` → re-read).
- Negative test: `create_activity` with a cross-org `person_id` is REFUSED by the kernel
  `SameOrgFk` (`{:error, _}`).
- Router: the two `:id` routes are in the table and register on a compiled host router.

## Dogfood self-verify (driftwood, PORT 4034)

`mix driftwood.seed` → `GET /crm/contacts/<uuid>?org=<uuid>&tab=activity` returned 200 with
the contact name in the clear, the lifecycle "Lead" pill, the LinkedIn social link, the
timeline rail with typed glyphs + seeded check-calls, and the log-activity composer.
`GET /crm/companies/<uuid>?org=<uuid>` returned 200 with the company header. Screenshot
captured (`/tmp/contact_detail_activity.png`).

## Not in this build (ADR-011 Phases 2–5, noted not gold-plated)

Email/sequences (mount Marketing — the Phase-4 abbrev-registry append lives there), a
`SegmentsLive` leads lens, an inline social/lifecycle editor, person↔opportunity direct link,
`:task` `due_at` in the composer, and a first-class activity author FK.
