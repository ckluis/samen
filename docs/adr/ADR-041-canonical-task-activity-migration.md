# ADR-041 — The canonical Work-scope Task + the destructive CRM-Activity migration

Status: Accepted
Date: 2026-07-23
Deciders: fable (AUTHOR, T96), operator ruling **M5** (OVERRIDE)
Consumes: **ADR-036** (rich types — `Samen.Type.Priority`), **ADR-037** (Ash-ecosystem
verdicts §5.3/§5.4/§5.8/§5.9), **ADR-039** (automation — Task is a trigger subject),
**ADR-040 §5.9** (soft-delete roster — the canonical Task arrives `archivable true`),
**ADR-015** (default-deny CDC), **ADR-011/ADR-012** (CRM timeline + the object-unfurl seam).
Implemented by: **T43** (build the Work scope — *no CRM contact*) + **T97** (the destructive
migration + CRM rewire + Activity removal). This ADR fixes the contract for both; the
**file-touch partition in §7 BINDS both tasks and is reviewer-enforced**.

---

## 1 · Context

Operator ruling **M5 (OVERRIDE)** on spec §F1: there is **one canonical Work-scope Task**;
the CRM `Activity` resource is **destructively migrated into it and removed** — a pre-1.0
contract break, accepted. This is the highest-risk change of Phase 3: it *removes a table*
and rewires the CRM detail timeline, the CDC-eligible surface, the catalog, and the seeds
across every host (demo, driftwood, pawchart, and the samen_web test host).

By the >~10-file cross-cutting rule this change is **fronted by an ADR** (this document) and
executed as a **two-task chain under a binding file partition**, per the decompose-cross-cutting
convention:

- **T43** builds the new Work substrate scope (Project + the canonical Task + self-referential
  Subtask tree) with **F8 discipline** (blueprint macro + catalog + policies + masked
  rendering + gen support + generated LiveViews). **T43 touches NO CRM code** — it *creates the
  destination*.
- **T97** *moves the data and removes the source*: copies every `Activity` row into the Task
  table, rewires the CRM timeline/CDC/catalog reads onto Task, drops the `Activity` table, and
  ships every host mirror migration in the same task.

The Work scope is **CRM-agnostic by construction**: Task links to "what it is about" through
the existing catalog object-ref (`samen:<resource-key>:<uuid>`, `Samen.Web.ObjectRef`), never
through CRM foreign keys. This is precisely what makes the T43/T97 partition honest — the Work
scope can be built, tested, and mounted without the CRM existing.

### 1.1 Non-goal / a trap to name up front

`Core.Ctx.Activity` (abbrev **`cea`**, table `cea_activity`,
`samen_core/test/support/context_fixture.ex`) is a **separate kernel context-DSL test fixture**
— it carries a PII field (`pii_cea_attendee_note`) and drives `context_test.exs`,
`context_red_path_test.exs`, and `cdc_default_deny_projection_test.exs`. **It is NOT the CRM
Activity and is OUT OF SCOPE for this migration.** Any diff touching `Core.Ctx.Activity`,
`context_fixture.ex`, or the three tests above **is a partition violation** (§7.4 tripwire).

---

## 2 · ADR-037 / ADR-039 / ADR-040 verdicts consumed (binding)

Per M6 the design consumes ADR-037's package verdicts rather than re-deciding them; each is
stated as adopt/reject **for the canonical Task specifically**.

| Package / capability | ADR verdict | Applied to the canonical Task |
|---|---|---|
| **ash_state_machine** (ADR-037 §5.8 **ADOPT**, *targeted: new state-bearing resources only*) | ADOPT targeted | **NOT applied.** Task `status` is a plain constrained atom enum, not a state machine — §4.3 gives the rationale (heterogeneous absorbed kinds; a bulk migration must set terminal states directly; §5.8 scopes adoption to resources whose *value is transition-guarding*). Reversible post-1.0. |
| **ash_archival** (ADR-037 §5.3 **ADOPT**; ADR-040 §5.9 roster) | ADOPT | **Applied.** Task is `archivable true` (ADR-040 §5.9 note: "the canonical Task arrives `archivable true`"). `crm.activity` is *already* archivable (§5.9 roster, adopted in T37c); the migration copies `archived_at` so trash state survives (§6.1, §8). |
| **ash_paper_trail** / E7 `versioned` (ADR-037 §5.4 **ADOPT**; ADR-040 §6) | ADOPT (opt-in) | **Declined for Task** — no spec line demands task change-history; keep the stored surface minimal (ADR-040 §6.1 is per-resource opt-in). A vertical may flip `versioned true` later. The hash-chain governance audit tier is untouched and covers Task's governed actions like any resource. |
| **ash_oban** (ADR-037 §5.9 **ADOPT**) | ADOPT | **Applied via ADR-039**, not a new Task worker: Task is a `resource_event` trigger subject and a natural due-date reminder/escalation client (§5). |
| **Samen.Type.Priority** (ADR-036 D2/H2 — integer-rank, atom face, `:non_pii` + `TypeClearance`) | — | **Applied.** Task `priority` uses it (ordered, sortable in `Reads` — c15). |
| **AshMoney** (ADR-037 §5.2) | ADOPT | **N/A** — Task carries no money field. |

---

## 3 · The canonical Task resource (spec §F1)

### 3.1 A new ninth-and-tenth… the **Work** substrate scope

A new `Samen.Scopes.Work` blueprint (the two-file mount-macro + `define_*` pattern every scope
uses — `support/` is the closest structural template: `scope.ex` mount macro +
`scope/blueprint.ex` define macros + policies). It ships **two resources**:

- **`Project`** — a container noun (name, status, owner, org-scoped).
- **`Task`** — the canonical Work item, **self-referential** for the Subtask tree
  (`parent_id`, cycle-refused). F1's "Subtask (or self-referential Task tree)" is realized as
  the self-reference, not a third resource — one table, one lifecycle.

Both are **tenant-plane, org-scoped** (INV-2 §9), governed by the standard policy stack
(`OrgScope` read; `OrgScope` + `{RoleAtLeast, role: :member}` write), and registered in the
catalog through the scope's `resources do resource(...) end` block (no bespoke catalog file).
Abbrevs are minted in **T43** through `mix samen.abbrev.reserve` (the ONLY sanctioned writer,
ADR-023) — this ADR uses `<abbrev>_` placeholders and pre-allocates nothing (§7.5).

### 3.2 Task schema — field by field (types per ADR-036)

Physical columns are `<abbrev>_<name>` (abbrev per host mount). The schema is designed to
**absorb Activity's semantics verbatim** wherever possible, minimizing migration transform and
CRM-rewire churn.

| Attribute | Ash type | allow_nil? | default | Source (Activity) | Notes |
|---|---|---|---|---|---|
| `kind` | `:atom` `one_of [:task,:call,:email,:meeting,:note]` | false | `:task` | `type` (verbatim) | **identical to Activity's `type` enum** (same five atoms); drives the timeline glyph via the entry `:type` key (ADR-011 §6.2, object.ex:206) |
| `title` | `:string` | true | — | `subject` | canonical task vocabulary; maps to the timeline `subject` display key |
| `body` | `:string` | true | — | `body` (verbatim) | freeform; **default-deny CDC** (§6.2) |
| `status` | `:atom` `one_of [:pending,:in_progress,:completed,:cancelled]` | true | `:pending` | `status` (verbatim) | Activity's exact enum **+ `:in_progress`**; plain enum, **not** a state machine (§4.3) |
| `priority` | `Samen.Type.Priority` | true | `:normal` | — (added) | ordered/sortable (c15); Activity had none — a documented added default, not dropped data (§5.2) |
| `due_at` | `:utc_datetime` | true | — | `due_at` (verbatim) | F1 due-date; reminder/escalation anchor (§5) |
| `completed_at` | `:utc_datetime` | true | — | `completed_at` (verbatim) | preserves the timeline "at" = `completed_at || inserted_at` (§6.1) |
| `subject_key` | `:string` | true | — | derived (§5.1) | catalog resource-key of the object this task is about (`"crm.person"`, `"crm.company"`, `"crm.opportunity"`) — CRM-agnostic |
| `subject_id` | `:uuid` | true | — | derived (§5.1) | the object-ref id; `(subject_key, subject_id)` = the `Samen.Web.ObjectRef` anchor |
| `custom` | `:map` | true | — | `custom` (verbatim, + `crm_refs`) | Tier-1 custom bag; carries `custom["author"]` (timeline `who`) and the preserved multi-ref set (§5.1) |
| `owner` (`owner_id`) | `belongs_to User`, `:uuid` | true | — | — (added) | F1 owner; ADR-039 §5.2 `assign_owner` default attr; migrated rows `nil` (§5.2) |
| `parent` (`parent_id`) | `belongs_to Task`, `:uuid` | true | — | — (added) | the Subtask self-reference; **cycle-refused** (§3.4) |
| `project` (`project_id`) | `belongs_to Project`, `:uuid` | true | — | — (added) | F1 Project link; migrated rows `nil` (§5.2) |

Base-macro columns `id`, `org_id`, `inserted_at`, `updated_at` are injected as for every
resource; **the migration copies `id`, `org_id`, and both timestamps verbatim** (§5, §8 — the
timeline sorts by `inserted_at: :desc`, so a defaulted `inserted_at` would scramble history).
Once `crm.activity` is archivable (T37c), Task's `archived_at` is copied verbatim too.

### 3.3 PII posture (INV-1)

CRM Activity was **PII-free by declaration** ("no PII in the activity row itself — references
are opaque IDs", `blueprint.ex:317`). The canonical Task **inherits that posture**: no attribute
routes to the vault. `owner_id` is a user id (non-PII); `subject_key`/`subject_id` are a catalog
key + id (non-PII); `priority` self-classifies `:non_pii` behind its `TypeClearance` (ADR-036).
`title`/`body`/`custom` are freeform user content — **not** vaulted (parity with Activity) and
**default-deny-excluded from CDC mirroring** (§6.2). A vertical needing a PII-classified task
field routes it through a Tier-1 custom field to the vault (ADR-036 H6) — never a core change.

**INV-1 declaration test (T43 c3):** the Work scope's catalog PII map is asserted **empty** (no
vaulted column) — the either-way INV-1 proof for a no-PII scope.

### 3.4 Subtask tree — cycle refusal

`parent_id` self-reference. A `Samen.Scopes.Work.Task` create/update change refuses a parent
cycle (a node cannot be its own ancestor) and bounds depth, mirroring the loop-guard precedent
(ADR-039 §4.7 cycle refusal). T43 ships the red test (a legal 3-level tree accepted; a cycle
refused, with the positive control — anti-tautology).

### 3.5 Soft-delete + audit classification (ADR-040)

- **Soft-delete:** `archivable true` (ADR-040 §5.9 roster — a user-managed noun). Task and
  Project both get the `<abbrev>_archived_at` column, the partial-unique-index convention
  (§5.3 of ADR-040) on any unique index, `:archive`/`:restore`/`:archived` actions, and the
  relationship/aggregate leak red test. **Cascade:** Project → Task is **not** a composition
  cascade (a task outlives its project's archival — default no-cascade, ADR-040 §5.4);
  Task → Subtask **is** declared cascade (a subtree is meaningless without its parent) — archiving
  a parent task archives its subtree at the same instant, restore matches the instant.
- **Automation interplay:** archiving a Task is an `updated` event (`changed: [archived_at]`,
  ADR-040 §5.7 / ADR-039 §4.1) — automations never act on archived tasks by construction.
- **Audit:** governed Task actions emit to the **hash-chain governance tier** like any resource
  (token/id-only, unchanged). E7 `versioned` is **declined** (§2). The four audit tiers stay
  disjoint.

### 3.6 Automation eligibility (ADR-039)

Task is a **first-class automation subject**: as a catalog-listed, org-scoped resource it is a
valid `resource_event` trigger target (`created | updated | destroyed`) through the blueprint-level
`Samen.Automation.EventCapture` after-action hook (ADR-039 §4.2) — the non-PII envelope carries
`{org_id, resource_key: "work.task", event, record_id, changed: [names]}` only. `due_at` makes
Task a natural **Reminder/Escalation** client (ADR-039 §6/§7 — "task overdue → escalate"), and
`assign_owner`/`mutate_record` actions (ADR-039 §5.2) target `owner_id`/`status`. **No new
Task-specific worker or ADR-039 contract change** — Task rides the existing seams.

---

## 4 · Design decisions (with rejected alternatives)

### 4.1 CRM linkage is a generic object-ref, not CRM FKs (the partition enabler)

Activity carried three `belongs_to` CRM FKs (`company`, `person`, `opportunity`). The canonical
Task instead carries a **generic primary subject anchor** `(subject_key, subject_id)` — the
`Samen.Web.ObjectRef` scheme `samen:<catalog-key>:<uuid>`. The Work scope therefore knows nothing
about the CRM; the CRM writes its own catalog keys (`"crm.person"`, …) into the anchor.
**This is what makes T43 buildable with zero CRM contact** (§7). Multi-anchor Activities are
preserved without loss (§5.1). *Rejected:* replicating the three CRM FKs on Task — it would
couple the Work scope to the CRM, break the partition, and re-couple every future vertical's
tasks to the CRM's schema.

### 4.2 `subject` anchor + `custom.crm_refs`, not a join table

A single primary anchor is the clean F1 shape (a task is *about* one primary thing — mirrors
ADR-012's `context_ref`). The rare multi-anchored Activity is preserved by writing the **full**
original ref set into `custom["crm_refs"]` (§5.1), and the CRM timeline read OR-matches it so
**no timeline entry disappears** (§6.1). *Rejected:* a polymorphic taggings/join resource for
task↔object — more schema and a new query surface for a preservation case the `custom` bag
already covers losslessly.

### 4.3 `status` is a plain enum, not `ash_state_machine`

Consuming ADR-037 §5.8 (ADOPT *targeted: new state-bearing resources only* — the designated
uses are Approval / automation-Run / Escalation, resources whose **core value is refusing an
illegal transition**), the canonical Task **declines** the state machine:

1. Task absorbs heterogeneous kinds — a logged `:call`/`:note` is created **already in a
   terminal state** (`:completed`); a mandatory-initial-state machine would make such a create
   look illegal.
2. **The bulk migration inserts rows in arbitrary terminal states** (`:completed`,
   `:cancelled`). A state machine requires rows to arrive through transitions, not direct
   set — an `INSERT … SELECT` cannot satisfy that cleanly. A plain enum lets the migration set
   the final status directly and losslessly (§5).
3. Task's value is the noun + subject placement + due/priority/owner, not a guarded lifecycle;
   `status` is a sortable/filterable attribute.
4. **Reversible:** a post-1.0 ADR may promote Task status to a state machine if a stricter
   lifecycle is demanded — symmetric with ADR-037 §5.8's explicit "existing status-bearing
   resources are NOT retrofitted this run" posture.

The status enum is Activity's exact set **plus** `:in_progress`, so Activity rows copy verbatim
and the CRM timeline's status handling needs no change.

---

## 5 · Data-migration semantics (T97)

### 5.1 Activity → Task field mapping (no silent drops)

The set-based copy (`INSERT INTO <task> (…) SELECT … FROM <activity>`), per host:

| Activity column | → Task column | Transform |
|---|---|---|
| `<act>_id` | `<task>_id` | **verbatim** (id preserved — idempotent re-copy, stable references) |
| `<act>_org_id` | `<task>_org_id` | **verbatim** (org scoping preserved — INV-2) |
| `<act>_type` | `<task>_kind` | verbatim (`:call/:email/:meeting/:note/:task`) |
| `<act>_subject` | `<task>_title` | verbatim |
| `<act>_body` | `<task>_body` | verbatim |
| `<act>_status` | `<task>_status` | verbatim (`:pending/:completed/:cancelled` — all in the Task enum) |
| `<act>_due_at` | `<task>_due_at` | verbatim |
| `<act>_completed_at` | `<task>_completed_at` | verbatim (preserves timeline "at") |
| `<act>_custom` | `<task>_custom` | verbatim, **then** merge `crm_refs` (below) |
| `<act>_company_id` / `_person_id` / `_opportunity_id` | `<task>_subject_key` + `<task>_subject_id` (**primary, by precedence** `opportunity ▸ person ▸ company`) **and** `custom["crm_refs"] = {company_id, person_id, opportunity_id}` (**full set, non-null only**) | precedence for the primary anchor; **the complete ref set is preserved in `custom` — zero FK data dropped** |
| `<act>_inserted_at` | `<task>_inserted_at` | **verbatim** (timeline order) |
| `<act>_updated_at` | `<task>_updated_at` | verbatim |
| `<act>_archived_at` (after T37c) | `<task>_archived_at` | verbatim (trash state preserved) |
| — | `<task>_priority` | **set `:normal`** (rank 20) — added field; documented default (§5.2) |
| — | `<task>_owner_id` | **set NULL** — Activity had no user FK; author string survives in `custom["author"]` (§5.2) |
| — | `<task>_parent_id`, `<task>_project_id` | **set NULL** — activities are flat, not project-scoped |

### 5.2 Intentionally dropped — explicit disposition

**Nothing is dropped.** Every Activity column maps to a Task column or is preserved inside
`custom`. The Task columns with no Activity source (`priority`, `owner_id`, `parent_id`,
`project_id`) receive **documented defaults**, which is an *addition*, not a drop:

- `priority := :normal` — Activity had no priority; `:normal` is the neutral rank.
- `owner_id := NULL` — Activity's "author" was a display string in `custom["author"]`, never a
  user FK; it is **retained verbatim** in `custom`, so the timeline `who` still renders. A later
  backfill may reconcile author strings to `owner_id`; that is out of scope and lossless-safe.
- `parent_id / project_id := NULL` — no Activity equivalent.

T97 done-criterion 1 (zero rows dropped silently) is met by a **row-count equality** assert
(`count(activity) == count(task WHERE migrated)`) plus **per-field equality** asserts on the
verbatim columns.

### 5.3 Per-host table inventory (abbrev placeholders)

Physical names differ per host mount (`AbbrevStorage`). Source abbrevs are **existing registry
facts**; destination abbrevs are **minted in T43** (shown as placeholders — not pre-allocated).

| Host (mount) | Source table (drop) | Destination table (T43-created) |
|---|---|---|
| demo (`Demo.CrmScope.Activity`) | `act_activity` | `<demo.task>_task` (+ `<demo.project>_project`) |
| driftwood (`Driftwood.Crm.Activity`) | `fac_activity` | `<dw.task>_task` (+ `<dw.project>_project`) |
| pawchart (`PawChart.Crm.Activity`) | `vce_activity` | `<pc.task>_task` (+ `<pc.project>_project`) |
| samen_web test host (`Samen.WebTest.Crm.Activity`) | `swa_activity` | `<wt.task>_task` (+ `<wt.project>_project`) |

**Untouched:** `cea_activity` (`Core.Ctx.Activity` — the kernel fixture, §1.1). Any diff to it
is a partition violation.

### 5.4 Exact migration sequence (per host — contract phase)

One migration per host, **contract phase** (net-destructive: drops a table with no deprecation
window — samen's PITR-covered category, not `down/0`-round-trip-tested; `samen.verify.migrations`
round-trips only `:expand` migrations and does not require a reversible `down/0` here — the
ADR-036 §4.3 precedent). The destination `<task>`/`<project>` tables already exist (created by
**T43's** `add_work_scope` migration, which orders **before** this one):

1. `INSERT INTO <task> (id, org_id, kind, title, body, status, priority, due_at, completed_at,
   subject_key, subject_id, custom, owner_id, parent_id, project_id, inserted_at, updated_at
   [, archived_at]) SELECT …§5.1… FROM <activity> ON CONFLICT (id) DO NOTHING;`
   — set-based, id-preserving, **idempotent** (§5.5).
2. `DROP TABLE <activity>;` — **same migration**, no deprecation window.
3. **Catalog reconciliation** (done at the code level in the same change set): removing
   `define_activity` from the CRM blueprint (§7.2) drops the `<act>_*` `fld_field` rows;
   Task's rows were added by T43. `catalog_parity` (name-only) stays clean.

### 5.5 Idempotency + failure posture

- **Atomic:** an Ecto migration runs in one transaction. A mid-run failure **rolls the whole
  migration back** — `<activity>` intact, `<task>` has no partial rows. No half-migrated state
  is representable.
- **Idempotent copy:** the `INSERT … ON CONFLICT (id) DO NOTHING` + id-preservation makes the
  copy re-runnable without duplication (belt-and-suspenders; Ecto's `schema_migrations` already
  guarantees single execution per DB).
- **Vault / re-tokenization:** **none required** — Activity carries no vaulted field (§3.3).
  (Had it carried a `pii_*` column, the copy would move the ciphertext + the `vt_*` token
  verbatim within the same org subject, never re-encrypting — but that path is unexercised
  here.)

### 5.6 Abbrev-registry ruling (binding — no hand-edit)

Dropping the `<activity>` tables orphans the existing registry rows `act` / `swa` / `fac` /
`vce` (mapping to now-removed modules). **Ruling: T97 does NOT touch `priv/abbrev_registry.json`.**

- Abbrevs are **never recycled** (ADR-023); the registry is **allocation-only** through
  `mix samen.abbrev.reserve` — there is no sanctioned "release" path, and hand-editing is
  forbidden by CLAUDE.md ("Abbrev registry — HANDS-OFF"; the SHA-256 byte-exact gates).
- An orphaned row is **inert**: no verifier asserts registry-row liveness (the abbrev suite
  checks conflict/format/byte-stability and read-only usage — `abbrev_property_test.exs`,
  `abbrev_registry_red_path_test.exs`, `abbrev_flatten_conflict_test.exs` — none maps rows to
  live modules). The orphaned Activity rows are **retained as retired reservations**.
- The **new** Task/Project abbrevs are minted in **T43** via the allocator (the one sanctioned
  writer). **If** a verifier is later found to assert row-liveness, T97 escalates rather than
  hand-editing the registry.

---

## 6 · CDC / timeline / catalog rewiring (T97)

### 6.1 CRM timeline surfaces move Activity → Task

The CRM detail timeline is the primary consumer. **The presentational component
`Samen.UI.Object.timeline/1` (`samen_web/lib/samen/ui/object.ex`) is UNCHANGED** — it consumes
generic entry maps keyed `{id, type, subject, body, status, at, who}` (note: the entry key is
`:type`, read by `timeline_type/1` at `object.ex:206` — **not** `:kind`; the Task *attribute* is
`kind`, and the mapping layer projects it onto the entry's `:type` key so the component needs no
change). Only the **query + mapping layer** changes:

- `samen_web/lib/samen/web/crm/reads.ex` — `activities_for_person/3`, `activities_for_company/3`
  repoint from `Mount.resource(mount, Activity)` to the Work `Task` resource, filtering by the
  object-ref anchor **OR the preserved `custom.crm_refs`** so multi-anchored history is exact:
  `subject_key == "crm.person" and subject_id == ^person_id` **OR**
  `custom["crm_refs"]["person_id"] == ^person_id` (company analog). Sort stays
  `inserted_at: :desc`; the read still `ensure_selected`s the timeline fields (now Task's).
- `create_activity/3` becomes a Task create: `kind`, `title`, `body`, `status`, `custom` (author),
  and the `(subject_key, subject_id)` anchor for the CRM entity.
- `contact_live.ex` / `company_live.ex` — `timeline_entries/1` (`contact_live.ex:493-505`)
  projects the Task onto the **existing entry keys**: `task.kind → :type`, `task.title →
  :subject`, `task.body → :body`, `task.status → :status`, `task.completed_at || task.inserted_at
  → :at`, `task.custom["author"] → :who`, `task.id → :id`. Same output shape; component untouched.

**Cross-org protection — precise mechanism (binding for T97).** Activity enforced same-org via
`{SameOrgFk, relationships: [company, person, opportunity]}`, a validation over `belongs_to`
FKs. The canonical Task's subject is a generic `(subject_key, subject_id)` pointer, **not** a
`belongs_to` — so `SameOrgFk` **cannot** target it without extension, and a `create_activity/3`-only
guard would be bypassable (a caller reaching the Work `Task` create directly would skip it, with a
different error). The invariant is therefore **not** re-implemented as a SameOrgFk-shaped check.
Instead it is enforced by the **org-scoped `Samen.Web.ObjectRef` resolve at the write boundary**:
`create_activity/3` resolves the subject ref through `Samen.Web.ObjectRef.resolve/3`, whose
private `load_scoped/3` (`samen_web/lib/samen/web/object_ref.ex:160-177`) reads the referenced row
**with the viewer's scope** — `OrgScope` narrows to `scope.actor.org_id`, so a cross-org id returns
`[]` → `{:error, :not_found}` (a raise maps to `:forbidden`; never a leak). A cross-org reference
is thus **inert by construction** — org-A cannot resolve, and so cannot anchor a task to, org-B's
person. The **security outcome is preserved** (cross-org reference rejected/inert); the **error
shape differs** from today's `SameOrgFk` failure (`:not_found`/`:forbidden` at resolve, not a
SameOrgFk validation error). §6.4 item 3 bounds the corresponding red-path test update
(re-assert on the new shape without weakening; positive + negative controls retained).

### 6.2 CDC consumers

CDC is globally opt-in/default-off and had **no Activity-specific config**; the default-deny
classifier (ADR-015) reflects over registered resources. Post-migration:

- Task's columns fall under the **same default-deny rule**: `kind`/`status`/`priority`(rank
  int)/`due_at`/`completed_at`/`subject_key`(bounded catalog key)/uuids/timestamps are
  structural-safe and mirror-eligible; **`title`/`body`/`custom` are refused as
  `:plaintext_pii`** unless a two-reviewer `non_pii!` clearance is added (none is) — identical
  to how Activity's `subject`/`body`/`custom` would have been treated. **No CDC consumer breaks**
  because none was Activity-specific.
- If the `no_plaintext_pii` projection roster (ADR-040 §6.2) names `crm.activity`, T97 removes
  that entry; `work.task` follows the same freeform-refused default (verified, not asserted-by-hand).

### 6.3 Catalog + search registry

- **Catalog:** removing `define_activity` from the CRM blueprint drops Activity from the catalog;
  Task/Project are added by T43. T97 verifies `crm.activity` is **absent** from the catalog dump
  and no `Activity` module reference remains outside CHANGELOG/docs (T97 c2).
- **Search:** search indexes are per-org runtime registrations gated by `SearchIndexGuard`;
  there is no static Activity search entry to migrate. A tenant that had indexed an Activity
  field re-registers against Task post-migration (operational, not a code change).

### 6.4 Allowed test-change surface (bounded — this is a destructive migration)

A destructive migration legitimately changes behavior; T97 **may** change **only** these tests,
**only** in these ways:

1. `samen_web/test/samen/web/crm_detail_render_test.exs` — swap the seeded/asserted resource
   from Activity to Task; **the timeline-renders + composer assertions stay** (behavior
   preserved), only the underlying resource name changes.
2. `crm_contact_detail_crud_test.exs` / `crm_company_detail_crud_test.exs` — the composer now
   writes a Task; row-count asserts target Task; **the OrgScope + inline-error red paths stay**.
3. `demo/test/crm_scope_policy_matrix_test.exs` — the cross-org-invisible and cross-org-FK red
   paths move to the Task/anchor write path (§6.1). The old assertion expected a **`SameOrgFk`
   validation error**; the migrated path rejects the cross-org reference via the org-scoped
   `ObjectRef` resolve, so T97 **updates the red-path assertion to the new error shape**
   (`{:error, :not_found}` / `:forbidden`, or the create refusing to anchor — the resolve is
   inert cross-org). This is an **allowed** change; it must **NOT weaken** the red path: a
   cross-org reference must still be rejected/inert, and the assertion must still pair with its
   positive control (same-org attach succeeds — anti-tautology). **Forbidden:** dropping the
   negative assertion, or asserting success where the old test asserted refusal.
4. `samen_web/test/support/seeds.ex` — seed Tasks instead of Activities.
5. **New:** a migration test (`…_activity_migration_test.exs`) — row-count + field-equality +
   zero-drop (T97 c1).

**Forbidden** (any of these in T97's diff is a review failure): weakening a masking test,
deleting a red-path positive control, relaxing an org-scope assertion, or **any diff to
`Core.Ctx.Activity` / `context_fixture.ex` / `context_test.exs` / `context_red_path_test.exs` /
`cdc_default_deny_projection_test.exs`** (§1.1). Deleting a test is allowed **only** for an
assertion that `crm.activity` *exists as a resource* — which becomes an assertion that it does
*not* (and that `work.task` does).

---

## 7 · The T43 / T97 file-touch partition (BINDING — reviewer-enforced)

The partition is checkable with `git diff --name-only`. **T43 creates the destination and must
show ZERO diff under the CRM globs; T97 owns every CRM touch and the migration.** Each side stays
within (or is flagged against) the ~10-file convention.

### 7.1 T43 — build the Work scope (**NO CRM contact**)

Allowed paths (create/extend only):

- `samen_core/lib/samen/scopes/work.ex` — mount macro (new)
- `samen_core/lib/samen/scopes/work/blueprint.ex` — `Project` + `Task` define macros (new)
- `samen_core/lib/samen/scopes/work/*.ex` — scope helpers if needed (new)
- `samen_web/lib/samen/web/work/**` — Work LiveViews (task list/detail, project) (new)
- `samen_web/lib/samen/web/work/routes.ex` — `samen_work_routes` macro (new)
- gen support: `samen_core/lib/mix/tasks/samen.gen.scope.ex` (+ `samen.gen.app.ex` if the flagship
  mounts Work) + any new `samen_core/priv/templates/*work*` template
- host mounts (create the destination, ≈0 LOC + generated create-tables migration):
  `demo/lib/demo/*work*` + `demo/lib/demo_web/router.ex` (add `samen_work_routes`) +
  `demo/priv/repo/migrations/<ts>_add_work_scope.exs`; the driftwood, pawchart, and
  samen_web-test-host analogs
- abbrev: **allocator run** (`mix samen.abbrev.reserve`) — writes the registry via the sanctioned
  path (the new Work abbrevs); **not** a hand-edit
- tests: `samen_core/test/work_scope_test.exs`, the INV-1 no-PII declaration test, the catalog +
  cycle-refusal + archive/restore tests; `samen_web/test/samen/web/work_*`; a host mount test;
  the gen_app probe extension
- `docs/adr/README.md` shares the index row with this ADR; `CHANGELOG.md` "Added: Work scope"
- **golden:** if mounting Work shifts gen output, T43 regenerates `templates_golden` fixtures in
  the same task (the no-deferral convention, §8)

**T43 FORBIDDEN (reviewer check — `git diff --name-only` must be empty here):**
`**/scopes/crm/**`, `**/web/crm/**`, `*activity*`, and every T97-owned migration/rewire below.

### 7.2 T97 — migrate + rewire + remove Activity

Allowed paths (the CRM touches live here):

- `samen_core/lib/samen/scopes/crm/blueprint.ex` — **remove `define_activity/8`** (`:320–411`)
- `samen_core/lib/samen/scopes/crm.ex` — remove Activity from `@default_abbrevs` (`:65–72`),
  `resolve_abbrevs`, the `Module.concat` list (`:143–152`), the `resources do resource(...) end`
  registration (`:98–105`), and the `Blueprint.define_activity` call
- `samen_web/lib/samen/web/crm/reads.ex` — repoint `activities_for_person/3` (`:175–185`),
  `activities_for_company/3` (`:187–197`), `create_activity/3` (`:232–236`) to Task (§6.1)
- `samen_web/lib/samen/web/crm/contact_live.ex` (`:336–345`, `:493–508`) +
  `company_live.ex` (`:297`, `:458–472`) — Task-backed `timeline_entries/1`
- per-host **data-copy + drop** migrations (new, one each):
  `demo/priv/repo/migrations/<ts>_migrate_activity_to_task.exs` (`act_activity` → Task, drop),
  the driftwood (`fac_activity`), pawchart (`vce_activity`), and samen_web (`swa_activity`) analogs
- seeds: `samen_web/test/support/seeds.ex` (+ any host seed that seeds activities)
- the bounded test changes in §6.4 + the new migration test
- `CHANGELOG.md` — the **breaking-change** entry (mandatory, M6 precedent)

Each side is ~8–12 files; both stay within the convention (T97's spread across four hosts is the
migration's irreducible fan-out, justified by the single destructive change — its gate is full
`./ci.sh`, per T97 c4).

### 7.3 The partition rule

> **A file is touched by exactly one of {T43, T97}.** T43 owns everything under
> `scopes/work/**`, `web/work/**`, the Work host mounts, and the Work gen/golden. T97 owns
> everything under `scopes/crm/**`, `web/crm/**`, the `migrate_activity_to_task` migrations, the
> CRM seeds, and the bounded CRM test changes. The `add_work_scope` migrations are **T43** (create
> the destination); the `migrate_activity_to_task` migrations are **T97** (move + drop) and order
> strictly *after* them.

**One documented exception:** `CHANGELOG.md` is appended by **both** tasks (T43 the "Added: Work
scope" line, T97 the breaking-change removal line) — an append-only shared ledger, not a partition
violation. Every *other* path is single-owner.

**Reviewer check:** `git diff --name-only <base>..T43` matches none of
`{scopes/crm, web/crm, *activity*, *migrate_activity*}`; `git diff --name-only <base>..T97`
matches none of `{scopes/work, web/work, *add_work_scope*}`. `priv/abbrev_registry.json` changes
in **T43 only** (allocator), **never** in T97.

### 7.4 Tripwire

Any diff in **either** task to `Core.Ctx.Activity`, `samen_core/test/support/context_fixture.ex`,
`context_test.exs`, `context_red_path_test.exs`, or `cdc_default_deny_projection_test.exs` is a
**partition violation** — that is the kernel context fixture, not the CRM Activity (§1.1).

### 7.5 Abbrev discipline

This ADR uses `<abbrev>_` placeholders throughout and **pre-allocates no registry rows**.
Allocation happens in T43 through `mix samen.abbrev.reserve` (ADR-023). T97 leaves the registry
untouched (§5.6).

---

## 8 · No-deferral host-migration convention + rollback/abort posture

### 8.1 No-deferral convention (binding for T97)

T97 ships **all four host mirror migrations in the same task** — demo, driftwood, pawchart, and
the samen_web test host — none deferred. The gate is a **clean drop/create from zero**:
`mix ecto.drop && mix ecto.create && mix ecto.migrate && <seed> ` on each host, then that host's
suite, then **`./ci.sh` ends `ROOT CI: ALL PASSED`** (T97 c4) — the full cross-app gate is
justified because the change ripples across every mounting host. Every app compiles
`--warnings-as-errors` (CLAUDE.md).

**Generators stay zero-hand-edit.** Because generated apps mount the CRM via the blueprint macro
(not by hand-emitting Activity — confirmed: no `activity` string in `priv/templates/` or
`templates_golden/`), **removing `define_activity` propagates to every generated app
automatically**. T97's generator duty is therefore to **verify**: the gen_app probe compiles and
its suite passes with Activity gone, and any `templates_golden` fixture that shifts is regenerated
in the same task. The **addition** side (mounting the Work scope into generated apps + its golden
regeneration) is **T43's** duty (T43 c4) — the partition splits the gen work exactly as it splits
everything else.

### 8.2 Rollback / abort posture

- **Mid-migration failure on a host:** the migration is one transaction — it rolls back whole.
  The host returns to its pre-migration state (`<activity>` intact, no `<task>` rows written);
  re-run after the fix. **No half-migrated state is representable** — this is the recovery story.
- **The clean drop/create verification IS the gate:** the destructive chain (T43 `add_work_scope`
  → T97 `migrate_activity_to_task`) must compose green from an empty database on every host
  *before merge*. A migration that cannot rebuild from zero fails T97's gate — it never reaches a
  real database in a broken state.
- **Production control:** contract-phase migrations are **PITR-covered**, not `down/0`-tested
  (samen's migration-safety posture — the ADR-036 §4.3 precedent). This is pre-1.0 with a public
  repo but no production data of consequence; PITR (Neon branch-and-restore) is the last resort,
  with detection-latency RPO for a bad contract per the foundry's stated posture.
- **Documented reversal recipe** (for operators; not a down-tested `down/0`): recreate
  `<abbrev>_activity` from its append-only creating migration's DDL, then
  `INSERT INTO <activity> (…) SELECT id, org_id, kind→type, title→subject, body,
  status→{pending|completed|cancelled}, due_at, completed_at, custom (minus crm_refs),
  crm_refs→{company_id,person_id,opportunity_id}, inserted_at, updated_at FROM <task>
  WHERE <migrated marker>`, then drop the migrated Tasks. The forward map is a bijection over the
  migrated rows (only `priority`/`owner_id`/`parent_id`/`project_id` are added-with-defaults and
  are discarded on reverse; `:in_progress` has no Activity source and cannot appear among migrated
  rows), so the recipe is exact for the data it must reverse.

---

## 9 · Plane placement (INV-2)

Work Project + Task are **tenant-plane, org-scoped** resources — exactly Activity's placement.
Tenant members create/read/update within their org; there is no operator-plane special case
(unlike reveal grants). The operator plane sees tenant tasks only through existing
operator-read/impersonation surfaces; since Task has no PII, there is nothing to mask (the
masking seam still applies by construction, it just resolves nothing).

---

## 10 · PII posture summary (INV-1)

| Attribute | Classification | Vault? | Mechanism |
|---|---|---|---|
| `kind`, `status`, `subject_key` | non-PII (bounded atom/key) | no | structural |
| `priority` | non-PII | no | `Samen.Type.Priority` `:non_pii` + `TypeClearance` (ADR-036) |
| `due_at`, `completed_at`, timestamps, `id`, `org_id`, `subject_id`, `owner_id`, `parent_id`, `project_id` | non-PII (id/timestamp) | no | structural |
| `title`, `body`, `custom` | freeform user content | no | **default-deny CDC** (ADR-015) — refused from mirroring, not vaulted (Activity parity) |

The scope's catalog PII map is **empty** (T43 c3 asserts it). No masking tier is added, removed,
or weakened by this ADR (INV-1 preserved).

---

## 11 · Verifier + sabotage duties (INV-3 — owed by T43 / T97)

- **T43:** cycle-refusal red test (legal tree accepted / cycle refused — positive control);
  archive→hidden→restore→visible + the relationship/aggregate leak red test (ADR-040 §5.5, §10);
  the INV-1 empty-PII-map assert; catalog registration probe; the gen_app ≈0-LOC mount probe.
- **T97:** the migration proof (row-count + per-field equality + zero-drop, §5.2); the
  Activity-gone probes (no `activities` table; no `Activity` module ref outside CHANGELOG/docs;
  catalog dump lacks `crm.activity`); the timeline-renders-migrated-Tasks test; the cross-org
  red path at its new enforcement point (§6.1); `./ci.sh` green before *and* after.
- **Sabotage duty (house rule):** a patch that flips the timeline read back to Activity (or drops
  the `custom.crm_refs` OR-match) must make the named timeline test FAIL and revert byte-exact —
  proving the rewire assertion is refutable.

---

## 12 · Rejected alternatives

1. **Alias, not migrate (M5 default (b)):** rejected by the operator OVERRIDE — one canonical
   Task, Activity removed.
2. **Replicate CRM FKs on Task:** rejected (§4.1) — couples the Work scope to the CRM and breaks
   the T43/T97 partition.
3. **`ash_state_machine` for Task status:** rejected (§4.3) — the migration inserts terminal-state
   rows directly; Task absorbs already-terminal logged kinds; ADR-037 §5.8 scopes adoption to
   transition-guarding resources.
4. **A polymorphic task↔object join resource:** rejected (§4.2) — the `custom.crm_refs` bag
   preserves the multi-anchor case losslessly without new schema.
5. **Hand-remove the orphaned Activity abbrev rows:** rejected (§5.6) — violates CLAUDE.md
   HANDS-OFF and the SHA-256 gates; orphaned rows are inert.
6. **Defer some host migrations to a follow-up:** rejected (§8.1) — a partial destructive
   migration leaves hosts on divergent schemas; the no-deferral convention ships all four.

---

## 13 · Consequences

1. One canonical Work Task replaces CRM Activity; every vertical inherits Project + Task +
   Subtask at ≈0 authored LOC (INV-5).
2. The CRM timeline is now a **client** of the Work scope through the generic object-ref — the
   same pattern F3 Docs will reuse ("attachable to any object").
3. Task is automation-ready (ADR-039), soft-deletable (ADR-040), and search-registerable with
   no new mechanism — leverage, not new surface.
4. The change is destructive and pre-1.0-breaking; CHANGELOG entry mandatory; PITR is the
   production control for the contract phase.
5. The T43/T97 partition keeps each task inside the convention and makes the highest-risk change
   of Phase 3 mechanically reviewable.

## 14 · References

- Operator ruling **M5** — `_orch/plan/spec-questions.md`
- Spec §F1, §F8 — `spec/full-saas-readiness.md`
- ADR-036 (types + the §4 destructive-migration template), ADR-037 (§5.3/§5.4/§5.8/§5.9),
  ADR-039 (§4.1/§4.2/§5.2/§6/§7), ADR-040 (§5.9 roster, §5 soft-delete, §6 audit), ADR-015
  (default-deny CDC), ADR-011/ADR-012 (CRM timeline + `Samen.Web.ObjectRef`)
- CRM Activity blueprint — `samen_core/lib/samen/scopes/crm/blueprint.ex:320`; mount —
  `samen_core/lib/samen/scopes/crm.ex`; reads — `samen_web/lib/samen/web/crm/reads.ex`
