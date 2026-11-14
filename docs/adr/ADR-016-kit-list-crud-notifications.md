# ADR-016 — Kit list/CRUD primitives, keyset pagination contract, and the masking-aware notifications engine + inbox

- **Status:** Accepted (design; WS-A phases A2–A5 implement, staged minimal-viable).
- **Date:** 2026-07-09
- **Task:** Framework DESIGN for WS-A/G1+G2+G5 — kit-level `simple_form`/`modal`/`empty_state`/`list_view` primitives + a `ListLive` behaviour so verticals inherit CRUD + list ergonomics at ≈0 lines; a keyset-pagination reads contract + JSON:API `default_limit`; and a notifications delivery engine (kernel record + dispatch) with a masking-aware inbox LiveView + unread badge + preferences. Framework-first in `samen_web`; kernel touch limited to the notification record/engine (no UI).
- **Deciders:** opus (framework layer), grounded in the WS-A non-negotiables ("capability lands in samen_web kit / kernel where sanctioned"; "adoption ≈ 0 lines for list ergonomics"; "masking by construction — new PII surfaces ship per-plane masking tests").
- **Builds on:**
  - **ADR-008/009** (the UI kit + `samen_web` two-plane pattern; `data_table/1`, `Mount`, `Plane`, `Reads`).
  - **ADR-010** (`PiiResolution` by plane; the impersonation `%Masked{}`-but-present rule).
  - **ADR-012 / 012a** (the chat PubSub id-only envelope + `ObjectRef.resolve/3 → object_card` per-viewer unfurl — reused verbatim for realtime notifications and notification-embedded object refs).
  - **ADR-014** (the delivery adapter — email notifications dispatch through it; blocked/failed sends notify the operator).
  - The `Notification` resource (`primitives/blueprint.ex`, abbrev `pnt`; `rendered_body` vault-routed) + `Primitives.Audit.notification_sent/3`.
- **Supersedes / touches:** extends the kit (new components + a `ListLive` mixin) and the `Reads` convention (keyset pagination + bounded reads). Adds a `NotificationPreference` resource (abbrev `npr`) + a framework `/notifications` route. `samen_core` gains a record+dispatch engine only (no web dep).

---

## 1 · Context — the product looks operable and isn't

Only 6 of 21 LiveViews handle events; the primary "New …" buttons are decorative; `data_table/1` renders all rows with no sort/filter/pagination/bulk; reads are unbounded `.read!()`; the `Notification` resource has no engine, inbox, prefs, or realtime; the `nav_item` `count` badge is unfed; the main lists render bare zero-row tables (end-user G1/G3/G4/G9; harden H-3/H-9/H-10). The kit is purely presentational — which is exactly why fixing IT fixes every vertical.

## 2 · Decision — kit primitives + `ListLive` behaviour

New kit components: `simple_form/1` (`AshPhoenix.Form`-backed, inline errors), `form_field/1` (labelled input/select/textarea + error slot + `aria-describedby`), `modal/1` (`role="dialog"`, focus trap, escape/click-away close), `empty_state/1` (title/body/icon + `:actions` + `:sample` slots), and `list_view/1` — wraps `data_table/1` and adds **as kit defaults**: sortable headers (`phx-click="sort"`), a debounced filter box (`phx-change="filter"`), a keyset pagination footer, and optional bulk-select (checkbox column + bulk-action bar). `list_view` renders `empty_state` via its `:empty` slot by default.

`Samen.Web.ListLive` — a `use`-able mixin supplying `handle_event("sort"|"filter"|"paginate"|"select"|"bulk", …)` over a `%ListState{sort, filter, cursor, page_size, selected}` assign, re-running the read on each mutation. A vertical list view becomes `use Samen.Web.ListLive, resource: Person, reads: &Reads.contacts/3` — **list ergonomics adoption ≈ 0 net vertical lines** (the acceptance measure), proven by converting one driftwood + one pawchart list.

**Invariant L1 (masking on write):** an input bound to a vaulted attribute renders `••••`/disabled on the operator/impersonation plane; the framework create/update `before_action` REJECTS a vaulted-attr change when `plane != :tenant` — no operator plaintext write, enforced at the write path (not the LiveView).

## 3 · Decision — keyset pagination contract

New `Samen.Web.Page` struct + a `Reads` convention: reads take a `%ListState{}`, apply **keyset (cursor) pagination** (`sort |> filter(> cursor) |> limit(page_size + 1)`), default `page_size = 50`, max `200`. Keyset (not offset) is stable under concurrent inserts and avoids deep-offset scans. A `Samen.Web.Reads.bounded!/1` lint (test-exercised) fails on any unbounded read — the `read!`-elimination gate. `samen_core` is untouched: this is a `samen_web` convention.

**JSON:API:** every `json_api do` block gains `default_limit: 50` / `max_page_size: 200` (AshJsonApi 1.7 keyset pagination) — driftwood `Driver`/`DispatchEvent`, demo `Contact`, samen_core identity `Org`/`User`/`Membership`. The `api_contract` snapshot updates as an expected delta; `page[size]` above max is capped, not honored.

## 4 · Decision — notifications engine + inbox (masking-aware)

**`Samen.Notifications.Engine.notify/1`** (kernel, record+dispatch, NO UI): given `{org_id, recipient_id, event_type, channel, render_input}` → render body → vault-route into `Notification.rendered_body` → write the record → emit `Primitives.Audit.notification_sent/3` → for `:email` hand to `Samen.Delivery.Adapter` (ADR-014), for `:in_app` mark `:delivered` → broadcast an **id-only** envelope `{:notification_created, %{id}}` on `samen:notifications:<org_id>:<recipient_id>` (the ADR-012 pattern). Prefs (`NotificationPreference`, abbrev `npr`) gate dispatch.

**Sources wired:** SLA breach (fixes H-9, + a Desk badge), chat mentions (via `ObjectRef.parse`), system events (blocked/failed sends per ADR-014, invoice events).

**`Samen.Web.Notifications.InboxLive`** (framework, `/notifications` route inherited by every vertical): subscribes to the topic; on `{:notification_created, %{id}}` **re-reads that notification through its OWN scope** — so `rendered_body` resolves per the receiving viewer's plane. Masking survives the realtime path by construction, exactly as chat proves (ADR-012 red path 3). `mark_read` flips `read_at`; `Reads.unread_count/2` finally lights the `nav_item` badge.

**Invariant N1 (realtime masking):** the PubSub envelope carries `notification_id` only — never a resolved/plaintext body. An operator subscriber cannot receive plaintext by listening on the topic.
**Invariant N2 (unfurl masking):** a notification body referencing `samen:crm.person:<id>` unfurls via `ObjectRef.resolve/3 → object_card`, every field resolved through `PiiResolution` per viewer plane — operator masked, tenant clear.

## 5 · Decision — empty states + first-run (G5)

`empty_state` is the `list_view` default `:empty`, retrofitted to the bare-table lists (crm contacts/companies, billing invoices, support tickets). `Samen.Web.FirstRun` detects a zero-data tenant and renders a plane-scoped checklist. `Samen.Web.SampleData.load/2` — a guarded (tenant plane only, idempotent, audited, prod-gated) framework action exposing the existing `mix` seed logic behind the empty_state `:sample` slot; it writes through the vault path (Invariant L1/MC-2).

## 6 · Red paths & anti-tautology
- **RP-L1:** operator-plane POST overwriting a vaulted attr with plaintext → rejected, DB unchanged.
- **RP-N1:** operator-plane inbox render — DOM plaintext-leak scan = 0, `••••` present; operator topic-subscriber cannot receive a plaintext body.
- **RP-N2:** operator-plane notification unfurl → masked `object_card`; tenant → clear (anti-tautology: both directions proven live).
- **RP-Page-1:** `page[size]=10000` capped to `max_page_size`; an unbounded read fails `bounded!/1`.
- **RP-Sample-1:** `SampleData.load/2` refused on the operator plane and in prod-without-flag.

## 7 · Consequences
- **+** Verticals inherit CRUD + list ergonomics + empty states + notifications at ≈0 lines (kit + `ListLive` + framework `/notifications`).
- **+** New PII surfaces (write forms, inbox, unfurl) each carry a per-plane masking red path; the impersonation seam holds by construction (no per-viewer masking code).
- **+** `samen_core` stays web-dep-free — only a record+dispatch engine + `NotificationPreference` resource land there.
- **−** One new abbrev (`npr`, per-mount registry rows, ADR-006 tax). `dsk` only if `LocalSink` is a resource (recommendation: keep it a log — no abbrev).
- **−** `api_contract`/LiveView test snapshots shift (expected deltas, regenerated per phase).

## 8 · Amendment (2026-11-13, WP6) — a failed read is not an empty list

§2/§3's `reads/3` contract returned a `%Page{}` and the helpers rescued every error to an EMPTY page, so
a database outage rendered as "No contacts yet" with its create CTA (audit F07/F13, pattern P3). Amended:

- `Samen.Web.Reads.Guard` is the one convention (`run/3`, `page/4`; `{:ok, v} | {:error, :unavailable | :forbidden}`).
  A failure is logged once (read name, org id, exception module names — never row data) and emits
  `[:samen, :web, :read, :error]`.
- `%Page{}` gains `error` (`nil | :unavailable`). A page read that failed returns an EMPTY page with
  `error: :unavailable`; the §3 bound is unchanged.
- `ListLive.reread/2` runs the view's `reads/3` through the Guard; on failure it keeps the previous
  `:page`, the new `:list_state` (filter text, sort, selection) and sets `:list_error`; the new
  `"list_retry"` event re-runs the read. A view renders it with `list_view error={@list_error}
  retry_event="list_retry"` (kit `error_state/1`); a view that does not is unchanged (empty/stale page).
- §5's empty state is shown only for an honest empty result. Detail screens keep 404 semantics for a
  missing record and show the error state for a failure.

Scope shipped: CRM, Search, Support (WP6 phase 1); the rest is tracked in the swallow ratchet
(`Samen.Web.Reads.SwallowLint`). Recipe: `docs/guides/cookbook.md` Recipe 11.

## 9 · Amendment (2026-11-14, ARCH-4) — the keyset page needs a tenant index

§3 bounded every page and made it keyset-stable, but nothing made it *cheap*: the tenant tables carried
no index led by `org_id`, so `WHERE org_id = $1 ORDER BY <sort>, id LIMIT n` was a sequential scan that
slowed with the table. Of 99 / 82 / 74 tables carrying `org_id` in driftwood / pawchart / demo, 27 / 17 /
14 had any btree led by it (89 / 73 / 62 are `OrgScope`-read; none had the `id` tie-break). Amended:

- **The shape.** `Samen.Web.Reads.build/3` orders by `<sort> <dir>, id <dir>` (one direction for both) after
  the `OrgScope` filter. A btree on `(org_id, <sort>, id)` is walked forward for ASC and backward for DESC
  (NULLS included: the defaults Ash emits are exactly a forward / backward scan) and stops at the LIMIT with no
  sort node. The cursor OR-chain is a filter on that walk; a page after a cursor reads from the start of the
  org's range, bounded by one org, not by the table.
- **The sort is declared on the resource**: `use Samen.Resource, keyset_sort: :name` (the `samen` section;
  `Samen.Info.keyset_sort/1`), `nil` meaning `(org_id, id)`. It must equal the list view's `default_sort`
  (`Samen.Web.KeysetSortParityTest` pins the pair). A user who clicks another column header sorts a column the
  index does not lead with: that page reads the org's rows and sorts them, bounded by the org.
- **One module owns the contract** — `Samen.Indexing` — and the migration helper
  (`create_org_keyset_indexes/2`), the retrofit generator (`mix samen.gen.indexes`) and the verifier
  (`mix samen.verify.indexes`) derive from it. Generated apps get the indexes inside the table-creating
  migrations; existing hosts run the generated retrofit migration (`CREATE INDEX CONCURRENTLY`, the
  `concurrent_index/3` carve-out).
- **The verifier reads the live catalog**, not the resource DSL: the hosts' schema is hand-written/templated
  `Samen.Migration`s, so a declared index can be one no migration made, and the planner uses only what the
  database has. A resource it cannot inspect is a violation; the exemption list is empty.
- **Proof the planner uses it**: `Samen.Web.TenantIndexPlanTest` captures the SQL the real `Reads.page!/3`
  sends and `EXPLAIN`s it (person, ticket, message; ASC and DESC; first page and after a cursor), with a
  drop-the-index positive control.
- **`activities_for_person` / `_for_company`**: the `get_path(custom, ["crm_refs", …])` arm renders as
  `jsonb_extract_path_text(custom, 'crm_refs', '<kind>_id') = $n`; partial expression indexes on that exact
  expression let the planner `BitmapOr` it with the `(subject_key, subject_id)` index
  (`Samen.Web.CrmRefsIndexPlanTest`).
