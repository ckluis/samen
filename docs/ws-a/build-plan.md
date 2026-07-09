# WS-A — "Product Reality" · Build Plan

- **Date:** 2026-07-09
- **Reads:** `docs/ws-a/design.md`, ADR-014 (delivery/suppression), ADR-015 (default-deny classifier), ADR-016 (kit/CRUD/notifications).
- **Execution model:** serialized workflow (session limits interrupt runs). **Every phase is independently committable + gate-able** — each ends with a green `ci.sh` across the touched apps and a committed milestone. Default fan-out concurrency = 1 on big agent runs (per project memory: session-limit hits strand ≤1 agent; resume re-runs only stragglers).
- **Model routing:** **opus** for design-bearing/kernel/verify tasks (adapter contract, classifier default-deny, masking chokepoints, gate authoring); **sonnet** for bulk mechanical work (LiveView CRUD wiring, JSON:API block edits, test scaffolding, empty-state retrofits).

---

## Dependency graph

```
A1 (kernel: G3 classifier + delivery/suppression)   ── no web deps; MUST precede vertical proofs
   │
A2 (kit: list/table/form/modal/empty primitives)    ── depends on nothing in A1; can start in parallel-ish but land after A1 commit
   │
A3 (CRUD wiring + JSON:API pagination)  ── depends on A2 (kit primitives) + A1 (suppression fix for marketing writes)
   │
A4 (notifications engine + inbox)       ── depends on A1 (delivery adapter, ADR-014) + A2 (list_view for inbox)
   │
A5 (empty states/first-run + vertical inheritance proof)  ── depends on A2/A3/A4
   │
A6 (adversarial gate)                   ── depends on all
```

A1 is the critical-path root (kernel + claim-integrity). A2 is the leverage root (everything web inherits it). A6 gates the lot.

---

## Phase A1 — Kernel: default-deny classifier + fail-honest delivery + suppression fix

**Scope:** the three kernel changes, all web-dep-free. G3 rider ships here (claim-integrity — must not wait).

**Tasks:**
1. `Samen.Delivery.Adapter` behaviour + `Samen.Delivery.Message` + `LocalSink` + `Smtp`/`Api` skeleton with `configured?/1`. **[opus]**
2. Rewrite `SendWorker.perform/1` for fail-honest semantics (`:blocked` on unconfigured non-test; `:failed` on adapter error; `:delivered` only on `{:ok,_}`). Delete the tautological "send→delivered" test; add RP-D1/RP-D2. **[opus]**
3. Replace `msp_suppression` literal SQL with an Ash-read (preferred) or abbrev-derived query via `Samen.Info.abbrev/1`; add RP-D3 (non-`msp` mount). **[opus]**
4. Default-deny classifier: add the freeform branch to `Projection.classify/3`; flip `PiiClassify` freeform default to opt-out; keep structural-safe types. Add RP-G3-1/2/3. **[opus]**
5. `mix samen.audit.freeform_projection` sweep task; triage + migrate demo/driftwood/pawchart freeform columns (vault-route or two-reviewer `non_pii!`); regenerate `schema.dict.json` baseline + `sink_schema`/`no_plaintext_pii` snapshots. **[sonnet bulk under opus review]**
6. Green every app `ci.sh` (verifier suite + adversarial + game-days). **[opus]**

**Dependencies:** none (root). **AC covered:** AC-G2-1..4, AC-G3-1..5, AC-X-1, AC-X-2. **Agent-tasks:** ~6. **Commit:** kernel milestone.

---

## Phase A2 — Kit: list/table/form/modal/empty primitives + `ListLive`

**Scope:** the presentational + behaviour primitives every vertical will inherit. No vertical wiring yet — build + unit/LV test the primitives against a fixture.

**Tasks:**
1. `simple_form/1` + `form_field/1` (AshPhoenix.Form-backed, inline errors, a11y attrs). **[sonnet]**
2. `modal/1` (role=dialog, focus trap, escape/click-away). **[sonnet]**
3. `empty_state/1` (title/body/icon + `:actions`/`:sample` slots). **[sonnet]**
4. `list_view/1` (sort headers + filter box + keyset pagination footer + bulk-select) wrapping `data_table/1`. **[opus — masking + contract-bearing]**
5. `Samen.Web.ListLive` mixin + `%ListState{}`/`%Samen.Web.Page{}` structs. **[opus]**
6. Component unit/LV tests + a11y assertions (AC-G1-9). **[sonnet]**

**Dependencies:** A1 committed (land after). **AC covered:** AC-G1-3, AC-G1-9 (partial), AC-G5-1 (component). **Agent-tasks:** ~6. **Commit:** kit milestone (framework `ci.sh` green).

---

## Phase A3 — CRUD wiring across LiveViews + JSON:API pagination + read bounding

**Scope:** wire create/edit/delete on every mounted LiveView using A2 primitives; convert reads to keyset pagination; add `default_limit` to every `json_api` block; enforce bounded reads.

**Tasks:**
1. Convert `Reads.*` to `%ListState{}` + keyset pagination; add `Samen.Web.Reads.bounded!/1` lint + test (RP-G1-5). **[opus contract, sonnet mechanical]**
2. Wire CRUD (`simple_form`/`modal`, `phx-click` on "New …") across the ~15 read-only LiveViews + upgrade the raw-input log-activity form. Validation errors + refresh (AC-G1-1/2). **[sonnet bulk, concurrency 1]**
3. Framework create/update `before_action` enforcing Invariant L1 (no operator plaintext vaulted write) + MC-1 red path (RP-L1). **[opus — masking chokepoint]**
4. Add `default_limit`/`max_page_size` to all 7 `json_api` blocks; regenerate `api_contract` snapshots; RP-G1-6 (page-size cap). **[sonnet]**
5. Per-plane masking tests on write forms (AC-G1-7/8, MC-1/2). **[opus]**

**Dependencies:** A2 (primitives), A1 (suppression fix for marketing writes). **AC covered:** AC-G1-1,2,4(partial),5,6,7,8. **Agent-tasks:** ~7 (largest phase; keep concurrency 1). **Commit:** CRUD milestone.

---

## Phase A4 — Notifications engine + inbox + preferences

**Scope:** the delivery engine (kernel record+dispatch), inbox LiveView, unread badge, preferences, and event-source wiring.

**Tasks:**
1. `Samen.Notifications.Engine.notify/1` (render → vault-route → record → audit → id-only broadcast); `NotificationPreference` resource + abbrev `npr` registry rows. **[opus — kernel + masking]**
2. Wire sources: SLA breach (H-9 fix + Desk badge), chat mention, system events (blocked/failed sends, invoice). **[sonnet]**
3. `InboxLive` (subscribe, realtime re-read-per-scope, `mark_read`) at framework `/notifications`; `unread_count` → `nav_item` badge; preferences panel. **[opus contract, sonnet UI]**
4. Masking + realtime red paths: MC-3 (inbox body per plane), MC-4 (unfurl per plane), N1 (id-only envelope), N2 (topic-listener cannot receive plaintext) — AC-G2-5..10. **[opus]**

**Dependencies:** A1 (delivery adapter), A2 (`list_view` for inbox). **AC covered:** AC-G2-5,6,7,8,9,10. **Agent-tasks:** ~5. **Commit:** notifications milestone.

---

## Phase A5 — Empty states / first-run + vertical inheritance proof

**Scope:** retrofit empty states, add first-run + in-app sample data, and PROVE ≈0-line vertical inheritance.

**Tasks:**
1. Retrofit `empty_state` (via `list_view` default) to the bare-table lists (crm contacts/companies, billing invoices, support tickets) — AC-G5-1. **[sonnet]**
2. `Samen.Web.FirstRun` checklist per plane; `Samen.Web.SampleData.load/2` (guarded, idempotent, audited) behind the empty_state `:sample` slot — AC-G5-2/3, RP-G5-3. **[opus — guarded action + masking]**
3. **Inheritance proof:** convert one driftwood + one pawchart list to `use Samen.Web.ListLive`; count the diff → list-ergonomics lines ≈ 0 (AC-G1-4). **[opus — the measure]**
4. Vertical `ci.sh` green (driftwood + pawchart inherit CRUD + list + notifications + empty states with near-zero code). **[opus]**

**Dependencies:** A2/A3/A4. **AC covered:** AC-G1-4, AC-G5-1,2,3. **Agent-tasks:** ~4. **Commit:** inheritance milestone.

---

## Phase A6 — Adversarial gate

**Scope:** the WS-A gate report + adversarial pass; findings fixed in-phase.

**Tasks:**
1. Author `docs/gate-ws-a.md` (gate-report style): every AC-ID with evidence, every red-path/masking test cited, DOM leak scans (operator-plane inbox + write forms + notification unfurl = 0 plaintext), the fail-honest send proof, the G3 provably-absent proof, the ≈0-line inheritance measure. **[opus]**
2. Adversarial probes: anti-tautology on every red path (flip each guarantee to confirm the test fails when the guarantee is broken); attempt operator plaintext write, unconfigured-adapter fake-delivered, non-`msp` suppression bypass, freeform-column projection leak, realtime plaintext leak. Fix findings in-phase. **[opus]**
3. Full `ci.sh` across root + all apps (verifier suite + `mix test` + `--only adversarial` + game-days) green before + after. **[opus]**

**Dependencies:** all. **AC covered:** AC-X-2 + verification of every prior AC. **Agent-tasks:** ~3. **Commit:** WS-A gate milestone.

---

## Totals & routing summary

| Phase | Scope (one line) | AC count | Agent-tasks | Routing |
|---|---|---|---|---|
| A1 | Kernel: default-deny classifier + fail-honest delivery + suppression fix | 11 | 6 | opus-heavy |
| A2 | Kit list/table/form/modal/empty primitives + ListLive | 3 | 6 | sonnet + opus (list_view) |
| A3 | CRUD wiring + JSON:API pagination + read bounding | 8 | 7 | sonnet bulk + opus masking |
| A4 | Notifications engine + inbox + prefs | 6 | 5 | opus kernel + sonnet UI |
| A5 | Empty states/first-run + inheritance proof | 4 | 4 | sonnet + opus (measure) |
| A6 | Adversarial gate | (all) | 3 | opus |

**Total estimated workflow-agent tasks: ~31** (serialized, concurrency 1 on A3's bulk wiring). Riskiest phases: A1 (claim-integrity + expected snapshot churn) and A3 (largest surface). A1 must land first; A6 gates the workstream.
