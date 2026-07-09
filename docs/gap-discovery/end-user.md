# Samen — End-User Lens: Gap Discovery

> Sub-orchestrator deliverable. Lens: the experience of a **tenant's end-users actually using
> a SaaS product built on Samen**. Benchmark: world-class B2B product UX (Linear, Notion,
> Stripe-embedded, Intercom-embedded, modern LiveView apps). Repo: `~/Desktop/projects/samen`.
> All file paths absolute. Read against the "make building AND running a SaaS a joy" north star.

## TL;DR

Samen has a **beautiful spine and a hollow surface**. The `samen_web` UI kit + LiveViews render
the inherited-80% (CRM / Billing / Support / Marketing / Chat) with a genuinely nice look, and the
masking-by-construction invariant holds all the way to the pixel. But the *product* an end-user
touches is, today, **mostly a read-only reference skin**: only 6 of ~30 LiveViews have any
`handle_event`, there is **no search box anywhere**, **no notifications inbox**, **no file
upload**, **no import/export**, **no pagination / saved views / bulk actions**, **no responsive
CSS (`@media` count = 0)**, **no loading/skeleton states**, **near-zero a11y attributes**, and
**no i18n / locale / timezone / multi-currency** (all money is hardcoded `$` USD, all timestamps
literally say "UTC"). The cross-cutting primitives (Notifications / Files / Search / Webhooks /
FeatureFlags) exist as **governed Ash resources with no runtime engine and no UI** — schemas, not
features. End-user self-serve (profile, 2FA, sessions, API keys, DSAR/export, team invites) has
**data models but zero screens**.

None of this is a defect against the current gates — the gates scored the masking spine and the
reuse thesis, both of which are real and strong. It IS the entire delta between "a governed
framework that proves masking" and "a SaaS foundry that makes *using* the product a joy." The
`next-session-brief.md` already names these as the end-user lens; this doc ranks them.

---

## Evidence base (what I actually read)

- UI kit: `/Users/clank/Desktop/projects/samen/samen_web/lib/samen/ui.ex` (852 lines — the whole
  component vocabulary: shell, sidebar, nav, topbar, button, tabs, data_table, pill, object_card,
  progress, metric, mask_bar, token_blind_bar, timeline, lifecycle_pill, social_links).
- Representative list page: `/Users/clank/Desktop/projects/samen/samen_web/lib/samen/web/crm/contacts_live.ex`.
- Write path: `/Users/clank/Desktop/projects/samen/samen_web/lib/samen/web/crm/contact_live.ex`
  (`log_activity` form, lines 62–70, 310–326).
- Router: `/Users/clank/Desktop/projects/samen/samen_web/lib/samen/web/router.ex`.
- Cross-cutting primitives: `/Users/clank/Desktop/projects/samen/samen_core/lib/samen/scopes/primitives/blueprint.ex`
  (Notification, File, SearchIndex, Webhook, FeatureFlag resources), `.../primitives/audit.ex`,
  `.../primitives/search_index_guard.ex`.
- Identity self-serve resources: `/Users/clank/Desktop/projects/samen/samen_core/lib/samen/scopes/identity/blueprint.ex`
  (Membership, Invitation, ApiKey).
- CSS: `/Users/clank/Desktop/projects/samen/samen_web/priv/static/assets/samen_ui.css` (500 lines,
  `@media` count = **0**, skeleton/loading/keyframes count = **0**).
- Gate reports (`docs/gate-*.md`) + `docs/next-session-brief.md` for known residues.

### Hard signals (grep-verified)

| Signal | Finding |
|---|---|
| LiveViews with `handle_event` | **6 of ~30** — chat threads/thread, crm company/contact (log-activity), marketing campaign, support ticket. Everything else is read-only. |
| `phx-submit` / `phx-change` in HEEx | 5 submit, 1 change — total. |
| Search box (`type="search"` / search phx-change) | **0** anywhere in `samen_web/lib`. |
| Import / export / CSV / download | **0** in web UI (grep hits were substring false-positives in var names). |
| `@media` queries in CSS | **0** — not responsive; desktop-only. |
| Loading / skeleton / spinner / keyframes | **0** in CSS; `assign_async` / `stream(` / `phx-loading` = **0** in LiveViews. |
| `aria-*` / `role=` / `alt=` | 3 total occurrences, all in one file (`current_org.ex`). |
| gettext / Cldr / locale / i18n | **0** — no translation infra. |
| Currency | hardcoded `"$#{cents/100}"` float-format, USD only (`billing/overview_live.ex:242`, `plans_live.ex:176`). |
| Timezone | every timestamp rendered literally `... UTC`; no per-user tz (`support/ticket_live.ex:390`, `marketing/campaigns_live.ex:140`, `ui.ex:728`). |
| Pagination | none — every reads returns a full list, table renders all rows. |
| Notif/File/Search/Settings/Profile/Team routes | **0** in framework or vertical routers. |

---

## The gaps

Format per gap: **world-class · Samen today (cited) · delta · joy (H/M/L) · effort (S/M/L) ·
harden-vs-new · breadth**. Ranked at the end by (joy × breadth) / effort.

### G1 — Notifications: no in-app inbox, no delivery engine, no preferences

- **World-class:** a bell/inbox with unread counts, grouped feed, real-time push, per-event
  email/digest with granularity + quiet hours, per-user preferences. (Linear/Intercom baseline.)
- **Samen today:** a `Notification` Ash resource exists — `.../primitives/blueprint.ex` — with
  `channel` (in_app/email/sms/push/webhook), `status`, `read_at`, vault-routed `rendered_body`,
  and an audit writer (`primitives/audit.ex`). That is the **whole** of it. There is **no send /
  dispatch action, no Oban delivery worker, no digest, no preference model, and no LiveView**
  anywhere that renders a notification. The sidebar `nav_item/1` even has a `count`/`dot` affordance
  (`ui.ex:157–173`) but nothing feeds it.
- **Delta:** everything a user experiences as "notifications" — the inbox surface, real-time
  PubSub delivery, the email/digest engine, preferences UI — is missing. Only the record schema
  exists.
- **Joy H · Effort L (full, incl. digests) / M (inbox + realtime MVP) · new module.**
- **Breadth:** universal — every vertical wants it. Chat PubSub + presence infra
  (`samen_web/lib/samen/web/chat/pub_sub.ex`, `presence.ex`) already exists to build on.
- **PII surface:** `rendered_body` is vault-routed — a notification inbox is a **new PII render
  surface** and needs a per-plane masking test (operator viewing a tenant's inbox must see `••••`),
  same pattern as the object-unfurl card.

### G2 — Global / catalog-aware search: registry exists, engine + box do not

- **World-class:** `⌘K` global search across objects, per-list search, catalog-aware, PII-safe.
- **Samen today:** a `SearchIndex` **registry** resource + a `search_index_guard.ex` that
  *forbids* indexing PII columns (`.../primitives/search_index_guard.ex`) + `tsvector` columns on
  resources (e.g. `pfl_search_vector`). This is a **governance layer that declares what could be
  searched** — there is **no `:search` action, no tsquery builder, no `⌘K` palette, no search
  box** in any HEEx (`type="search"` count = 0).
- **Delta:** the hard, differentiated part (PII-safe indexing policy) is *done*; the entire
  user-facing search — action + box + results + highlighting — is absent.
- **Joy H · Effort M · new module (built on the existing guard).**
- **Breadth:** universal.
- **PII surface:** the guard already blocks PII indexing by construction — this is the *right*
  foundation and a rare case where masking-by-construction *reduces* risk. Results still render
  through PiiResolution; needs a per-plane test.

### G3 — Onboarding / empty states / sample-data: no first-run anywhere

- **World-class:** first-run checklist, contextual empty states with a primary CTA, one-click
  "load sample data," guided setup.
- **Samen today:** empty states are **partial and inconsistent** — present on Marketing leads/
  campaigns/segments and some CRM detail sub-lists, **absent on the main lists** (crm/contacts,
  crm/companies, billing/invoices, support/tickets render a zero-row `<.data_table>`). No first-run
  flow, no in-app "populate demo data" (seeds are operator CLI only: `driftwood/lib/driftwood/seeds.ex`,
  invoked via `mix`, not a button).
- **Delta:** a new tenant lands on empty tables with a decorative "New contact" button that has no
  `phx-click`. No guided path from zero to value.
- **Joy H · Effort M · harden (finish empty states) + new (first-run framework).**
- **Breadth:** universal; empty-state pattern belongs in the kit so every vertical inherits it.

### G4 — CRUD is decorative on most pages (the "read-only skin" gap)

- **World-class:** every list has working create/edit/delete, inline or modal forms with
  validation.
- **Samen today:** only 6 LiveViews handle events. Writes that exist: chat send, log-activity
  (crm company/contact), ticket reply, one campaign action. The prominent **"New contact" /
  "New company" primary buttons render with no `phx-click`** (`contacts_live.ex:85–93`) — pure
  decoration. Billing, invoices, plans, all list pages are read-only. The one real form
  (`contact_live.ex:310` log-activity) is a bare `<form>` with raw `<input>`/`<textarea>`, no
  changeset-backed validation, no error display, no `simple_form`.
- **Delta:** a tenant cannot actually *manage* their CRM/billing/support data through the UI — it
  reads seeded data. This is the largest single "joy" hole: the product looks operable and isn't.
- **Joy H · Effort M–L (per scope) · harden.**
- **Breadth:** universal.
- **PII surface:** create/edit of Person/Company writes PII — every new write form must route
  through the vault write path and ship a per-plane test (operator impersonating must not be able
  to write plaintext into a masked field unnoticed).

### G5 — Responsive / mobile: zero media queries

- **World-class:** fully responsive; usable on tablet/phone; the sidebar collapses.
- **Samen today:** `samen_ui.css` has **`@media` count = 0**. The `.app > .side + .main` grid is a
  fixed desktop two-pane. On a phone it does not adapt.
- **Delta:** the product is desktop-only. Any end-user on mobile (support agents, field users like
  Driftwood dispatchers, vet-clinic front desk on a tablet) gets a broken layout.
- **Joy M–H (vertical-dependent; freight/vet are mobile-real) · Effort M · harden (CSS).**
- **Breadth:** universal.

### G6 — Files: metadata resource, no upload / preview / storage

- **World-class:** drag-drop upload, thumbnails/preview, attach-anywhere, size/type limits,
  virus scan, S3-backed.
- **Samen today:** a `File` resource with `filename`/`content_type`/`size_bytes`/`storage_key`/
  `status(active|quarantined|…)`/`search_vector` + an audit writer (`primitives/blueprint.ex`).
  **No upload action, no storage adapter (S3/local), no `Phoenix.LiveView.allow_upload`, no
  preview, no attachment picker, no size/type enforcement.** `storage_key` is a bare string.
- **Delta:** the entire file lifecycle (upload → store → scan → preview → attach) is unbuilt.
- **Joy M–H · Effort M (LV upload + local/S3 adapter) / L (preview + scan) · new module.**
- **Breadth:** universal (support attachments, CRM docs, billing PDFs, vet records, BOLs).
- **PII surface:** filenames + file bodies can be PII; a preview surface is a new render surface —
  needs masking/access policy per plane.

### G7 — Import / export: none, at any granularity

- **World-class:** CSV import with column mapping + dedupe preview; per-object + whole-account
  export; scheduled backups.
- **Samen today:** **nothing** — no import UI, no export button, no CSV/xlsx anywhere in the web
  layer.
- **Delta:** a tenant cannot get data in (migrating from a competitor) or out (backup, reporting).
  Table-stakes for B2B adoption.
- **Joy M–H (import is an adoption unlock) · Effort M · new module.**
- **Breadth:** universal; the catalog-as-data makes a *generic* mapper feasible (map CSV columns to
  catalogued fields).
- **PII surface:** export is a classic mask-by-omission leak vector — must go through PiiResolution
  (the kit already proves this pattern; export must not become the plaintext bypass). Per-plane
  export test required.

### G8 — Self-serve settings: profile / 2FA / sessions / API keys — models, no screens

- **World-class:** users edit their profile, change password, enable 2FA, view/revoke sessions,
  mint personal API tokens; tenant admins self-serve billing.
- **Samen today:** `ApiKey` (admin-only, `token_digest`, `plane`, `scopes`, `revoked_at`) and
  `Membership`/`Invitation` resources exist in `identity/blueprint.ex`. **No settings screen, no
  profile edit, no password/2FA (auth is deferred to host — `router.ex` derives org from session,
  no login LV), no session list, no API-key management UI.**
- **Delta:** every self-serve settings surface is data-model-only. There isn't even a `/settings`
  route.
- **Joy M · Effort M (profile+keys) / L (2FA+sessions, needs auth story) · new module.**
- **Breadth:** universal.
- **PII surface:** profile edits the user's own vaulted PII — a self-edit path must keep the vault
  write chokepoint.

### G9 — List ergonomics: no pagination / sort / filter / saved views / bulk actions

- **World-class:** sortable columns, faceted filters, saved views, multi-select bulk actions,
  server-side pagination.
- **Samen today:** every list `reads` returns the full set; `data_table/1` (`ui.ex:371`) renders
  all rows with fixed headers and **no sort, no filter, no pagination, no row selection, no bulk
  bar**. Reads have no `limit`/`offset`.
- **Delta:** at any real data volume the tables are unusable and slow (full-table render). No way
  to slice or act in bulk.
- **Joy M · Effort M · harden (extend `data_table` + reads).**
- **Breadth:** universal; belongs in the kit + a reads convention so every vertical inherits it.

### G10 — i18n / locale / timezone / multi-currency: none

- **World-class:** translatable UI (gettext/Cldr), per-user locale + timezone (timestamps shown
  local), multi-currency formatting.
- **Samen today:** **no gettext/Cldr** (count 0). Money is hardcoded `"$" <> float(cents/100)`
  USD (`billing/overview_live.ex:242`, `plans_live.ex:176`) — no currency field respected, float
  formatting risks rounding. Every timestamp is rendered with a literal `UTC` suffix and no
  conversion (`ui.ex:728`, `support/ticket_live.ex:390`).
- **Delta:** unusable outside a US-English/USD tenant; timestamps always UTC; no localization
  substrate.
- **Joy M (L for US-only verticals, H for anyone global) · Effort M (tz+currency) / L (full
  gettext) · new (substrate) + harden (money/tz helpers into the kit).**
- **Breadth:** universal.

### G11 — Accessibility: near-zero semantics

- **World-class:** WCAG-AA — semantic landmarks, `aria-*`, keyboard nav, focus states, SR labels.
- **Samen today:** 3 total `aria`/`role`/`alt` occurrences (all in `current_org.ex`). Nav uses
  bare `<a>`, icon-only buttons have no labels, tables lack captions/scope, no skip links, no
  documented keyboard model, status conveyed by color-pill alone (`pill/1`).
- **Delta:** fails accessibility baseline; blocks enterprise/gov procurement.
- **Joy L (invisible to most, gating for some) · Effort M · harden (kit-level).**
- **Breadth:** universal; fixing the kit fixes every vertical at once (high leverage).

### G12 — Perf & polish: no loading/optimistic/streams; full-list render

- **World-class:** skeleton/loading states, optimistic UI, `stream` for lists, `assign_async`
  for slow strips, no full re-render.
- **Samen today:** `assign_async`/`stream(`/`phx-loading` = **0**; no skeletons/keyframes in CSS.
  Lists assign full lists (not streams); the analytics strips render synchronously in `mount`.
- **Delta:** every navigation is a blocking full load; large lists re-render whole; no perceived-
  speed polish.
- **Joy M · Effort M · harden (convert reads to streams + async strips + kit skeletons).**
- **Breadth:** universal.

### G13 — Webhooks & FeatureFlags: no tenant-admin UI

- **World-class:** self-serve endpoint management with test-send + delivery logs; a flags console.
- **Samen today:** **Webhooks outbound delivery is genuinely built** (`samen_core/lib/samen/webhook*`
  — HMAC signing, backoff, idempotency, DLQ) — but there is **no admin UI** to register/test/inspect
  endpoints. `FeatureFlag` is a config resource with **no `enabled?/2` gate function, no rollout
  sampler, no toggle UI.**
- **Delta:** admin-facing management surfaces (and the flag runtime) are missing; webhooks are
  API/DB-only.
- **Joy L–M · Effort S (webhook admin UI on existing engine) / M (flag runtime + UI) · harden
  (webhooks) + new (flag runtime).**
- **Breadth:** universal, but admin-tier (narrower daily reach than G1–G5).

### G14 — DSAR / data-export self-serve: backend-only

- **World-class:** a tenant admin (or subject) requests "download my data" / "delete my data"
  self-serve, audited.
- **Samen today:** crypto-shred + erasure exist in the kernel (`Samen.Erasure`), and a tenant can
  *read* who impersonated them (`samen_core/lib/samen/impersonation/sessions.ex`). **No self-serve
  UI** to request export or erasure; both are operator/offline.
- **Delta:** GDPR/CCPA self-serve is unbuilt at the UI. (Overlaps G7 export.)
- **Joy L–M · Effort M · new (thin UI over existing erasure/export).**
- **Breadth:** universal (compliance), but low daily-joy.

---

## Ranking — (joy × breadth-across-verticals) / effort

| Rank | Gap | One-clause delta | Joy | Effort | Harden/New |
|---|---|---|---|---|---|
| 1 | **G4 CRUD is decorative** | most pages read-only; primary "New" buttons unwired; users can't manage their data | H | M | harden |
| 2 | **G1 Notifications** | resource only — no inbox, no delivery engine, no prefs; nav count affordance unfed | H | M/L | new |
| 3 | **G3 Onboarding + empty states** | inconsistent empty states, no first-run, no in-app sample data | H | M | harden+new |
| 4 | **G2 Global search** | PII-safe index registry exists; no search action, no ⌘K, no box | H | M | new |
| 5 | **G9 List ergonomics** | no pagination/sort/filter/saved-views/bulk — tables unusable at scale | M | M | harden |
| 6 | **G5 Responsive/mobile** | zero `@media`; desktop-only; breaks for mobile-real verticals | M/H | M | harden |
| 7 | **G6 Files** | metadata resource; no upload/preview/storage adapter | M/H | M | new |
| 8 | **G7 Import/export** | none; adoption blocker; catalog makes generic mapper feasible | M/H | M | new |
| 9 | **G12 Perf/polish** | no streams/async/skeletons; blocking full-list renders | M | M | harden |
| 10 | **G8 Self-serve settings** | profile/2FA/sessions/API-keys are models with no screens | M | M | new |
| 11 | **G11 Accessibility** | ~zero aria/roles; kit-level fix = whole-fleet leverage | L | M | harden |
| 12 | **G10 i18n/tz/currency** | USD-only, UTC-only, no gettext | M | M | new+harden |
| 13 | **G13 Webhook/flag admin UI** | delivery engine built; no admin surface; no flag runtime | L/M | S/M | harden+new |
| 14 | **G14 DSAR/export self-serve** | erasure/audit in kernel; no self-serve UI | L/M | M | new |

### Recommended first workstream

**"Make the product operable + alive"** — bundle **G4 (real CRUD via kit-level create/edit
forms) + G3 (empty states + first-run in the kit) + G1 (notifications inbox on the existing chat
PubSub/presence infra)**. These three convert the reference skin into a product a tenant can
actually *use*, share the same framework leverage (kit + reads conventions inherited by every
vertical), and each carries a clean per-plane masking-test story. G2 (search) is the strong
fast-follow — its hard part (PII-safe indexing) is already done.

### Masking-by-construction watch-list (new PII surfaces → require per-plane masking tests)

Every one of these creates a value-render or value-write path that must pass through
`Samen.Api.PiiResolution` (never a plaintext bypass), matching the object-unfurl precedent:

- **G1** notification inbox — `rendered_body` is vaulted; operator viewing a tenant inbox = `••••`.
- **G4** create/edit forms writing Person/Company PII — write chokepoint + no operator plaintext write.
- **G6** file preview + filename render.
- **G7** export (the classic mask-by-omission leak — export must render masked on the operator plane).
- **G8** profile self-edit of own vaulted PII.
- **G2** search results (guard already blocks PII *indexing* by construction — the low-risk case).

---

## Overall assessment

Samen's end-user surface is a **gorgeous, masking-correct read-only demonstration, not yet a
usable product.** The framework spine (kit, Mount seam, PiiResolution-to-pixel masking, reuse
thesis) is real and high-quality — the leverage story ("fix the kit, every vertical inherits") is
exactly right and makes almost every gap here a *framework-first* win rather than vertical churn.
The dominant hole is that the product **looks operable and isn't**: decorative CRUD, no
notifications a user can see, no search, no files, no import/export, desktop-only, no i18n. Closing
G1–G4 (plus G9) would move Samen from "proves masking" to "a SaaS you'd actually enjoy using," and
none of it requires touching the pure kernel.
