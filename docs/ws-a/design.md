# WS-A — "Product Reality" · Design Spec

- **Status:** Design (buildable). Build phases follow this spec + ADR-014/015/016; each phase is independently committable + gate-able.
- **Date:** 2026-07-09
- **Scope owner:** WS-A design sub-orchestrator (opus). Design only — no code touched.
- **Reads:** `docs/saas-gap-roadmap.md` (WS-A = G1 + G2 + G5, G3 rider), `docs/gap-discovery/{end-user,harden-existing,builder-dx}.md`, existing ADR-001..016, `docs/gate-*.md`.
- **Mission:** turn the read-only demonstration into a product a tenant can actually use — real CRUD on every mounted LiveView, list ergonomics as **kit defaults** (verticals inherit at ≈0 lines), a **fail-honest** delivery engine + notifications inbox, consistent empty states/first-run, and (rider) a **default-deny** CDC classifier that closes the H-2 claim gap.

**North star (measured):** capability lands in `samen_web` kit / `samen_core` kernel where sanctioned; `driftwood` + `pawchart` + `demo` only PROVE inheritance. Adoption cost for list ergonomics ≈ **0 lines of vertical code**.

---

## 0 · Grounding — what exists today (cited, from this pass)

**Kit (`samen_web/lib/samen/ui.ex`, 852 lines, purely presentational):** `app_shell`, `sidebar`, `nav_item/1` (has an unfed `count`/`dot` badge affordance, ~157–173), `button/1` (~319, forwards `phx-*` via `:rest`), `data_table/1` (~371, two slots `:head` + `:inner_block`, renders ALL rows, **no** sort/filter/pagination/row-select), `pill/1` (renders `%Masked{}` as `••••`), `object_card/1` (~435, the unfurl renderer — every field already resolved through `PiiResolution`), `mask_bar`/`token_blind_bar`, `timeline/1` (~629, the ONLY component with an `empty` affordance). **No** `simple_form`, modal, empty-state, pagination, sort, filter, or bulk-bar component today.

**LiveViews (21 total; 6 handle events):** event-handlers = `crm/contact_live`, `crm/company_live`, `chat/threads_live`, `chat/thread_live`, `support/ticket_live`, `marketing/campaign_live`. The remaining ~15 list/detail views are read-only; primary "New …" buttons render with no `phx-click`. All read-enabled views funnel through a `Reads` module.

**Reads (`.../crm/reads.ex`):** `.read!(scope: scope)` is **unbounded** — `Ash.Query.sort |> Ash.read!(scope: scope) |> resolve_pii(...)`. `resolve_pii/4` calls `Samen.Api.PiiResolution.resolve/4` (the masking chokepoint; fail-safe — on rescue it keeps records masked).

**Masking to pixel (proven):** `Mount.scope/2 → Plane.scope/2` puts `plane: :tenant|:operator` (+ `:impersonation` marker) on the actor; `PiiResolution.resolve_field/8` returns clear (tenant/own), `%Ash.ForbiddenField{}` (operator API, omitted), or `%Masked{}` (impersonation, PRESENT → `••••`); `Samen.Masked` `Phoenix.HTML.Safe` impl renders `••••`. **No plaintext bypass exists in the kit.**

**Kernel gaps in WS-A scope:**
- `marketing/send_worker.ex:27–62` — `StubAdapter.deliver/2` returns `:ok` and the send is marked `:delivered` **unconditionally** (no real dispatch, no fail-closed on unconfigured adapter).
- `marketing/blueprint.ex:450–458` — literal SQL `SELECT 1 FROM msp_suppression WHERE msp_org_id=$1 AND msp_subscriber_id=$2 AND msp_active=true`. `msp` abbrev + table baked in; breaks under any other mount abbrev (crash or silent suppression bypass).
- `cdc/projection.ex:140–165` + `pii_classify.ex:290–301` — a freeform `:string`/`jsonb`/`:map` column with a benign name + no PII-shaped seed value falls through to `:metadata` → **mirrored to the aggregate plane**. "Mask-unknown-by-default" holds for unknown *types*, not unknown *string contents* (H-2).
- `primitives/blueprint.ex` — `Notification` resource exists (abbrev `pnt`; `channel`/`event_type`/`status`/`read_at`/`sent_at`/`metadata`; `rendered_body` vault-routed via `pii do vault(:pii_body); pii_attribute(:rendered_body, ..., vault: :pii_body); reveal(:reveal_notification) end`). **No delivery action, no preferences resource, no inbox LiveView.** `nav_item` badge is unfed.
- JSON:API: 7 `json_api do` blocks (driftwood freight, demo crm, samen_core identity). **None** declare `paginate`/`default_limit`/`max_page_size` (`ash_json_api ~> 1.7`).

**Realtime substrate to reuse:** `chat/pub_sub.ex` — per-topic **id-only** broadcast envelope; each subscriber re-reads through its OWN scope so masking survives the realtime path by construction. `chat/presence.ex` — non-PII meta by construction. This is the exact pattern the notification inbox reuses (topic `samen:notifications:<org_id>:<recipient_id>`, envelope carries `notification_id` only).

**Gate substrate to keep green:** ci.sh runs `mix compile --warnings-as-errors`, the `mix samen.verify.*` suite (`pii_classify --baseline`, `no_plaintext_pii`, `no_pii_columns`, `aggregate_privacy`, `api_contract`, `catalog_parity`, `prefixes`, `sink_schema`, …), `mix test --warnings-as-errors`, `mix test --only adversarial`, and (driftwood) the crypto-shred + PITR game-days. Abbrev registry = `samen_core/priv/abbrev_registry.json` (`"abbrev": "Module"` rows, 3-letter, never recycled, verifier-enforced).

---

## 1 · G1 — Real CRUD + list ergonomics (kit-first)

### 1.1 Architecture

The kit gains **four new presentational primitives** + **one behaviour module**, and the `Reads` convention gains a **paginated query builder**. Verticals inherit by calling the kit; the vertical-code cost is the acceptance measure.

**Kit components (new, in `samen_web/lib/samen/ui.ex` or a sibling `ui/` dir):**

1. `simple_form/1` — changeset/`AshPhoenix.Form`-backed form wrapper. Attrs: `for` (form), `phx-submit`, `phx-change`, optional `phx-target`. Slots: `:inner_block`, `:actions`. Renders inline field errors from `form[:field].errors`. **Masking rule:** an input bound to a vaulted field whose current value is `%Masked{}` renders a disabled/`••••` placeholder on the operator/impersonation plane and MUST NOT submit a plaintext overwrite (see §Masking, MC-1).
2. `form_field/1` — a single labelled field (`input`/`select`/`textarea`) with error slot + `aria-describedby` wiring. Replaces the raw `<input name="activity[subject]">` markup.
3. `modal/1` — accessible dialog (`role="dialog"`, focus trap, `phx-click-away`/`Escape` close, `aria-labelledby`). Hosts create/edit forms without a full-page nav.
4. `empty_state/1` — see §3 (G5); shared by list defaults.
5. `list_view/1` (the behaviour-bearing primitive) — wraps `data_table/1` and adds, as **kit defaults**: sortable column headers (`phx-click="sort"` emitting `{field, dir}`), a filter/search bar (`phx-change="filter"` debounced), a pagination footer (prev/next + page size), and an optional bulk-select column (checkbox header + row checkboxes + a bulk-action bar that appears when ≥1 selected). Attrs: `page` (a `%Samen.Web.Page{}`), `sort`, `filter`, `selectable` (bool), `bulk_actions` (list). Slots: `:head`, `:row`, `:bulk_bar`, `:empty`.

**Behaviour module (new, `samen_web/lib/samen/web/list_live.ex`):** `Samen.Web.ListLive` — a `use`-able mixin giving any LiveView the `handle_event("sort"|"filter"|"paginate"|"select"|"bulk", …)` handlers that mutate a `%ListState{sort, filter, page, cursor, selected}` assign and re-run the read. A vertical list view becomes: `use Samen.Web.ListLive, resource: Person, reads: &Reads.contacts/3` — the sort/filter/paginate/bulk wiring is inherited (adoption ≈ 0 net list-ergonomics lines).

**Paginated reads convention (`crm/reads.ex` + a shared `Samen.Web.Reads` helper):**
- New `Samen.Web.Page` struct: `{items, cursor, next_cursor, prev_cursor, has_more, page_size, sort, filter, total_estimate}`.
- `Reads.contacts/3` gains a `%ListState{}` arg; internally applies **keyset (cursor) pagination** (`Ash.Query.sort` + `Ash.Query.filter(> cursor)` + `Ash.Query.limit(page_size + 1)`), never `offset` for hot lists (keyset is stable under inserts and avoids deep-offset scans). Default `page_size = 50`, max `200`.
- **`read!` elimination:** every unbounded `.read!()` in `samen_web` reads gains an enforced `limit`. A new verifier-adjacent lint (`Samen.Web.Reads.bounded!/1`, exercised by a test) fails if a read in the reads modules omits a limit. Kernel-adjacent: this is a `samen_web` convention, NOT a `samen_core` change (kernel stays web-dep-free).

**JSON:API `default_limit`:** add a shared `Samen.JsonApi.pagination/0` macro-helper (or a documented block snippet) and apply `paginate keyset?: true, default_limit: 50, max_page_size: 200` (or the AshJsonApi 1.7 equivalent — `default_limit`/`max_page_size` on the resource's `json_api do` block) to every existing `json_api do` block: driftwood `Driver`+`DispatchEvent`, demo `Contact`, samen_core `Org`/`User`/`Membership`. The `api_contract` snapshot updates in the same commit (expected snapshot delta, not a break).

### 1.2 Masking (new PII write surfaces)

CRUD write forms are a NEW PII surface (roadmap watch-list). Rules (MC = masking criterion):
- **MC-1 (no operator plaintext write):** on the operator/impersonation plane, a vaulted field renders `••••` and its input is disabled; a submitted changeset MUST NOT overwrite a vaulted attribute with operator-authored plaintext. Enforced at the Ash write path (a `before_action` on the framework create/update that rejects a vaulted-attr change when `plane != :tenant`), NOT in the LiveView. Red-path test: operator impersonation POSTs a plaintext `full_name` → change rejected, DB unchanged.
- **MC-2 (tenant write chokepoint):** tenant create/edit of Person/Company routes the vaulted attr through the existing vault write path (same as seeds), never a raw column write.

### 1.3 Out of scope (G1)
- Saved views / faceted multi-filter UI (single sort + single search/filter box only; saved views are WS-E).
- Server-side full-text search (`⌘K`) — that is G9/WS-E; the filter box here is a simple `ilike`/bounded-attr filter over already-selected columns.
- Optimistic client-side reordering; virtualized rendering (streams are a P2 perf item, G12).

---

## 2 · G2 — Delivery engine + notifications inbox (fail-honest)

### 2.1 Delivery adapter contract (kernel — see ADR-014)

**Behaviour `Samen.Delivery.Adapter`** (new, `samen_core/lib/samen/delivery/`): the outbound-email contract, pluggable per host.

```
@callback deliver(message :: Samen.Delivery.Message.t(), config :: map()) ::
  {:ok, receipt :: map()} | {:error, reason :: term()}
@callback configured?(config :: map()) :: boolean()
```

- **`Samen.Delivery.Message`** — token-only envelope: `to_subscriber_id`, `org_id`, `template_id`, `send_id`; the recipient email is looked up at delivery time via the vault reveal path under a grant, NEVER in the struct (matches the send_worker doc convention).
- **Adapters shipped:** `LocalSink` (dev/test — persists the rendered message to a local table/log and returns `{:ok, %{sink: true}}`, an HONEST "captured, not delivered"); `Smtp`/`Api` **skeleton** (real `deliver/2` guarded by `configured?/1`; returns `{:error, :not_configured}` when creds absent — it does NOT fake success).
- **Fail-honest semantics (the load-bearing change):** `SendWorker.perform/1` now: (a) if no adapter configured AND env is not `:test` → the send goes to `:blocked` (not `:delivered`) and emits an audit `marketing.send.blocked` + a notification to the operator; the Oban job returns `{:error, :adapter_unconfigured}` so it retries/alerts, NEVER `:delivered`. (b) adapter `{:ok, receipt}` → `:delivered` with the receipt. (c) adapter `{:error, r}` → `:failed` (retriable) — the send is provably NOT delivered. This kills the tautological "send → delivered" green.

### 2.2 Suppression fix (kernel — ADR-014)

Replace the literal `msp_suppression` SQL (`blueprint.ex:450–458`) with an abbrev-derived query. The blueprint mints its resources with a declared `abbrev`; `Samen.Info.abbrev/1` reads it (`Spark.Dsl.Extension.get_opt(resource, [:samen], :abbrev, nil)`). The suppression resource module is known at blueprint-expansion time, so derive:

```
abbrev   = Samen.Info.abbrev(<SuppressionResource>)     # e.g. "msp" or "xyz"
table    = "#{abbrev}_suppression"
org_col  = "#{abbrev}_org_id" ; sub_col = "#{abbrev}_subscriber_id" ; act_col = "#{abbrev}_active"
```

Prefer building the check via an **Ash read on the Suppression resource** (`Ash.exists?`/`Ash.Query.filter` scoped to org+subscriber+active) over raw SQL — this removes the string entirely and inherits `OrgScope`. Fall back to abbrev-derived SQL only if the resource isn't reachable at that point. Red-path: mount Marketing under a non-`msp` abbrev, add an active suppression row, attempt a send → refused (proves no silent bypass and no crash).

### 2.3 Notifications delivery engine (kernel-adjacent + web)

**Engine (`Samen.Notifications.Engine`, new in `samen_core` — pure record + dispatch, NO UI):** a `notify/1` action that, given `{org_id, recipient_id, event_type, channel, render_input}`, (1) renders the body, (2) vault-routes it into `Notification.rendered_body` via the existing `pii_attribute`, (3) writes the `Notification` record (status `:pending` → `:delivered` for in-app; `:pending` → hand to `Samen.Delivery.Adapter` for email), (4) emits the audit event via the existing `Primitives.Audit.notification_sent/3`, (5) broadcasts an **id-only** PubSub envelope (`{:notification_created, %{id: ...}}`) on `samen:notifications:<org_id>:<recipient_id>`.

**Event sources wired (kernel + web):**
- **SLA breach** (fixes H-9): the support breach worker calls `notify/1` (`event_type: "sla_breach"`) instead of only flipping `breached=true`. Also surfaces an at-risk/breached badge in the Desk LiveView.
- **System events:** send `:blocked`/`:failed`, invoice events (existing billing state changes).
- **Chat mentions:** when `ObjectRef.parse` finds a `@participant`/mention in a chat send, `notify/1` fires (`event_type: "chat_mention"`). Reuses the existing chat unfurl parse.

**Preferences (new resource — see abbrev registry §5):** `NotificationPreference` — `(recipient_id, event_type, in_app_enabled, email_enabled, quiet_hours)`; the engine checks prefs before dispatch (default-on for in-app, opt-in for email digests). No PII (bounded recipient_id + enums + bools). Abbrev `npr`.

### 2.4 Inbox UI (web)

**`notifications/inbox_live.ex`** (new framework LiveView, `/notifications` route added to the framework router so every vertical inherits): mounts, subscribes to `samen:notifications:<org_id>:<recipient_id>`, reads the recipient's notifications through a `Reads.notifications/3` (paginated via §1 `list_view`), renders each as a row/card. On `{:notification_created, %{id}}` it re-reads that notification **through its own scope** (so body resolves per viewer plane — masking survives realtime by construction, exactly like chat). `mark_read` action flips `read_at`. **Unread badge:** `Reads.unread_count/2` feeds the existing `nav_item` `count` affordance (finally lit).

**Preferences UI:** a `/notifications/settings` panel over `NotificationPreference` (per-user toggle grid).

### 2.5 Masking (new PII render surfaces)

- **MC-3 (inbox body masking):** `Notification.rendered_body` is vaulted. Tenant viewing own inbox → clear; operator impersonating → `%Masked{}` → `••••`; operator API/cross-tenant → forbidden/absent. Red-path masking test per plane.
- **MC-4 (unfurl-in-notification masking):** a notification body referencing a Samen object (`samen:crm.person:<id>`) unfurls via the existing `ObjectRef.resolve/3` → `object_card`, which resolves every field through `PiiResolution` per viewer plane. Test: operator-plane render of a person-referencing notification shows a masked card; tenant shows clear.

### 2.6 Out of scope (G2)
- Email **digest/batching** + quiet-hours *scheduling* engine (preference fields exist; the scheduler is a fast-follow). MVP = per-event in-app + immediate email via adapter.
- SMS/push/webhook channels beyond the enum (in_app + email only wired; others remain declared-but-inert).
- A real SMTP/ESP integration test against a live provider (skeleton + LocalSink + `configured?` red-path only; live creds are an operator TODO).

---

## 3 · G5 — Onboarding / empty states / first-run (kit-first)

### 3.1 Architecture

**`empty_state/1` kit component:** attrs `title`, `body`, `icon`; slots `:actions` (primary CTA), `:sample` (optional "load sample data" affordance). Rendered by `list_view/1`'s `:empty` slot **by default** — so every list that adopts `list_view` gets a consistent empty state at zero extra cost. Retrofit the main lists that currently render a bare zero-row table (crm contacts/companies, billing invoices, support tickets).

**First-run per plane:** a `Samen.Web.FirstRun` helper detecting "tenant has zero rows across its core resources" → renders a first-run checklist card on the plane's landing view (tenant plane: "add your first contact / load sample data / invite a teammate"; operator plane: n/a — operator lands on accounts). Framework-level so every vertical inherits.

**In-app sample-data offer:** the seed logic currently invoked via `mix` (e.g. `driftwood/lib/driftwood/seeds.ex`) is exposed behind a **guarded** framework action `Samen.Web.SampleData.load/2` (tenant plane only, idempotent, audited, disabled in prod unless a flag is set). The empty_state `:sample` slot triggers it. **Masking note:** sample data is synthetic (no real PII), but it still writes through the vault write path (MC-2) so the demonstration is honest.

### 3.2 Out of scope (G5)
- Guided product tours / tooltips / coach-marks.
- Per-vertical bespoke first-run content beyond the framework checklist (verticals may override the copy; the mechanism is framework).

---

## 4 · G3 rider — CDC classifier: heuristic → default-deny mechanism (kernel — see ADR-014)

### 4.1 The change

Replace the name+type "provably non-PII" heuristic (`pii_classify.ex`, `cdc/projection.ex`) with a **default-deny** rule for freeform content types:

**Rule:** a physical column whose Ash type is **freeform** (`:string`, `:ci_string`, `:text`, `:map`, `:jsonb`, or any type not on the structural-safe allowlist) is **EXCLUDED from the CDC/aggregate projection UNLESS** it is one of: (a) vault-routed (`pii_attribute` → carries a `vt_*` token, mirrored as `:token`), or (b) explicitly allowlisted via a **verifier-backed `non_pii!` declaration** with distinct second-reviewer metadata (the existing `Samen.NonPii` registry, `cleared_by != reviewed_by`). Everything else freeform is classified `:plaintext_pii` → refused from the mirror and `assert_no_plaintext!/1` RAISES on an explicit demand.

Structural-safe types (bounded id / enum / timestamp / number / bool) remain `:metadata`-class and mirror as today — the change is scoped to **freeform content types only**, so it does not over-refuse IDs/enums/dates.

### 4.2 Why this closes H-2

Today `classify/3` (`projection.ex:140`) only refuses on `Context.plaintext_pii_type?(type)` (a type check) and buckets everything else via `scalar_kind/1` → `:metadata`. A benign-named `drv_notes :string` with no seed value produces empty `pii_classify` reasons → passes → mirrored. Under default-deny, `drv_notes` is freeform + not vault-routed + not `non_pii!`-cleared → `:plaintext_pii` → **provably absent from the projection**. The verifier miss-mode flips from *silent-pass* to *fail-closed*.

### 4.3 Migration path for existing verticals

This will re-classify currently-mirrored freeform columns as `:plaintext_pii`, which would (a) fail `pii_classify`/`no_plaintext_pii` and (b) shrink the projection. Migration:
1. **Audit sweep:** a one-shot `mix samen.audit.freeform_projection` lists every currently-`:metadata` freeform column across `demo`/`driftwood`/`pawchart`.
2. **Triage each:** genuine PII → declare `pii_attribute` (vault-route it) → mirrors as `:token`; genuinely-safe (e.g. a bounded status string that should have been an enum) → either fix the type OR add a `non_pii!` two-reviewer registry entry.
3. **Baseline shift:** `schema.dict.json` baseline + the `pii_classify --baseline` invocation are regenerated in the migration commit; the aggregate/CDC snapshot (`sink_schema`, `no_plaintext_pii`) updates as an expected delta.
4. **Sequencing:** because this changes the classifier default, it MUST land in phase A1 (kernel) BEFORE any vertical inheritance proof, and each vertical's re-classification is a discrete, gate-able step.

### 4.4 Masking / fail-closed
- **G3-red:** an unlisted freeform column (`:string`, no vault, no `non_pii!`) is provably ABSENT from `Projection.project/1` output AND `assert_no_plaintext!(resource, [that_col])` RAISES. This is the anti-tautology probe (the test must FAIL if the column ever appears).
- **G3-green:** a `non_pii!`-cleared (two-reviewer) freeform column IS present as a safe scalar; a vault-routed one IS present as `:token`.

### 4.5 Out of scope (G3)
- A **runtime value-shape scan** on the CDC write path (belt-and-suspenders; the compile-time default-deny is the mechanism this workstream ships). Noted for WS-C.
- Reclassifying non-freeform types (IDs/enums/timestamps stay as-is).
- The impersonation `reason` plaintext channel (H-7) — separate WS-C item.

---

## 5 · Data-model deltas & abbrev-registry entries

| New table | Resource module (mount example) | Abbrev | Contents | PII? |
|---|---|---|---|---|
| `<abbrev>_notification_preference` | `Demo.PrimitivesScope.NotificationPreference` | **`npr`** | `recipient_id` (uuid), `event_type` (string/enum), `in_app_enabled` (bool), `email_enabled` (bool), `quiet_hours` (map of bounded ints) | No (bounded id + enums + bools) |
| `<abbrev>_delivery_sink` (dev/test only, LocalSink) | `Demo.PrimitivesScope.DeliverySink` (or kept as a log, not a resource) | **`dsk`** (only if realized as a resource) | `send_id`, `to_subscriber_id`, `template_id`, `status`, captured-at | No (token-only) |

- **`npr`** is required (preferences resource is load-bearing for G2 prefs). Add one row to `samen_core/priv/abbrev_registry.json`: `"npr": "Demo.PrimitivesScope.NotificationPreference"` (and the analogous vertical modules on mount, per ADR-006 ergonomic tax — each mounting app appends its own row).
- **`dsk`** is required ONLY if `LocalSink` is realized as an Ash resource; if it's a log file / process table, no abbrev entry is needed. **Recommendation:** keep LocalSink as a non-resource log to avoid a per-mount abbrev tax — flag for build-time decision.
- No new tables for G1 (list ergonomics are query-layer + kit) or G5 (empty states/first-run are UI + a guarded action over existing seeds).

---

## 6 · Acceptance criteria (numbered · test-typed)

Test types: **U**=unit, **LV**=liveview (Phoenix.LiveViewTest), **RP**=red-path must-fail, **MC**=masking (per-plane), **VER**=verifier/gate, **A11y**=accessibility assertion.

### G1 — CRUD + list ergonomics
- **AC-G1-1 (U+LV):** every mounted list/detail LiveView has working create + edit + delete via `simple_form`/`modal`; the primary "New …" button carries a `phx-click` and opens a form. *(previously 6/21 → target 21/21 write-capable where a create action exists.)*
- **AC-G1-2 (LV):** submitting an invalid create shows inline field errors (no crash, no silent drop); a valid submit persists + refreshes the list.
- **AC-G1-3 (U+LV):** `list_view/1` provides sort (toggle asc/desc per column), a filter box, keyset pagination (prev/next, page size), and bulk-select — all as **kit defaults**.
- **AC-G1-4 (measure):** a vertical list view adopts full list ergonomics in **≈0 net list-ergonomics lines** (`use Samen.Web.ListLive`); proven by converting one driftwood + one pawchart list and counting the diff (ergonomics lines ≈ 0).
- **AC-G1-5 (U):** every `Reads` read is bounded (a `limit` present); the `bounded!/1` lint test fails on an unbounded read. **RP-G1-5:** an intentionally-unbounded read makes the test FAIL.
- **AC-G1-6 (VER):** every `json_api do` block declares `default_limit`/`max_page_size`; the `api_contract` snapshot reflects pagination; an index route returns ≤ `max_page_size` rows. **RP-G1-6:** a request for `page[size]=10000` is capped, not honored.
- **AC-G1-7 (MC):** operator/impersonation plane — a create/edit form on a vaulted field renders `••••` + disabled input. **RP-G1-7 (MC):** an operator-plane POST attempting to overwrite a vaulted attr with plaintext is REJECTED; DB unchanged (MC-1).
- **AC-G1-8 (MC):** tenant create/edit of Person/Company writes vaulted attrs through the vault write path (MC-2), never a raw column write.
- **AC-G1-9 (A11y):** `form_field`/`modal` carry `aria-*`/`role`; table headers carry `scope`.

### G2 — Delivery + notifications
- **AC-G2-1 (U):** `Samen.Delivery.Adapter` behaviour + `LocalSink` + `Smtp`/`Api` skeleton exist; `configured?/1` gates real dispatch.
- **AC-G2-2 (RP — the fail-honest proof):** with NO adapter configured in a non-`:test` env, a send is marked `:blocked` (NOT `:delivered`), emits `marketing.send.blocked` audit + operator notification, and the Oban job returns error/retries. **The old tautological "send→delivered" green is deleted.**
- **AC-G2-3 (U+RP):** adapter `{:error, _}` → send `:failed`, provably NOT `:delivered`; adapter `{:ok, receipt}` → `:delivered` with receipt.
- **AC-G2-4 (RP):** Marketing mounted under a **non-`msp`** abbrev with an active suppression row REFUSES the send (no crash, no silent bypass) — suppression table derived from the blueprint abbrev.
- **AC-G2-5 (U+LV):** `Notifications.Engine.notify/1` writes a `Notification`, vault-routes `rendered_body`, emits audit, broadcasts an **id-only** envelope; the inbox LiveView renders it in realtime.
- **AC-G2-6 (LV):** SLA breach fires a notification (fixes H-9) + a Desk badge; a chat mention fires a `chat_mention` notification; a blocked/failed send fires a system notification.
- **AC-G2-7 (LV):** unread badge on `nav_item` reflects `unread_count`; `mark_read` decrements it.
- **AC-G2-8 (MC):** inbox `rendered_body` masks per plane — tenant clear, operator impersonation `••••`, operator API absent (MC-3). **RP-G2-8:** operator-plane inbox render contains zero plaintext (`••••` present, DOM leak scan = 0).
- **AC-G2-9 (MC):** a notification referencing a Samen object unfurls a per-plane-masked `object_card` (MC-4) — operator masked, tenant clear.
- **AC-G2-10 (U):** the realtime envelope carries only `notification_id` (no rendered body on PubSub). **RP-G2-10:** an operator subscriber cannot receive plaintext by listening on the topic.

### G5 — Empty states / first-run
- **AC-G5-1 (LV):** every main list renders the consistent `empty_state` (via `list_view` default) at zero rows — crm contacts/companies, billing invoices, support tickets included.
- **AC-G5-2 (LV):** first-run checklist appears for a zero-data tenant on the plane landing view and disappears once data exists.
- **AC-G5-3 (LV+MC):** the in-app "load sample data" offer triggers `SampleData.load/2` (tenant plane only, idempotent, audited); it writes through the vault path (MC-2). **RP-G5-3:** the sample-data action is refused on the operator plane and in prod-without-flag.

### G3 rider — default-deny classifier
- **AC-G3-1 (VER):** a freeform (`:string`/`:text`/`:map`/`jsonb`) column with no vault + no `non_pii!` clearance classifies `:plaintext_pii` and is EXCLUDED from `Projection.project/1`.
- **AC-G3-2 (RP — anti-tautology):** the excluded freeform column is PROVABLY ABSENT from the projection AND `assert_no_plaintext!(resource, [col])` RAISES; the test FAILS if the column ever appears.
- **AC-G3-3 (VER):** a `non_pii!`-cleared (distinct two-reviewer) freeform column IS present as a safe scalar; a vault-routed one IS present as `:token`.
- **AC-G3-4 (VER):** the migration sweep re-classifies each vertical's existing freeform columns; `pii_classify`/`no_plaintext_pii`/`sink_schema`/`aggregate_privacy` stay green post-migration with updated baseline.
- **AC-G3-5 (RP):** structural-safe types (uuid/enum/timestamp/number/bool) are NOT over-refused — they remain mirrored (guards against the default-deny becoming a projection-killing over-block).

### Cross-cutting
- **AC-X-1 (VER):** `samen_core` stays web-dep-free (no `phoenix`/`liveview` dep added); kernel changes are the send adapter behaviour, suppression fix, notification engine (record+dispatch, no UI), and classifier only.
- **AC-X-2 (VER):** every `mix samen.verify.*`, `mix test`, `mix test --only adversarial`, crypto-shred + PITR game-days, and every app's `ci.sh` stay green before/after each phase.

---

## 7 · Explicit out-of-scope for WS-A (whole workstream)
- Global search / `⌘K` (G9), files engine + upload (G14), import/export (G15), self-serve settings/2FA (G18), responsive/mobile CSS (G20), i18n/tz/currency (G24), full a11y pass (G25) — later workstreams.
- Feature-flag runtime, MRR movements, per-tenant health drill-down, product analytics — WS-B.
- DSAR self-serve, retention admin, runtime CDC value-shape scan, impersonation-reason redaction — WS-C.
- Generator emission of these new patterns (web/API/seed scaffolds) — WS-D (deliberately after A so the generator scaffolds the REAL patterns).
- Real SMTP/ESP/Stripe live-credential integration, ClickHouse/ClickPipes activation — operator TODOs.
