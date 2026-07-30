# ADR-040 — Lifecycle substrate: the WS-E E3/E6/E7 contracts

- **Status:** Accepted.
- **Date:** 2026-07-23.
- **Task:** T33 (Phase-3 lifecycle ADR). Downstream implementers: **T34** (E3 approvals
  engine), **T35** (reveal grants become its client), **T36** (E6 soft-delete core),
  **T37** (E6 blueprint-wide adoption sweep — decomposed per §5.9 here), **T38** (E7
  audit-on-write + ContentVersion client). **T96** (canonical-Task ADR) allocates its ADR
  number after this one and consumes the §5 soft-delete conventions.
- **Consumes:** ADR-037 §5.3 (**ash_archival ADOPT** — preparation variant + explicit
  unarchive + partial identities fixed there, mode confirmed here), §5.4 (**ash_paper_trail
  ADOPT** — `:changes_only` default chosen here per its C2 note), §5.5 (**ash_events
  REJECT** — no plaintext-inputs event store, no deferred-parameterized execution), §5.8
  (**AshStateMachine ADOPT, targeted** — the E3 `Approval` lifecycle is its designated new
  state-bearing resource for this ADR), §5.9 (**ash_oban ADOPT** — the approval-expiry
  scan). Rulings: spec-questions **c6** (`archived_at`, utc_datetime_usec, NULL = live),
  **c12** (requester≠approver by DB CHECK mirroring the reveal-grant precedent, plus policy
  check). Spec: §E3, §E6, §E7; INV-1/INV-2/INV-3/INV-5. Coheres with ADR-039 (§7 here).
- **Precedents built on:** `Samen.Reveal.{Grants,RevealRequest,RevealGrant,RevealAudit}` +
  the `rvg_distinct_party` CHECK (`samen_core/priv/test_repo/migrations/20260705050100_reveal_grants.exs`)
  and its two-layer enforcement tests; `Samen.Retention.{Spec,SweepWorker}` (fail-closed
  per-resource retention, `:shred | :delete`); `Samen.Erasure.shred/2` + `Samen.Kms.shred/1`
  (key-destruction-first crypto-shred); `Samen.AuditChain.Writer` (governance events,
  token-only, PiiReasonScan); the CMS `define_content_version` macro (the E7 client being
  migrated); `Samen.Resource` (`samen do` section, CoreAttributes, catalog/abbrev duties);
  `Samen.Notifications.Engine` (host-wired module/repo seams, fail-closed
  `{:error, :no_*_module}`); ADR-036/M6 (pre-1.0 destructive break precedent);
  object-ref convention (`"samen:scope.resource:<id>"`).

---

## 1 · Context

Three lifecycle capabilities are substrate-wide by nature — every blueprint resource, every
generated app: **E3** a generalized approve/reject engine (today only reveal grants have a
two-party decision, hand-built), **E6** soft-delete/archive/restore (today every destroy is
terminal; only crypto-shred and retention exist), **E7** per-resource audit-on-write (today
only CMS has a bespoke, half-wired ContentVersion). The operator's decompose-cross-cutting
rule applies: this ADR fixes the contracts and the adoption conventions; T34–T38 implement
in phases, and the T37 sweep is decomposable per scope precisely because the logic lands in
the blueprint macro, not in 60 hand-edits.

The PII stakes are specific. Approvals tempt you to persist "the action to run later" —
action inputs at write time are pre-vault plaintext, the exact reason ash_events was
rejected. Audit-on-write tempts you to snapshot rows — which is safe in samen *only*
because the vault type's dump face emits tokens, and that fact must be red-tested, not
assumed. Soft-delete tempts you to believe a hidden row is a deleted row — archived rows
still hold vaulted tokens, still count for erasure, and still occupy unique slots. This ADR
fixes all three postures.

## 2 · ADR-037 verdicts consumed (binding)

| Verdict | What this ADR does with it |
|---|---|
| §5.3 ash_archival **ADOPT** | E6 is implemented ON ash_archival, **preparation variant** (not `base_filter` — restore is a hard requirement) + explicit unarchive actions + partial unique indexes. Delivered as a `Samen.Resource` option (§5.2), not per-resource hand-wiring. The documented leak surface (relationship loads/aggregates bypassing read preparations) becomes a standing red-test duty (§5.8, §10). |
| §5.4 ash_paper_trail **ADOPT** | E7 is a per-blueprint opt-in on ash_paper_trail. Default `change_tracking_mode` is **`:changes_only`** (atomic-safe; smallest stored surface); a per-resource **`:snapshot`** override exists for resources needing rollback semantics (CMS content, §6.5). `:full_diff` is refused substrate-wide (`require_atomic? false` — not acceptable). `store_action_inputs?` is **false forever** (§6.3). |
| §5.5 ash_events **REJECT** | Honored twice: no event store, and — the same reasoning applied to E3 — the approvals engine **never persists action inputs**; approved work is re-derived from governed domain state (§4.4). |
| §5.8 AshStateMachine **ADOPT (targeted)** | The `Approval` resource is the new state-bearing resource: `pending → approved \| rejected \| expired \| cancelled`, illegal transitions refused by the machine — the double-decide guard is the exactly-once mechanism (§4.3). No retrofit of reveal tables. |
| §5.9 ash_oban **ADOPT** | The approval-expiry scan is an AshOban trigger with **explicit `scheduler_cron`**, queue `:automation_timers` (shared with ADR-039 §6.3/§7.3), ID-only job args (the §5.9 sink rule). |

## 3 · Architecture overview

Three capabilities, three delivery vehicles, all INV-5 substrate-first:

1. **E3** — one new blueprint resource, `Approval`, added to the **primitives scope**
   (`Samen.Scopes.Primitives.Blueprint.define_approval/…`; abbrev allocator-owned per
   ADR-023, never pinned here), plus a kernel public API **`Samen.Approvals`** in
   `samen_core` (host-wired module/repo seam per the `Notifications.Engine` convention;
   unwired ⇒ fail-closed `{:error, :no_approvals_module}`). Two integration faces (§4.4):
   a handler registry for kernel/non-Ash clients (reveal), and an Ash action gate built on
   it.
2. **E6** — a new **`Samen.Resource` option**: `samen do archivable true end` attaches
   ash_archival (preparation variant) with `archived_at` (c6), rewrites the default destroy
   to soft, and emits `:archive`/`:restore`/`:archived` read/`:destroy_permanently`
   actions (§5.2). Adoption is a roster-driven per-scope flip (§5.9) — leverage, not a
   100-file sweep.
3. **E7** — a new **`Samen.Resource` option**: `samen do versioned true end` (optional
   `versioned mode: :snapshot`) attaches AshPaperTrail; the generated `<Resource>.Version`
   resources receive the samen extension via `version_extensions` so abbrev/catalog/
   no-plaintext duties run on them like any table (§6.2). CMS ContentVersion is retired in
   favor of it (§6.5).

Nothing here touches the governance hash-chain (`aud_chain` stays append-only,
PII/governance-scoped), the CDC mirror, or the crypto-shred path — §7.4 states the
four-tier audit story explicitly.

## 4 · E3 — Generalized approve/reject engine (spec §E3; T34, T35)

### 4.1 The `Approval` resource

Org-scoped blueprint resource in the primitives scope; logical columns:

| Column | Notes |
|---|---|
| `org_id` | **`allow_nil? true` — a documented CoreAttributes exception** (the Identity.Org precedent). Non-NULL = tenant-plane approval, OrgScope-policed. NULL = plane-global governance approval (reveal), reachable only from operator-plane surfaces; `Samen.Policy.OrgScope`'s filter (`org_id == actor.org_id`, fail-closed) structurally hides NULL-org rows from every tenant actor — the cross-org red test covers both directions. |
| `kind` | Bounded string, **registered** (config registry, §4.4); registration fixes the plane (`:tenant \| :operator`) and the handler module. Unregistered kinds are refused at write. |
| `subject_ref` | Object-ref string (`"samen:scope.resource:<id>"`) — the governed domain record this decision concerns. The approval row carries **no other subject data**. |
| `requested_by` | Opaque actor id. |
| `decided_by` | Opaque actor id, NULL until decided. |
| `reason` | Freeform, **PiiReasonScan-gated at write** (the `AuditChain.Writer` detail precedent) — refused if PII-shaped, never vault-routed, because the approver on either plane must read it to decide (§12 records the rejected vault-routing alternative). |
| `state` | AshStateMachine: `pending → approved \| rejected \| expired \| cancelled`. All decided states are terminal. |
| `deadline_at` | Optional; pending past deadline ⇒ `expired` via the §4.6 scan. |
| `requested_at`, `decided_at` | Timestamps. |

**Pending-uniqueness:** partial unique index on `{org_id, kind, subject_ref}` `WHERE state
= 'pending'` (NULL org: `{kind, subject_ref}` via a second partial index) — re-requesting
returns the existing pending approval (idempotent request), never a duplicate.

### 4.2 Requester ≠ approver — two-layer enforcement (c12)

Mirrors the reveal-grant precedent exactly:

1. **Policy layer** — `Samen.Approvals.approve/3` refuses `decided_by == requested_by`
   with `{:error, :self_approval}` and writes a refusal audit event; the approval stays
   `pending` (the `Grants.approve/2` L180 shape).
2. **DB layer** — CHECK constraint on the approval table, named `<abbrev>_distinct_party`
   (the `rvg_distinct_party` twin):

   ```sql
   CHECK (<abbrev>_decided_by IS NULL
          OR <abbrev>_decided_by <> <abbrev>_requested_by)
   ```

   A direct insert/update with equal ids raises `Postgrex.Error` — T34's red test, with a
   distinct-party positive control (anti-tautology).

The reveal grant's own `rvg_distinct_party` CHECK **stays** — after T35 the reveal path is
enforced at three layers (engine policy, approval CHECK, grant CHECK), and no existing test
changes.

### 4.3 Decision semantics — exactly-once by state machine, atomic by Multi

`approve/3` runs **one transaction**: state transition `pending → approved` (machine-
guarded — a concurrent second approve hits `NoMatchingTransition` / a guarded `WHERE
state = 'pending'` no-op; this is the exactly-once mechanism for T34 c1), then the
registered handler's `on_approve/2` **inside the same transaction**, then the audit write.
Handler error ⇒ whole transaction rolls back, approval stays `pending`, error surfaced —
this is what preserves the reveal same-tx guarantee (a grant CHECK violation must roll back
grant, audit, and auto-revoke job together, per `reveal_grant_same_tx_test.exs`).
`reject/3` is symmetric with `on_reject/2` (a no-op default). Decisions emit governance
audit events through `Samen.AuditChain.Writer` (`approval_requested | approval_approved |
approval_rejected | approval_expired | approval_cancelled | approval_self_decide_refused`)
— token/id-only detail, `reason` never enters chain detail.

### 4.4 Two integration faces — and the no-persisted-inputs rule (binding)

**The engine never stores action inputs.** A client that needs work performed on approval
persists its *intent as governed domain state first* (vault-routed where PII), and the
handler re-derives everything from that record at decision time. This is the ash_events
rejection applied to E3: an approval row is `{kind, subject_ref, parties, reason, state}` —
nothing else.

**Face 1 — handler registry** (kernel/non-Ash clients; T34):

```elixir
defmodule Samen.Approvals.Handler do
  # Runs INSIDE the decision transaction (§4.3). ctx: %{approval, actor, repo, opts}.
  @callback on_approve(approval :: struct(), ctx :: map()) ::
              {:ok, meta :: map()} | {:error, term()}
  @callback on_reject(approval :: struct(), ctx :: map()) :: :ok | {:error, term()}
  @optional_callbacks on_reject: 2
end
```

Registry: config-resolved `kind => {plane, handler_module}` (the automation action-registry
shape). `Samen.Approvals` public API (host-wired seam; binding signatures):

```elixir
Samen.Approvals.request(attrs, opts \\ [])
  :: {:ok, approval} | {:error, term()}
# attrs: %{org_id: id | nil, kind: String.t(), subject_ref: String.t(),
#          requested_by: id, reason: String.t() | nil, deadline_at: DateTime.t() | nil}
Samen.Approvals.approve(approval_id, decided_by, opts \\ [])
  :: {:ok, approval, meta} | {:error, :self_approval | :not_pending | term()}
Samen.Approvals.reject(approval_id, decided_by, opts \\ [])
  :: {:ok, approval} | {:error, :self_approval | :not_pending | term()}
Samen.Approvals.cancel(approval_id, actor, opts \\ [])       # requester withdraws
  :: {:ok, approval} | {:error, term()}
```

**Face 2 — the Ash action gate** (`"any action can require approval"`; T34): a blueprint
action opts in via `change {Samen.Approvals.Gate, kind: "..."}`. Gateable actions are
**bounded transitions on an existing record** — no arguments beyond the record itself (a
gated action declaring arguments is refused at compile/verifier time; freeform inputs are
exactly what must not be deferred). Invoked without an approval in context, the Gate
aborts the write, opens (or returns the existing) pending approval
(`kind: "<resource_key>:<action>"`, `subject_ref` = the record), and returns fail-honest
`{:error, {:approval_required, approval_id}}`. On approve, the generic gate handler
re-invokes the same action **as the original requester** (their intent, their permission
envelope — approval adds second-party consent, never privilege escalation) with a one-shot
approval context that satisfies the Gate. T34 proves the hook on two different gated
action types.

### 4.5 Plane placement (INV-2 — who approves what where)

The `kind` registration fixes the plane; a kind is never decidable cross-plane:

| Kind class | Requester | Approver | Approval surfaces |
|---|---|---|---|
| Tenant kinds (gated blueprint actions, future D5 AI-draft approvals, automation-opened requests) | Any org member the action's own policies admit | Org member with the approve permission (`RoleAtLeast :admin` default on the Approval resource's decide actions), `≠` requester | Tenant plane |
| Operator/governance kinds (`"pii_reveal"`) | Operator | Distinct operator | Operator plane; rows are `org_id NULL`, invisible to every tenant actor by OrgScope |

Approval list/detail surfaces render `subject_ref` as object refs — masked-render rules
apply wherever a subject preview is unfurled; the approval row itself contains no PII
(`reason` is scan-gated, ids are opaque).

### 4.6 Expiry

Optional `deadline_at`; one AshOban trigger on Approval (predicate `state == :pending and
deadline_at <= now`, **explicit `scheduler_cron`**, queue `:automation_timers`, per-record
`max_attempts 3`, ID-only args) transitions to `expired` + audit. Approval timeouts as
escalation clients (ADR-039 §7.4's anticipated future client) are a seam note — no code
owed this run.

### 4.7 Reveal-grant migration plan (T35 — behavior-preservation is the criterion)

Reveal grants become a **client**, not a rewrite. What changes and what provably does not:

1. `Samen.Reveal.Grants.request/1` additionally opens an Approval
   (`kind: "pii_reveal"`, `org_id: nil`,
   `subject_ref: "samen:reveal.request:<request_id>"`) and keeps writing the
   `RevealRequest` row + `requested` audit exactly as today (dual truth: the request row
   stays the domain intent record per §4.4).
2. `Grants.approve/2` keeps its own policy-layer distinct-party check verbatim (L180 —
   unmodified error shape, unmodified `denied` RevealAudit write), then routes the happy
   path through `Samen.Approvals.approve/3` whose registered handler
   `Samen.Reveal.ApprovalHandler.on_approve/2` executes the **existing `do_approve/4`
   Multi body** — grant insert + `granted` audit + auto-revoke job `scheduled_at:
   expires_at`, one transaction with the approval transition (§4.3). Module probe target:
   grant issuance calls the engine API.
3. **Unchanged, and every existing test must pass unmodified:** the `rvg_distinct_party`
   CHECK; grant time-boxing (`expires_at = now + window`, no renew-in-place); the
   `AutoRevokeWorker` timing and `expired` audit; deny-on-read `Grants.active?/2`;
   `revoke/2`; the erasure path's `erased` audit; all masking-watch-list tests. The grant
   lifecycle (time-boxed capability) and the approval lifecycle (consent decision) are
   different objects — the approval row records the decision; the grant row remains the
   capability.
4. **Host wiring duty:** every host mounting reveal must materialize the Approval resource
   + migration (demo/driftwood/pawchart via the updated primitives scope; samen_core's own
   TestRepo host; the gen_app golden templates gain the approval migration alongside their
   existing reveal-grant goldens). An unwired host fails closed
   (`{:error, :no_approvals_module}`) — never a silent single-party grant.

## 5 · E6 — Soft-delete core + adoption (spec §E6; T36, T37)

### 5.1 Semantics in one paragraph

`archived_at` (`utc_datetime_usec`, NULL = live — c6) is **trash, not erasure**: an
archived record keeps its vaulted tokens, keeps its org scoping and per-plane masking,
keeps counting for erasure/DSAR, and stays recoverable via `:restore` until retention
purges it. **Hard-delete + crypto-shred remain the terminal path, unchanged**: the real
destroy survives as an excluded action for the retention/erasure/governance paths only;
`Samen.Erasure.shred/2` and `Samen.Kms.shred/1` are untouched (key destruction is
storage-state-independent — shredding an archived subject works identically).

### 5.2 Delivery: the `archivable` blueprint option (T36)

`samen do archivable true end` on `use Samen.Resource` attaches, in one place:

- **ash_archival, preparation variant** (ADR-037 §5.3's fixed default — `base_filter` is
  refused as the default because it makes unarchive impossible), attribute renamed/prefixed
  to `<abbrev>_archived_at` via the ADR-037 C2(a) transformer-ordering duty; catalogued.
- **Default destroy becomes soft** (the package's soft-destroy rewrite); a separate
  **`:destroy_permanently`** action is excluded from archival
  (`exclude_destroy_actions`) — *not* exposed on tenant UI; callable only by the retention
  sweep, the erasure path, and operator governance surfaces.
- **`:archive`** (explicit, audited) and **`:restore`** (excluded read +
  `set_attribute(archived_at, nil)` + `atomic_upgrade_with`, audited) actions, plus an
  **`:archived`** read (preparation-excluded) for trash views/retention. Double-archive and
  double-restore are idempotent no-ops (T36 c4). Archive/restore carry the same policy
  posture as the destroy/update they mediate; both emit audit events (`record_archived` /
  `record_restored`, token/id-only) and, where user-visible, notifications — ash_archival
  itself notifies nobody (ADR-037's cascade caveat).
- **Search integration:** archive de-indexes the record from the search registry; restore
  re-indexes ("hidden from default reads/list/**search**" is the spec sentence). T36 wires
  the hook; T37 proves it per adopting scope.

### 5.3 Uniqueness: partial-index convention (binding)

Samen has **no Ash identities** — uniqueness lives in migration-level `unique_index`es. For
every archivable resource, unique indexes convert to **partial** form:

```sql
CREATE UNIQUE INDEX ... WHERE <abbrev>_archived_at IS NULL
```

so an archived row frees its slot. Consequence: `:restore` can collide with a live row that
claimed the slot since — restore fails honest with `{:error, :restore_conflict}` (surfaced
in UI copy; never auto-renames, never clobbers). If Ash identities ever appear, the
equivalent is `identity ..., where: expr(is_nil(archived_at))` + `identity_wheres_to_sql`.
T37's per-scope items grep the scope's migrations for `unique_index` on adopted tables and
convert each (most current unique indexes sit on *excluded* resources — tokens, provider
refs — so the sweep is small; the probe proves it either way).

### 5.4 Cascade / association semantics (binding)

- **Default: no cascade.** Archiving a record leaves associated records live; surfaces
  rendering a link to an archived parent show the archived affordance (UI copy, T37).
- **Composition cascades are declared per resource in the roster** (children meaningless
  without the parent): Ticket → Conversation → Message; chat Thread → Message; CMS
  Page → Block. Cascade uses `archive_related`, sets children's `archived_at` to the
  **same instant** as the parent, and pairs with a notification where user-visible.
- **Restore of a cascade parent restores exactly the children whose `archived_at` equals
  the parent's** (the same-instant match) — a child independently archived earlier stays
  archived. Restore conflicts on any member abort the restore transaction honestly.

### 5.5 Reads, policies, masking

The archival read preparation adds `is_nil(archived_at)` to default reads; `Samen.Web.Reads`
keyset helpers are unchanged (the filter composes under sort/cursor/limit). Policies are
orthogonal: archived rows remain OrgScope-filtered and mask-by-default on every plane
(T36 c3 masking test on a vaulted pilot). **The documented ash_archival leak surface —
relationship loads and aggregates bypass read preparations — is a standing red-test duty:**
every adopting scope ships an archived-record-must-not-appear-via-traversal red test
(ADR-037 C2), and the sabotage patch flips the default-filter preparation so the named test
fails.

### 5.6 Retention interplay (T37)

`Samen.Retention.Spec` gains no new fields — the existing `timestamp_field` seam carries
the convention: an archivable resource's purge spec points `timestamp_field: :archived_at`
(= "purge N days after archive"; live rows have NULL `archived_at` and never match the
expiry comparison — fail-safe by SQL semantics). Duties: the sweep's queries read through
the **archived-inclusive** path (the default preparation would hide exactly the rows it
must purge); `:delete` action rides `:destroy_permanently`; the sweep report counts
archived rows distinctly (T37 c2). `:shred` semantics unchanged.

### 5.7 Automation interplay (ADR-039 coherence)

Already anticipated by ADR-039 §4.1: a soft destroy is an **`updated`** event with
`changed: [archived_at]` — `:destroyed` fires only on the terminal path. A workflow whose
subject was archived between capture and run finds nothing on its governed re-read (the
default filter) and records a skipped run — automations never act on archived records, by
construction rather than by new code. `mutate_record`/`assign_owner` against archived
subjects fail the same way. No ADR-039 contract changes.

### 5.8 Generator integration (INV-5)

`mix samen.gen.resource` gains `--archivable` (emits the option + the partial-index
migration form); `mix samen.gen.app`'s authored vertical resource is archivable by default
and the flagship probe asserts archive → hidden → restore → visible; golden templates
updated in the same task that flips them (T37). `Samen.UI` list/detail gain the archive
action, an archived-filter toggle, and restore (T37 c3) — generated LiveViews inherit.

### 5.9 Adoption roster + the T37 decomposition convention (binding)

**Classification rule:** a resource is archivable iff it is a *user-managed noun*. Three
exclusion classes: **(L)** ledgers/logs/events (append-only truth — archiving history is
falsifying it), **(M)** provider mirrors + derived state (a mirror row hidden from
reconciliation breaks ADR-038 fetch-on-event convergence; derived rows follow their
source), **(A)** auth/governance material (revocation/expiry/deactivation are their
lifecycles — ADR-035's domain; deferred with a revisit trigger: a member-offboarding
feature).

| Scope | Archivable | Excluded (class) |
|---|---|---|
| analytics | — | product_event (L) |
| billing | plan, price | customer (M), subscription (M), invoice (M), payment (M), usage (L), entitlement (M — derived), subscription_event (L) |
| cms | page ▸cascade block, post, media, navigation, seo_meta | content_version (L; retired by T38 anyway) |
| crm | company, person 🔒, pipeline, opportunity, activity†, attachment | — |
| identity | — | all 10 (A) |
| marketing | campaign, segment, template, subscriber‡ | send (L), email_event (L), suppression (**never** — a hidden suppression row is a compliance leak), consent_event (L) |
| primitives | file§, webhook, feature_flag, **approval — no** (decision record, own machine) | notification (L — retention owns feed pruning), notification_preference (settings row), search_index (M — derived; follows its source per §5.2) |
| support | ticket ▸cascade conversation ▸cascade message, agent, sla, macro | csat (L) |
| automation (ADR-039) | workflow | run (L), reminder (own lifecycle), escalation (own machine) |
| chat (samen_web) | thread ▸cascade participant¶ ▸cascade message | disclosure_setting (settings row — per-org Tier-0 identity-disclosure config, the notification_preference shape; hiding a live config row is a semantics hazard, delete is delete) |

† `crm.activity` adopts now; the T96/T97 canonical-Task migration inherits and honors
archived state (ADR-037 §5.3 note) — the canonical Task arrives `archivable true`.
‡ Archiving a subscriber never touches the suppression list — suppression is enforced at
the delivery chokepoint independent of archival state (red test, T37).
§ `Samen.Files.ChokepointGuard` structurally refuses direct updates — the file
archive/restore actions must be guard-sanctioned in the same change (integration duty,
T36-piloted or the primitives sweep item).
¶ `chat.participant` is thread membership + the cross-plane grant carrier 🔒 (ADR-012
§2.2) — a composition child with no independent archive: it cascades with its thread, so
archiving a thread also retires its cross-plane grants from default reads on both planes;
the vaulted `full_name` stays tokenized like any archived 🔒 row (§5.1).

**T37 decomposes into serialized, mechanical sub-items** (the decompose-cross-cutting
rule; each ≤10 files, buildable from the roster row alone):

1. **T37a–T37f** — one item per adopting scope (billing, cms, crm, marketing, primitives,
   support): flip `archivable true` per the roster; convert the scope's unique indexes to
   partial (§5.3); declare roster cascades; add the scope's relationship/aggregate leak red
   test (§5.5). Chat (samen_web) rides the primitives or its own micro-item.
2. **T37g** — retention integration (§5.6) + sweep report counts.
3. **T37h** — UI affordance + gen templates + flagship-probe extension (§5.8) + the
   catalog-driven adoption probe: iterate the catalog, assert every roster-archivable
   resource exposes archive/restore + default-filter behavior, and every exclusion is
   listed here with its class (T37 c1's table-driven test — this roster is its fixture).

## 6 · E7 — Audit-on-write opt-in (spec §E7; T38)

### 6.1 Delivery: the `versioned` blueprint option

`samen do versioned true end` (optional `versioned mode: :snapshot`) attaches AshPaperTrail
to the resource; the domain gains the generated `<Resource>.Version` via
`AshPaperTrail.Domain`. **Opt-in stays per-resource judgment** — no blueprint-wide sweep
this run (E7 is an opt-in per spec; the only mandated adopters are the CMS content
resources, §6.5). Actor attribution via `belongs_to_actor` (opaque actor id — user and,
where relevant, workflow-owner attribution for ADR-039 `mutate_record` writes falls out
free and correctly names the owner).

### 6.2 Version-resource governance (INV-3)

Version resources are real AshPostgres tables and get **zero exemptions**: the samen
extension passes through `version_extensions`, so each version resource receives an
allocator-owned abbrev (ADR-023 — reserved at build time, never pinned here), prefixed
columns, `org_id` mirrored from the source record (OrgScope policies; reads keyset-bounded;
tenant-plane history surfaces, operator plane sees them masked/token-only like any table),
catalog registration, and membership in the `no_plaintext_pii` projection roster. The jsonb
`changes` column rides the existing freeform-projection audit
(`mix samen.audit.freeform_projection`).

### 6.3 PII posture (INV-1 — the decisive facts, restated as duties)

1. **Token-only diffs by construction:** the stored value per attribute is
   `Ash.Type.dump_to_embedded/2` → `dump_to_native/2`; `Samen.Type.VaultField` therefore
   emits the `vt_*` token — or fails closed if plaintext ever reached the type layer.
   T38's red test: a version row of a vault attribute contains the token, never the
   sentinel plaintext; plus the sabotage twin (ADR-037 C1(b)).
2. **`store_action_inputs?` is `false`, forever, on every samen resource** — create/update
   inputs are pre-vault plaintext. Guarded by a test asserting the option is off across all
   versioned resources (belt-and-braces over the package's own sensitive-input redaction).
3. `sensitive_attributes :ignore` for any non-vault `sensitive?` attribute a resource
   declares (ADR-037 C1(c)).
4. **No `vt_*` token leaks either:** version history surfaces render diffs through the
   masked-render path — a vault-attribute diff displays as the masked affordance
   (`•••• → ••••` with a changed marker), never the raw token in DOM/CSV/API (the masking
   watch-list "never a token" rule).
5. Mode default `:changes_only` (diff keys + new values, atomic-safe, smallest surface).
   The trade against `:full_diff` (old + new) is decided by atomicity: `require_atomic?
   false` is not acceptable substrate-wide. Where old-state matters, `:snapshot` gives the
   full prior reconstruction chain instead (§6.5).

### 6.4 Crypto-shred, retention, archival interplay

Version rows hold tokens; shredding the subject seals the vault and the tokens dereference
to nothing — version history degrades to masked, exactly like every other tier (no
version-row chasing, consistent with `Samen.Erasure`'s no-copy-chase posture). Version
tables get ordinary `Samen.Retention.Spec` entries (`timestamp_field: :inserted_at`) —
convention, host-tunable. On an archivable+versioned resource, the soft destroy is an
update ⇒ the archive itself is a recorded change (the package's own recommended answer to
versioning deletes); `:destroy_permanently` on the source leaves prior version rows subject
to their retention spec.

### 6.5 ContentVersion becomes a client (T38)

CMS `Page`/`Post`/`Block` flip `versioned mode: :snapshot` — snapshot preserves the
full-row rollback semantics `content_snapshot` provided (authored content is classified
NOT-PII today; under paper_trail, any future vaulted field would snapshot as a token —
strictly safer than the bespoke map). Then, as a **pre-1.0 destructive break (the M6/ADR-036
precedent; CHANGELOG mandatory):**

- `define_content_version` and the `<abbrev>_content_version` table are **retired**; the
  CMS version-history surface reads the generated `Page.Version`/`Post.Version`/
  `Block.Version` resources; demo's explicit `:create_version` call sites migrate.
- The long-standing discrepancy — blueprint moduledocs promise status transitions
  "append a ContentVersion row via a change hook," but publish/archive only
  `set_attribute` — is **fixed by construction**: every tracked write versions
  automatically; nothing depends on callers remembering to snapshot.
- `change_summary` (caller-supplied editorial note) is superseded; if editorial notes are
  wanted back, they return as a scan-gated metadata column on the version resources via the
  samen version extension — recorded as a post-run candidate, not owed by T38.
- The governance hash-chain is untouched (T38 c4's git-diff probe on the aud test files).

### 6.6 Impersonation-context writes — the mandatory first client (P7-F1, BINDING; T38)

Addendum reconciling the escalated persona-7 finding **P7-F1** (security · ESCALATE)
into §6. The P7 dogfood walk drove a real `Samen.Impersonation` session, mutated a
tenant record through the ordinary authorized Ash update path, and found the mutation
produced **no per-mutation audit row** — the `aud_event` delta was exactly the session
`open` event, zero rows for the mutated subject, the only physical trace a bumped
`updated_at`. Session-level attribution (open/close on the org's hash chain) was real
and correct; **write-level attribution did not exist**.

**Rule (overrides the §6.1 opt-in default for this one case):** every mutation executed
under a live `Samen.Impersonation` scope MUST emit an attributable audit row — the
impersonation chokepoint is the enforcement point, **regardless of whether the target
resource opted into `versioned true`/E7**. This is *not* a `versioned` Version row
(the target may not be versioned, and there is no Version table for it); it is a
**governance `aud_event`** on the tenant org's hash chain, the same tier the session
open/close already ride — a write-granularity governance event, not a fourth tier
(the §7.4 disjointness holds: it is neither an E7 business-history Version row, nor the
CDC mirror, nor the automation Run log).

- **Mechanism (single enforcer — in-transaction, fail-closed, all write paths).**
  `Samen.Audit.ImpersonationWrite`, a global `Ash.Resource.Change` on **every**
  `use Samen.Resource` (added via `Samen.Transformers.ImpersonationAudit`), keyed on the
  acting actor's `:impersonation` marker (`%{operator_id, org_id, session_id}`, set solely
  by `Samen.Impersonation.Scope.build/1`; a plain tenant member scope never has it, so
  ordinary tenant CRUD is **not** blanket-audited — E7 stays opt-in). It emits via
  `Samen.Audit.ImpersonationEmit`. Key facts:
  - **Registered `on: [:create, :update, :destroy]`** — load-bearing. Ash global changes
    default to **create + update only**; without `:destroy` the hook never fires for
    destroy actions — that was the actual reason bulk_destroy and atomic single
    `:destroy`/`:destroy_permanently` escaped (NOT any actor "back-fill"). Registered for
    `:destroy`, the hook fires per destroyed record with the operator on `context.actor`.
  - Adds an **`after_action`** audit hook in **both `change/3` and `atomic/3`** (an atomic
    single write calls only `atomic/3`, which also keeps bulk_update/bulk_destroy usable —
    a change with no `atomic/3` triggers `NoMatchingBulkStrategy`; a non-empty
    `after_action` makes Ash force `return_records?` + run the hook per record for atomic
    bulk). `after_action` is atomic-safe (excluded from `update.ex`'s non-atomic-forcing
    `dirty_hooks`), so **no substrate-wide `require_atomic? false`** is forced. A context
    flag dedups so exactly one hook is added.
  - **In-transaction, FAIL-CLOSED for every write type** (create/update/**destroy**,
    single + bulk): the audit is written inside the action's transaction, and on failure
    the hook returns `{:error, _}` → the write rolls back. There is **no post-commit
    notifier** (an interim design added one for destroys; retired now that the change
    covers destroys in-transaction).
  - The operator is read from the **`Change.Context.actor`** field (`= opts[:actor]`,
    reliable per record for every action type incl. bulk_destroy), with the scope's shared
    context as a secondary fallback.
- **Row (INV-2 two-plane, token-only):** `event_type "impersonation_write"` (disjoint
  from the session-lifecycle `"impersonation"` events), `actor_id` = the **operator**
  id, `correlation_id` = the impersonation **session id** (the same id the open/close
  bookends carry), `org_id`/`subject_id` = the **tenant** org, `detail` =
  `event=impersonation_write action=<name> session=<id> subject=samen:<abbrev>:<record-id>`
  — the action and the mutated record's object-ref, and **no attribute values** (INV-1:
  the row cannot leak a mutated value or a `vt_*` token by construction).
- **Coverage:** in-transaction and fail-closed for EVERY impersonated write path —
  single-record create/update/destroy/archive/restore/destroy_permanently, `Ash.bulk_create`,
  `Ash.bulk_update`, and `Ash.bulk_destroy` (per destroyed record). No path escapes.
- **Proof (T38):** `impersonation_write_audit_test.exs` — RED (impersonated single
  create/update, single `:destroy`+`:destroy_permanently`, **bulk_create/bulk_update, and
  bulk_destroy** each produce the attributable per-record rows) + positive CONTROLs
  (normal single/bulk create/update/destroy produce none) + INV-1 (a PII-shaped sentinel
  value never appears in the row) + fail-closed atomicity red-paths for BOTH update and
  destroy (an armed audit-fault aborts the impersonated write — no orphaned mutation, no
  row) + sabotage twin (`scripts/sabotages/33-p7f1-impersonation-write-audit-drop.patch`)
  neutralizing the shared emit so the six RED assertions fail.

### 6.7 General `versioned` adoption is phased (T38 disposition)

The `versioned` opt-in mechanism proper (the `samen do versioned true end` DSL option
attaching AshPaperTrail; the generated `<Resource>.Version` governance per §6.2; the CMS
`ContentVersion` retirement per §6.5) is **phased into a filed follow-up** rather than
landed alongside §6.6. Rationale (the decompose-cross-cutting rule): §6.2's
version-resource governance requires the **first auto-allocated abbrev on a generated
resource** in the codebase (every abbrev today is an explicit `use Samen.Resource,
abbrev:` literal; the allocator has no generated-resource path yet), and §6.5 is a
pre-1.0 **destructive break** rippling across demo/driftwood/pawchart test surfaces —
a blast radius unsafe to land mid-session under sole CI-surface ownership. The dep-add
(`ash_paper_trail ~> 0.6.0`, ADR-037 §5.4 ADOPT, T38-owned) is deferred **with** its
first governed adopter, matching how ash_archival/ash_oban were added in their adopting
task (T36/T39), not ahead of it. The P7-F1 impersonation-write audit (§6.6) does **not**
depend on `versioned` and ships now.

## 7 · Cross-capability + cross-ADR interactions

1. **Approve vs archived subject:** a handler's governed read of an archived/vanished
   subject fails; per §4.3 the decision rolls back and the approval stays pending — the
   approver sees the honest error and may `cancel`. No decision ever executes against a
   record the requester could no longer see.
2. **Approval-gated actions as automation targets (ADR-039):** an automation invoking a
   gated action gets fail-honest `{:error, {:approval_required, id}}`; the run records the
   action failure with that error kind — automations may *open* approvals (as requesters),
   they never satisfy them. The D5 AI-draft human-approve loop is a named future tenant
   kind.
3. **Approvals vs reveal time-box:** decision lifecycle (Approval) and capability lifecycle
   (RevealGrant, `expires_at`, auto-revoke) are distinct objects — §4.7(3).
4. **The four audit tiers, disjoint by design:** `aud_chain` hash-chain = tamper-evident
   governance events (approvals decisions land here, §4.3); CDC = token-blind analytics
   mirror; AshPaperTrail versions = per-resource business history (E7); ADR-039 `Run` log =
   automation outcomes (ids/enums only). No tier subsumes another; none stores action
   inputs.
5. **Soft-delete vs automation:** §5.7 — archive is `updated`; archived subjects yield
   skipped runs by the default filter.
6. **T96 (canonical Task):** consumes §5.9 (activity adopts now, Task arrives archivable,
   migration honors archived rows) and allocates the next ADR number after this one.

## 8 · Plane placement (INV-2)

| Surface | Plane |
|---|---|
| Tenant approval request/decide UI + pending list | Tenant (approver `RoleAtLeast :admin` default) |
| Reveal (`"pii_reveal"`) approvals | Operator only; rows `org_id NULL`, structurally invisible to tenant actors |
| Archive/restore affordances, trash (archived) views | Tenant; operator surfaces see archived rows masked/token-only like live ones |
| `:destroy_permanently` | Never tenant UI — retention sweep, erasure, operator governance |
| Version-history surfaces | Tenant plane, masked-render diffs; operator plane masked/token-blind |
| Audit chain entries for decisions/archive/restore | Governance tier, both planes' existing audit views |

## 9 · PII posture summary (INV-1)

1. No approvals row ever stores action inputs — intent lives in governed, vault-routed
   domain records; handlers re-derive (§4.4). `reason` is PiiReasonScan-gated, ids opaque.
2. `archived_at` is a non-PII timestamp; archived rows keep tokens vaulted, masked per
   plane, erasure-countable; crypto-shred and the terminal destroy are byte-for-byte the
   existing path (§5.1).
3. Version diffs hold `vt_*` tokens by the type's dump face — red-tested with a sabotage
   twin; `store_action_inputs?` off forever; version tables ride every no-plaintext roster
   and the freeform-projection audit (§6.3).
4. No surface renders a raw token: approval subject previews and version diffs go through
   the masked-render path (watch-list discipline).
5. Job args (approval-expiry scan) are ID-only per the ADR-037 §5.9 sink rule.

## 10 · Verifier + sabotage duties (INV-3 — owed by the implementing tasks)

- **T34:** DB CHECK red (equal-ids insert raises on `<abbrev>_distinct_party`) + distinct
  control; policy-layer `:self_approval` red + audit assert; cross-org red both directions
  (tenant A vs org-B rows AND vs NULL-org rows); double-approve exactly-once
  (machine-guard) test; approve-executes-once / reject-never (red + control); two gated
  action types; expiry-scan job-args sink test; sabotage: bypass the Gate's refusal — the
  approval-required test must fail.
- **T35:** module probe (grant issuance calls `Samen.Approvals`); **every pre-existing
  reveal/grant/masking test green unmodified** (list in evidence); auto-revoke timing
  tests green; golden templates gain the approval migration; `mix samen.verify.pii_reads`
  green.
- **T36:** default-read red / archived-read control / restore assert; relationship +
  aggregate leak red tests (§5.5); masking test on an archived vaulted pilot; idempotence;
  restore-conflict honest error; search deindex/reindex; archive/restore audited; ALL
  existing retention/shred tests green; sabotage: flip the default-filter preparation —
  the named hidden-from-default-reads test must fail (ADR-037 §5.3).
- **T37 (a–h):** per-scope adoption probe rows go green as items land; partial-index
  conversion per scope; suppression-unaffected-by-subscriber-archive red test; retention
  archived-count assert; UI + gen-probe; full `./ci.sh` at the end of the chain (per its
  handoff).
- **T38:** token-only diff red + sabotage twin; `store_action_inputs?`-off guard test;
  non-opted-resource control; version tables in `no_plaintext_pii` roster + freeform
  audit; CMS history reads Version resources (tests updated per §6.5); hash-chain files
  untouched (git-diff probe) and green.

## 11 · Follow-up tasks (buildable from these contracts)

| Task | Consumes | Est. files (≤10 each) |
|---|---|---|
| T34 — E3 engine | §4.1–§4.6 (resource via `define_approval`, machine, CHECK, registry, Gate, seam API, expiry scan) | ~9 — blueprint define, approvals.ex (API), handler.ex, gate.ex, registry/config, migration, expiry trigger, engine_test.exs, approvals policy bits |
| T35 — reveal client | §4.7 verbatim | ~7 — grants.ex edits, reveal/approval_handler.ex, host mounts/migrations, golden templates, probe test |
| T36 — E6 core | §5.1–§5.5, §5.8 pilot (option in Samen.Resource, archival attach, actions, search hook, 2 pilots incl. one vaulted + the file-guard sanction) | ~9 |
| T37a–h — adoption | §5.9 rows + §5.3/§5.4/§5.6 | mechanical per item |
| T38 — E7 | §6 (option, version_extensions pass-through, guards, CMS migration) | ~9 |

Deliberately left to implementers: exact abbrev values (allocator-owned, ADR-023); the
Gate's one-shot approval-context mechanism; Approval builder/UI layout; per-host retention
TTLs for version tables; the samen version-extension internals (which existing extension
face carries org_id mirroring).

## 12 · Rejected alternatives

- **Deferred parameterized execution for approvals** (persist the pending action's inputs,
  replay on approve) — action inputs are pre-vault plaintext; this is ash_events' C1 FAIL
  re-entering through E3. Intent-as-domain-state + handler re-derivation instead (§4.4).
- **Executing the approved action as the approver** — privilege confusion; the approver
  consents, the requester acts within their own policy envelope (§4.4).
- **Vault-routing the approval `reason`** — the approver must read it to decide, on the
  operator plane for reveal kinds; masked reasons make two-party review theater.
  PiiReasonScan write-gating (the aud detail precedent) instead (§4.1).
- **A second approvals store for the operator plane** (or plain-Ecto kernel approvals) —
  two stores drift; the NULL-org documented exception + OrgScope's fail-closed filter
  covers both planes with one resource, and keeps AshStateMachine per ADR-037 §5.8.
- **`base_filter` as the archival default** — airtight but structurally blocks unarchive;
  restore is a hard E6 requirement (ADR-037 fixed this; resources with
  aggregate-sensitive semantics may still opt into base_filter + companion resource by
  exception, none rostered today).
- **Archivable-by-default across all blueprints** — ledgers, mirrors, suppression, and
  auth material must never hide rows (§5.9's three exclusion classes are load-bearing).
- **Cascade-by-default / auto-restore-all-children** — silent data hiding; cascades are
  declared composition only, restore matches the cascade instant (§5.4).
- **`:full_diff` versioning** — `require_atomic? false` substrate-wide is not acceptable;
  `:snapshot` covers the old-state need (§6.3, §6.5).
- **Keeping ContentVersion as a parallel bespoke store** — the spec sentence is "becomes a
  client"; two version stores on one scope guarantee drift, and the bespoke one is already
  half-wired (§6.5).

## 13 · Consequences

1. Two-party decision-making becomes a substrate primitive with the reveal-grade
   enforcement stack (policy + CHECK + audit), and reveal grants shrink to its first
   client with zero observable change.
2. Every blueprint gains a one-line trash/restore capability whose filters, indexes,
   cascades, retention, and exclusions are convention, not per-resource invention; the
   terminal path (hard destroy + crypto-shred) is untouched.
3. Per-resource business history is a one-line opt-in whose rows are token-only by the
   type system and governed like any table; CMS versioning stops being bespoke and starts
   being true (the auto-append promise finally holds).
4. The audit story is four disjoint tiers with stated boundaries (§7.4) — no tier stores
   action inputs, none was weakened.
5. T37 stops being a 100-file risk: eight mechanical items driven by one roster table.
6. New verifier/sabotage surface added across T34–T38 (§10); none removed.

## 14 · References

- ADR-037 §5.3/§5.4/§5.5/§5.8/§5.9; ADR-039 (§4.1 archival note, §7.4 escalation seam);
  ADR-036 + M6 (destructive-break precedent); ADR-035 (identity lifecycles stay its
  domain); ADR-023 (allocator); ADR-015/ADR-034 (classification oracle, for context).
- `samen_core/lib/samen/reveal/{schema,grants,auto_revoke_worker}.ex`;
  `samen_core/priv/test_repo/migrations/20260705050100_reveal_grants.exs`
  (`rvg_distinct_party`); `samen_core/test/reveal_grant_{db_check,same_tx}_test.exs`.
- `samen_core/lib/samen/retention{,.ex,/spec.ex,/sweep_worker.ex}`;
  `samen_core/lib/samen/erasure.ex`; `samen_core/lib/samen/kms.ex`;
  `samen_core/lib/samen/audit_chain/{schema,writer}.ex`.
- `samen_core/lib/samen/scopes/cms/blueprint.ex` (`define_content_version`, the retired
  client); `samen_core/lib/samen/resource.ex`; `samen_core/lib/samen/policy/org_scope.ex`;
  `samen_web/lib/samen/web/reads.ex`.
- `spec/full-saas-readiness.md` §E3/§E6/§E7, INV-1..INV-6; `_orch/plan/spec-questions.md`
  c6, c12; `_orch/tasks/{T34,T35,T36,T37,T38}/handoff.md`.
