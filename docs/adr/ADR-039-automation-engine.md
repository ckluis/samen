# ADR-039 — Automation engine: the WS-E E1/E2/E4/E5/E8 contracts

- **Status:** Accepted.
- **Date:** 2026-07-23.
- **Task:** T32 (Phase-3 automation ADR). Downstream implementers: **T39** (E1 engine),
  **T40** (E2 actions), **T41** (E4/E5 reminder + escalation), **T42** (E8 observability).
  Their handoffs bind to the contracts here; §12 names what each consumes.
- **Consumes:** ADR-037 §5.7 (**Reactor ADOPT**), §5.8 (**AshStateMachine ADOPT, targeted**),
  §5.9 (**AshOban ADOPT**) — and honors the rejections: §5.5 (ash_events REJECT — the run log
  is a samen resource, not an event store), §5.13 (ash_admin REJECT — the E8 health view is
  first-party operator plane). Rulings: spec-questions **c13** (non-PII condition keys per the
  TargetRule precedent). Spec: §E1, §E2, §E4, §E5, §E8; INV-1/INV-2/INV-5.
- **Precedents built on:** `Samen.FeatureFlags.TargetRule` + ADR-020 (condition shape,
  write-time non-PII refusal), `Samen.Notifications.Engine` (host-wired module/repo seams,
  id-only envelopes, fail-closed `{:error, :no_*_module}`), `Samen.Cdc.Projection` + ADR-015
  (the default-deny non-PII classification oracle), ADR-038 (delivery chokepoint, webhook
  ingress redaction posture), `Samen.Scopes.Support.SlaBreachWorker` +
  `Samen.Billing.Dunning` (the E5 clients being adopted), object-ref convention
  (`"samen:scope.resource:<id>"`).

---

## 1 · Context

The table's Rules column is user-facing automation, and today the flag-scoped TargetRule
engine is the only condition→action machinery in the substrate (spec WS-E preamble). WS-E
demands: tenant-definable Workflows (E1: trigger → conditions → actions), an action library
(E2: 8 actions), a first-class Reminder scheduler (E4), a generic Escalation primitive with
SLA-breach and dunning as its first clients (E5), and observable runs with a kill-switch (E8).

Automation is exactly the surface class that leaks PII (INV-1): it re-renders records into
notifications, emails, and webhooks on a schedule, with no human in the loop. And automation
that can trigger automation is exactly the surface class that melts a tenant's database. This
ADR fixes the contracts so T39–T42 build a governed engine, not a footgun.

## 2 · ADR-037 verdicts consumed (binding)

| Verdict | What this ADR does with it |
|---|---|
| §5.7 Reactor **ADOPT** | E1 workflow execution = runtime-built reactors via `Reactor.Builder`; steps invoke governed Ash actions; per-action compensation per §5.2 here. Trigger/condition evaluation stays the pure TargetRule-precedent evaluator — Reactor is the execution layer only. Zero new deps (transitive of ash). |
| §5.8 AshStateMachine **ADOPT (targeted)** | New state-bearing resources only: the E8 `Automation.Run` lifecycle (§8.1) and the E5 `Automation.Escalation` lifecycle (§7.1). Workflow itself uses a plain bounded `status` enum (its transitions are trivial CRUD, not a guarded machine). No retrofit of existing resources. |
| §5.9 AshOban **ADOPT** | All three periodic scans — E1 schedule-due (§4.3), E4 reminder-due (§6.3), E5 escalation-step-due (§7.3) — are AshOban triggers with **explicit `scheduler_cron`** (no accidental every-minute defaults), queues registered via `AshOban.config/2`, `max_attempts` set per job class, and the **ID-only ActorPersister rule**: job args carry bounded ids/enums only — never actor structs, never attribute values, never `vt_*` tokens (red-tested, §11). |
| §5.5 ash_events **REJECT** | The E8 run log stores *run outcomes* (bounded enums + ids), never action inputs; no replay semantics. |
| §5.13 ash_admin **REJECT** | The E8 health view is a first-party operator-plane LiveView, token-blind by construction. |

## 3 · Architecture overview

### 3.1 Resource model — new `Samen.Scopes.Automation.Blueprint` (the ninth scope)

Materialized per-host by the ADR-004 convention; abbrevs allocated **only** through
`mix samen.abbrev.reserve` (ADR-023 — never pinned in this ADR); every resource org-scoped
(`Samen.Policy.OrgScope`), catalogued per `catalog_parity`.

| Resource | Task | Purpose | Key columns (logical names) |
|---|---|---|---|
| `Automation.Workflow` | T39 | E1 rule definition | `name`, `status` (enum `draft\|active\|paused`), `trigger_kind` (enum `resource_event\|schedule\|manual`), `resource_key` (catalog key of the target resource), `event` (enum `created\|updated\|destroyed`, resource_event only), `schedule_cron` (bounded cron string, schedule only), `next_fire_at` (utc, schedule only), `conditions` (bounded jsonb, §4.4), `actions` (ordered bounded jsonb of action configs, §5), `owner_id` (bounded FK — the execution principal, §4.5), `disabled_by_operator_at` + `disabled_reason` (enum, §8.4), `webhook_secret` (`public?: false`, §5.3) |
| `Automation.Run` | T42 | E8 run log | `workflow_id`, `dispatch_key` (unique, §4.6), `state` (AshStateMachine, §8.1), `trigger_kind`, `subject_ref` (object ref string), `depth`, `outcome` (bounded jsonb: per-action `{index, kind, status, error_kind}` — enums/ids only), `started_at`, `finished_at`, `duration_ms`, `error_kind` (bounded enum) |
| `Automation.Reminder` | T41 | E4 | `recipient_id`, `subject_ref`, `remind_at`, `note` 🔒 (vault-routed `pii_attribute`, §6.2), `source` (enum `user\|automation\|system`), `state` (enum `scheduled\|sent\|cancelled`), `sent_at` |
| `Automation.Escalation` | T41 | E5 | `kind` (bounded string: `"sla_breach"\|"dunning"\|"automation"\|host-registered`), `dedupe_key`, `subject_ref`, `deadline_at`, `chain` (bounded jsonb, §7.2), `current_step`, `next_action_at`, `state` (AshStateMachine, §7.1), `resolved_at` |

No resource stores attribute *values* from trigger events — envelopes and logs carry ids,
enums, timestamps, and object refs only. Freeform user content appears exactly once
(`Reminder.note`) and is vault-routed like `Notification.rendered_body`.

### 3.2 Module boundaries (INV-5)

- **`samen_core`** — the blueprint above; `Samen.Automation.Condition` (evaluator);
  `Samen.Automation.NonPiiPredicates` (write-time refusal change);
  `Samen.Automation.EventCapture` (the transactional trigger tap, §4.2);
  `Samen.Automation.DispatchWorker` / `RunWorker` (Oban);
  `Samen.Automation.Compile` (workflow → `Reactor.Builder`);
  `Samen.Automation.Action` behaviour + the 8 actions;
  `Samen.Automation.Remind` + `Samen.Automation.Escalate` public APIs (host-wired
  module/repo seams per the `Notifications.Engine` convention — config-resolved, opts
  override, **fail-closed** `{:error, :no_automation_module}` when unwired);
  `Samen.Automation.Recorder` (Reactor middleware, T42);
  `Samen.Automation.Breaker` (rate trip, T42). No new samen_core deps
  (reactor is transitive; ash_oban lands per ADR-037 §5.9 — an ash-project extension,
  not a vendor SDK).
- **`samen_web`** — Workflow builder LiveView + per-workflow run list (tenant plane),
  operator health view (operator plane), `samen_automation_routes()` router macro.
- **Verticals/demo** — adopt via the router macro at ≈0 LOC; `mix samen.gen.app` wires the
  Oban queues/crontab and blueprint mount (INV-3 gen-app probe extends).

### 3.3 Execution pipeline

```
capture (in-txn, non-PII envelope)          §4.2
  → DispatchWorker (match active workflows by org+resource+event)
    → per-match RunWorker (Oban unique)     §4.6
        kill-switch re-check                §8.4
        loop/depth/rate guards              §4.7
        re-read subject via governed read (owner actor)  §4.5
        condition AND-gate                  §4.4  — no match ⇒ run recorded :skipped
        Compile → Reactor.run               §5    — outcomes recorded per action
  → Run row finalized (T42)                 §8
```

Schedule and manual triggers enter at DispatchWorker with the same envelope shape.

## 4 · E1 — Workflow resource + trigger/condition engine (spec §E1; T39)

### 4.1 Trigger taxonomy

Three kinds, one pipeline:

1. **`resource_event`** — `created | updated | destroyed` on one catalog-listed, org-scoped
   resource. Captured in-transaction (§4.2). Note the T33 interplay: once ash_archival lands
   (ADR-037 §5.3), soft-destroys are *updates* — `:destroyed` fires only on real destroys
   (retention/erasure path); archive is observable as `updated` + `changed: archived_at`.
2. **`schedule`** — a bounded cron expression owned by the tenant rule. Because tenant cron
   strings are runtime data and AshOban triggers are compile-time DSL, the design is **one**
   AshOban trigger on the Workflow resource itself: predicate
   `status == :active and trigger_kind == :schedule and next_fire_at <= now`,
   `scheduler_cron "* * * * *"` (explicit), which enqueues per-workflow dispatch and
   advances `next_fire_at` (computed via `Oban.Cron.Expression` — already in the tree, no
   new dep) under an idempotent `WHERE next_fire_at = $old` guard.
3. **`manual`** — the builder's "Run now" against a chosen subject record (also the test-run
   affordance). Requires workflow-edit permission; same pipeline, `trigger_kind: :manual`.

### 4.2 Resource-event capture — transactional, non-PII envelope

Capture is a blueprint-level after-action hook (`Samen.Automation.EventCapture`) running
**inside** the write transaction, which `Oban.insert`s one `DispatchWorker` job in the same
transaction — **transactional capture**: the event exists iff the write committed; no
after-commit gap can lose it. The envelope (job args) is non-PII **by construction**:

```elixir
%{org_id, resource_key, event, record_id, changed: [attribute_names], event_id,
  depth, chain: [workflow_ids]}   # ids/atoms/names only — NO attribute values
```

Attribute *names* are catalog metadata, not data. Values are never serialized into
`oban_jobs.args` (the ADR-037 §5.9 sink rule; red-tested). Guard for write-amplification:
capture consults a per-org active-trigger index (cached; invalidated on Workflow writes) and
inserts **nothing** when no active workflow matches org+resource+event — correctness never
depends on the cache, only cost does.

### 4.3 Schedule dispatch

Covered in §4.1(2). Queue: `:automation` (registered via `AshOban.config/2`), scan job
`max_attempts 1` (next minute's scan is the retry), per-run jobs `max_attempts 3`.

### 4.4 Condition model — the TargetRule precedent, generalized (c13)

Conditions are a bounded jsonb list evaluated as an **AND-gate** (all must match ⇒ actions
run; these are gates, not routers — no first-match-wins):

```elixir
%{"attribute" => "priority", "op" => "gte", "values" => ["high"]}
```

- **Op set:** `eq | neq | in | not_in | gt | gte | lt | lte | is_nil | not_nil | changed`.
  `changed` tests membership in the envelope's `changed` name list (enables "when status
  changes"); the comparison ops make due-date/priority rules expressible. Same tolerant
  `parse/1` discipline as TargetRule: a malformed condition is **dropped at read** — but
  unlike flags (which degrade to a default), a workflow whose parsed condition list is
  shorter than its stored list does NOT fire; the run is recorded `:skipped /
  :invalid_conditions` (an automation must never fire on fewer gates than the tenant wrote).
- **Non-PII whitelist, enforced at WRITE time** (the `NonPiiTargeting`/RP-F3 precedent):
  `Samen.Automation.NonPiiPredicates` refuses any condition (or action interpolation, §5.2)
  keying an attribute that is not **condition-eligible**. Eligibility is defined as: the
  attribute projects through `Samen.Cdc.Projection` as a **non-token kind** (structural-safe
  scalar, or freeform bearing a valid two-party `non_pii!` clearance — ADR-015/ADR-034
  oracle). One oracle, three consumers (CDC, flags, automation) — no second classification
  ever drifts. A `pii_*`/vault-routed attribute is refused with the red-tested error
  (T39 c2). The catalog dump gains a derived `automation_eligible` flag per attribute
  (computed from the same oracle — c13 "catalog marks eligible attributes"; never
  hand-marked).
- **Evaluation** happens in RunWorker against a **fresh governed re-read** of the subject
  (never the envelope — which carries no values anyway, and never stale row images). The
  subject map handed to the evaluator contains only condition-eligible attributes; a vault
  field structurally cannot reach `Condition.matches?/2`.

### 4.5 Execution actor + policy posture

Runs execute **as the workflow's owner** (`owner_id`, re-resolved at run time): every read
and every E2 action goes through governed Ash actions authorized as that member, on the
**tenant plane**. Consequences, all deliberate:

- Record mutations respect policies — a rule whose owner cannot update the target fails
  `:unauthorized` (T40 c3 red test), no system-actor bypass exists.
- INV-1: the owner holds no reveal grants during automation runs — any vault field read
  resolves to `%Masked{}` via `Samen.Api.PiiResolution`; automations render framework copy +
  object refs, never plaintext (§10).
- Owner removed/deactivated ⇒ run fails `:owner_unavailable` (recorded; surfaces in the E8
  health view) — never silently re-attributed.

### 4.6 Idempotency + at-least-once semantics

Oban is at-least-once; the engine layers two dedupe tiers:

1. **T39:** per-run jobs are Oban-**unique** on `{workflow_id, event_id}` (plain-Oban unique
   jobs) — a retried DispatchWorker cannot double-enqueue a run.
2. **T42:** `Run.dispatch_key = sha256(workflow_id <> event_id)` under a **unique index** —
   durable dedupe across the job-pruning horizon; a second insert is a no-op conflict.

Actions are therefore **at-least-once**: notify is preference-gated and cheap; email rides
the ADR-038 chokepoint; webhooks carry `delivery_id` (= dispatch_key) so receivers dedupe;
record mutations are set-semantics idempotent where possible, and compensation (§5.2) covers
partial-run failure. Exactly-once is explicitly NOT claimed anywhere.

### 4.7 Loop + rate protection (automation triggering automation)

Writes performed by a run execute with an actor context carrying `{depth, chain}`; events
captured from those writes inherit `depth + 1` and `chain ++ [workflow_id]` (§4.2 envelope).
Three guards, all recorded as skipped runs (visible in E8, never silent):

1. **Cycle refusal** — an envelope whose `chain` already contains the candidate workflow id
   is skipped `:loop` (a workflow can never re-fire itself transitively).
2. **Depth cap** — `depth > 3` (config `:samen_core, :automation_max_depth`) skips
   `:depth_exceeded`. Chains of A→B→C→D are legitimate; unbounded cascades are not.
3. **Rate breaker (T42)** — more than 60 runs/workflow/minute (config-tunable) auto-trips the
   operator kill-switch: `disabled_by_operator_at` set with `disabled_reason: :rate_tripped`,
   operator notification emitted, tenant sees the tripped state in the builder. Re-arming is
   an explicit operator (or, for rate trips, tenant-owner) action — never automatic.

## 5 · E2 — Action library (spec §E2; T40)

### 5.1 The action behaviour

```elixir
defmodule Samen.Automation.Action do
  @callback kind() :: atom()
  # Write-time config validation (called by the Workflow changeset alongside
  # NonPiiPredicates — bad configs are refused at save, never at fire time).
  @callback validate(config :: map(), resource_key :: String.t()) ::
              {:ok, normalized :: map()} | {:error, term()}
  # Fire time. ctx is %Samen.Automation.Context{org_id, workflow_id, run_id,
  # subject_ref, subject (governed re-read), actor (owner), depth, chain}.
  # meta is bounded (ids/enums only) — it lands in the Run outcome jsonb.
  @callback run(config :: map(), ctx :: Samen.Automation.Context.t()) ::
              {:ok, meta :: map()} | {:error, error_kind :: atom()}
  # Reactor compensation face (ADR-037 §5.7). Optional; default no-op.
  @callback undo(config :: map(), meta :: map(), ctx :: Context.t()) ::
              :ok | {:error, term()}
  @optional_callbacks undo: 3
end
```

The registry maps bounded action `kind` strings to modules (config-extendable by hosts; the
8 below ship in core). Each action executes as one Reactor step; a step failure records the
action outcome, triggers whole-run compensation (undo of completed steps, in reverse), and
finalizes the run `:failed` — **action failures never crash the engine** (T40 c4).

### 5.2 The 8 actions

Interpolation rule (binding, INV-1): wherever a config allows values from the subject
(`{{subject.attr}}`), the attribute must be **condition-eligible** (§4.4 oracle) — validated
at write time by the same `NonPiiPredicates` pass. Vault fields are structurally
un-referenceable in any action config.

Exactly **8 registry kinds**, mapping 1:1 onto spec §E2's 8 items (the spec's "create/update
a record" is one item ⇒ one `mutate_record` kind with a `mode`) — T40's table-driven
one-test-per-action has 8 rows:

| # | kind | Config (bounded) | Executes via | undo |
|---|---|---|---|---|
| 1 | `notify` | `recipient` (`"owner"\|"org"\|user_id`), `event_type` (bounded), `template_key` (framework copy) | `Samen.Notifications.Engine.emit/1` — preference-gated, body vault-routed by the engine itself | no-op (at-least-once) |
| 2 | `send_email` | `to` (recipient **selector**: `"owner"\|user_id` — freeform addresses deliberately excluded this run; a to-address is PII input), `template_key`, `assigns` (eligible attrs only) | ADR-038 delivery chokepoint incl. suppression check (T40 c2 red test) | no-op |
| 3 | `mutate_record` | `mode` (`"create"\|"update"`), `resource_key` (create mode), `attrs` (literal or eligible interpolation); update targets the subject | governed create/update as owner | create mode: destroy the created record (`meta.record_id`) — meaningful reversal per ADR-037 §5.7. Update mode: **no-op, documented** — reversing requires snapshotting prior values, and prior values may be PII; the engine never captures them (INV-1 beats undo fidelity) |
| 4 | `assign_owner` | `attribute` (catalog bounded-id attr, default `owner_id`), `user_id` (literal or `"workflow_owner"`) | governed update | no-op (same reason) |
| 5 | `add_tag` | `tag` (bounded string) | §5.4 seam | no-op |
| 6 | `escalate` | `kind: "automation"`, `deadline_minutes`, `chain` (§7.2) | `Samen.Automation.Escalate.open/2` with `dedupe_key: "wf:" <> workflow_id <> ":" <> subject_ref` | resolve the opened escalation as `:cancelled` (`meta.escalation_id`) |
| 7 | `webhook` | `url`, `include: [eligible attrs]` — full egress contract in §5.3 | signed HTTPS POST (§5.3) | no-op (receiver dedupes on `delivery_id`) |
| 8 | `enqueue_reminder` | `recipient` selector, `offset_minutes` or `at_attribute` (eligible timestamp attr), optional `note` template (framework copy only from automation — user-freeform notes are the E4 UI's business, not E2's) | `Samen.Automation.Remind.schedule/2` | cancel the created reminder (`meta.reminder_id`) |

Actions 6 and 8 build **directly** on the T41 primitives (T40's blocked_by edge exists
precisely so no stub phase can occur); their public signatures are fixed in §6.1/§7.2 —
T41 c4 binds those signatures verbatim.

### 5.3 Webhook egress contract

Payload — fixed schema, non-PII by construction:

```json
{"delivery_id": "...", "org_id": "...", "workflow_id": "...", "event": "updated",
 "subject_ref": "samen:crm.opportunity:<id>", "occurred_at": "...",
 "data": { only §4.4-eligible attrs listed in include }}
```

Binding egress rules: **no plaintext PII and no `vt_*` tokens** ever leave (the masking
watch-list "never a token in API" rule applies to egress; T40 c2 snapshot assert); HMAC-SHA256
signature header keyed on the per-workflow `webhook_secret` (generated server-side at
creation, shown once, stored `public?: false`, excluded from every projection/log, never
rendered again — the credential-material posture; app-level sealing of the column is noted as
a post-1.0 hardening candidate); SSRF guard — https-only outside dev, resolve-then-deny
loopback/RFC1918/link-local, no redirect following, bounded timeout; responses are never
stored (status code + duration into run meta only); at-least-once with backoff, receivers
dedupe on `delivery_id`.

### 5.4 The `add_tag` seam (F4 not yet landed)

E2 lands in Phase 3; the F4 Tag/Tagging resource lands with WS-F. `add_tag` therefore targets
a designed seam, not a stub: it performs a governed update appending to the target resource's
`tags` array attribute where the catalog shows one (Ticket today — a real, testable path,
satisfying T40 c1 with no fail-honest stub), and returns `{:error, :no_tag_surface}` for
resources with neither. When F4's polymorphic Tagging resource lands, its migration task
re-points this action's write path at the Tagging create in the same sweep that migrates the
Ticket array — the action *config* contract (`tag` string) is F4-stable by design.

## 6 · E4 — Reminder (spec §E4; T41)

### 6.1 Public API (binding signatures — T41 c4 / T40 build against these verbatim)

```elixir
Samen.Automation.Remind.schedule(attrs, opts \\ [])
  :: {:ok, reminder} | {:error, term()}
# attrs: %{org_id: id, recipient_id: id, subject_ref: String.t(),
#          remind_at: DateTime.t(), note: String.t() | nil,
#          source: :user | :automation | :system}
Samen.Automation.Remind.snooze(reminder_id, until :: DateTime.t(), actor, opts \\ [])
  :: {:ok, reminder} | {:error, term()}
Samen.Automation.Remind.cancel(reminder_id, actor, opts \\ [])
  :: {:ok, reminder} | {:error, term()}
```

`opts` carries the host-wired module/repo overrides (the `Notifications.Engine` convention;
config wins otherwise; unwired ⇒ fail-closed `{:error, :no_automation_module}`).

### 6.2 Semantics

- **Distinct from Notification** (spec's explicit line; T41 c1 probe): a Reminder is a
  *future intent* row with its own lifecycle (`scheduled → sent | cancelled`; snooze updates
  `remind_at` in place); the Notification is only its *delivery artifact*, created at fire
  time.
- `note` is user-authored freeform ⇒ **vault-routed** `pii_attribute` (the
  `Notification.rendered_body` precedent): plaintext never at rest, tenant plane resolves via
  `PiiResolution`, operator plane sees `••••`, CDC/exports carry the token classification —
  3-proof MaskingCase tests owed by T41 (§11).
- **Digest feed:** firing emits through `Notifications.Engine.emit/1`
  (`event_type: "reminder_due"`), so C8 digest batching applies with zero new plumbing.
- **Calendar feed:** `remind_at` is a plain timestamp column — the WS-G G2 calendar view
  consumes it as an ordinary date-field resource; a seam note, no code owed here.

### 6.3 Due-scan

AshOban trigger on Reminder: predicate `state == :scheduled and remind_at <= now`,
explicit `scheduler_cron "* * * * *"`, queue `:automation_timers`, per-record job
`max_attempts 3`. Fire = emit notification + transition `scheduled → sent` under an
idempotent state-guard `WHERE` (the SlaBreachWorker `breached = false` discipline) — a
concurrent duplicate is a no-op.

## 7 · E5 — Escalation (spec §E5; T41)

### 7.1 Lifecycle (AshStateMachine — ADR-037 §5.8's designated new-resource use)

`open → escalating → resolved | exhausted | cancelled`. Illegal transitions refused by the
machine (`NoMatchingTransition`), red-tested with a legal-transition positive control (§11).
`resolve` is legal from `open` and `escalating`; a resolved/exhausted case never walks
further steps (T41 c2 control).

### 7.2 Public API + chain shape (binding signatures)

```elixir
Samen.Automation.Escalate.open(attrs, opts \\ [])
  :: {:ok, escalation} | {:error, term()}
# attrs: %{org_id: id, subject_ref: String.t(), kind: String.t(),
#          dedupe_key: String.t(), deadline_at: DateTime.t(),
#          chain: [step] | nil}   # nil ⇒ the default single-step org chain
Samen.Automation.Escalate.resolve({org_id, kind, dedupe_key} | escalation_id,
                                  outcome :: :resolved | :cancelled, opts \\ [])
  :: {:ok, escalation} | {:error, :not_found | term()}
```

**Open is idempotent-by-dedupe:** an existing non-terminal escalation with the same
`{org_id, kind, dedupe_key}` (unique index) is *advanced/refreshed* (deadline re-mirrored),
never duplicated — the same idempotent-upsert discipline as the dunning case row.

Chain step (bounded jsonb; framework copy only, the SlaBreach notification precedent —
bounded ids travel, subject data never):

```elixir
%{"after_minutes" => 0,                        # relative to deadline_at
  "recipient"     => "org" | user_id,          # bounded
  "channel"       => "in_app" | "email"}       # email rides the ADR-038 chokepoint
```

Step 0 fires at `deadline_at`; step *n* at `deadline_at + after_minutes`. Each step emits via
`Notifications.Engine.emit/1` (`event_type: "escalation_step"`), advances `current_step`,
computes `next_action_at`; past the last step ⇒ `exhausted`.

### 7.3 Deadline scan

AshOban trigger on Escalation: predicate
`state in [:open, :escalating] and next_action_at <= now`, explicit `scheduler_cron`,
queue `:automation_timers`, idempotent per-step advance under a `current_step` guard.

### 7.4 Client adoption seams (adoption, NOT rewrites — binding for T41)

The primitive owns *attention* (chain walking + notification emission). Clients keep their
domain truth untouched:

- **SLA breach** (`Samen.Scopes.Support.SlaBreachWorker`): keeps its scan, its `breached`
  flag flip, and its `aud_event` emission unchanged. Its inline
  `Notifications.Engine.emit/1` call — the only bespoke attention path — is **replaced** by
  `Escalate.open(%{kind: "sla_breach", dedupe_key: ticket_id, subject_ref: "samen:support.ticket:" <> id, deadline_at: breach_at, chain: nil})`.
  (T41 c3's "old bespoke path removed" = that emit call; grep probe target.)
- **Dunning** (`Samen.Billing.Dunning`): keeps its gate/watermark, mirror upsert, and
  entitlement logic verbatim. `reconcile/2` additionally opens/advances
  `kind: "dunning", dedupe_key: provider_invoice_id, deadline_at: grace boundary (period_end)`;
  `recover/2` additionally calls `Escalate.resolve({org, "dunning", provider_invoice_id}, :resolved)`
  best-effort (the Dunning module's own "never re-decides, never aborts the main path"
  posture applies to the escalation calls too).

## 8 · E8 — Observability (spec §E8; T42)

### 8.1 Run log

`Automation.Run` (§3.1) records **every** dispatch outcome — `fired` (→ `succeeded|failed`),
`skipped` (with bounded reason: `:conditions_unmet | :invalid_conditions | :killed | :loop |
:depth_exceeded | :rate_tripped | :owner_unavailable`), timing, and the per-action outcome
list. State machine: `queued → running → succeeded | failed | skipped`. Recording is a
**Reactor middleware** (`Samen.Automation.Recorder` — ADR-037 §5.7's telemetry face): step
timings and outcomes captured without action code knowing about the log. Log rows are
non-PII by schema (ids/enums/timestamps only — passes `mix samen.verify.no_pii_columns`,
T42 c3); exception detail beyond `error_kind` goes to Logger, never to rows.

T39 ships the engine with test-asserted outcomes but without Run rows; T42 adds the resource
+ recorder + the durable `dispatch_key` unique index (§4.6 tier 2). To avoid migration churn,
**T39's Workflow schema already includes** `disabled_by_operator_at`/`disabled_reason` and
the dispatch `WHERE` honors them from day one; T42 delivers the surfaces.

### 8.2 Tenant-plane run list

Per-workflow run history in the builder (tenant plane): state, reason, timing, subject_ref.
Bounded ids only — nothing to mask, keyset-bounded reads.

### 8.3 Operator health view

Operator-plane LiveView: per-org/per-workflow aggregates — run counts by state, error-kind
distribution, last failure, trip status. **Token-blind by construction** (INV-2): it reads
only the Run schema, which structurally contains no PII and no tokens; first-party (ash_admin
REJECT honored).

### 8.4 Kill-switch semantics (binding)

Two independent switches, both audited:

- **Tenant pause** — `status: :paused`, owner-controlled in the builder.
- **Operator kill** — `disabled_by_operator_at` + `disabled_reason`
  (`:operator | :rate_tripped`), operator-plane (or breaker-set, §4.7(3)).

Dispatch requires `status == :active AND disabled_by_operator_at IS NULL`. Enforcement is
**double-checked**: at dispatch (no new runs enqueued) and again at RunWorker start (already
queued runs of a killed rule finalize `skipped / :killed`) — a kill takes effect within at
most one in-flight run, and killed-while-queued work is visible in the log, never silently
dropped. Other workflows are unaffected (T42 c2 control). Switch flips write audit events;
re-arming is explicit (§4.7).

## 9 · Plane placement (INV-2)

| Surface | Plane |
|---|---|
| Workflow builder + manual run + tenant pause | Tenant |
| Per-workflow run list | Tenant |
| Reminder create/snooze/cancel UI + digest/calendar feeds | Tenant |
| Escalation notifications (chain steps) | Tenant (recipients are org members) |
| Health view + operator kill-switch | Operator (token-blind) |
| Run log resource | Non-PII by schema; readable from both planes' surfaces above |

## 10 · PII posture summary (INV-1)

1. Condition keys, action interpolations, and webhook `include` lists all pass ONE write-time
   eligibility oracle (CDC-projection non-token kinds) — vault/PII attributes are
   structurally unreferenceable in any workflow definition (c13).
2. Event envelopes, job args, run rows, and escalation chains carry ids/enums/names/refs
   only — never attribute values, never `vt_*` tokens (ADR-037 §5.9 sink rule, red-tested).
3. Runs execute as the workflow owner on the tenant plane through `PiiResolution` — no
   grant, no plaintext; automations render framework copy + object refs (the SlaBreach
   notification precedent).
4. Webhook egress: no plaintext PII, no tokens, fixed schema, signed (§5.3).
5. The single freeform surface (`Reminder.note`) is vault-routed with 3-proof MaskingCase
   coverage owed by T41.
6. Email actions route through the ADR-038 chokepoint (suppression, deliverability,
   token-blind events) — no second send path.

## 11 · Verifier + sabotage duties (INV-3 — owed by the implementing tasks)

- **T39:** red: PII-keyed condition refused at write (+ non-PII control); red: cross-org
  event never fires another org's rule; sabotage: flip the NonPiiPredicates refusal — the
  named test must fail. Catalog rows for Workflow via allocator; gen-app probe gains the
  blueprint + queues.
- **T40:** suppressed-recipient email red test; webhook snapshot assert (no plaintext, no
  `vt_*`); unauthorized-mutation red + control; action-failure isolation assert; sabotage:
  leak a vault token into the webhook payload builder — snapshot test must fail.
- **T41:** MaskingCase 3-proofs on `Reminder.note` (green/red/sabotage-twin); illegal
  escalation transition red + legal control; job-args sink red test (no PII/token in
  `oban_jobs.args` for timer scans); SLA/dunning client tests + old-path grep probes; all
  pre-existing SLA/dunning tests stay green.
- **T42:** `no_pii_columns` on Run; kill-switch red (killed stops) + control (others fire);
  dispatch_key uniqueness under concurrent duplicate dispatch; sabotage: bypass the
  RunWorker kill re-check — the killed-rule test must fail.

## 12 · Follow-up tasks (done-criterion 3)

| Task | Consumes | Est. files (≤10) |
|---|---|---|
| T39 — E1 engine | §3, §4 (Workflow resource, capture, dispatch, conditions, actor, unique-jobs tier, guards 1–2; schema incl. §8.4 columns) + minimal `notify` for end-to-end proof | ~10 — workflow.ex, condition.ex, non_pii_predicates.ex, event_capture.ex, dispatch_worker.ex, run_worker.ex, compile.ex, builder LiveView, routes macro, workflow_test.exs |
| T40 — E2 actions | §5 (behaviour, registry, 8 actions, webhook egress, add_tag seam) | ~10 — action.ex + registry, 8 action modules (record-family may share a file), actions_test.exs |
| T41 — E4/E5 | §6, §7 (resources, APIs verbatim, scans, SLA/dunning seams) | ~9 — reminder.ex, remind.ex, escalation.ex, escalate.ex, timer wiring, 2 client rewires (edits), 2 test files |
| T42 — E8 | §8 + §4.6 tier 2 + §4.7 guard 3 (Run, Recorder middleware, breaker, health view, kill surfaces) | ~7 — run.ex, recorder.ex, breaker.ex, health LiveView, kill actions/audit, observability_test.exs |

Deliberately left to implementers: exact Oban queue concurrency numbers; builder UX layout;
the active-trigger cache mechanism (§4.2 — an optimization, not a correctness surface);
`Automation` scope abbrev values (allocator-owned at build time, ADR-023).

## 13 · Rejected alternatives

- **Dispatch from the CDC pipe** — the CDC tier is the token-blind *analytics mirror*
  (ADR-015), batch-shaped and default-deny by projection; riding it couples tenant-facing
  latency/delivery semantics to an analytics surface and gives no transactional capture.
  The in-transaction Oban insert is exactly-once at capture and stays on the OLTP plane.
  (The *classification oracle* is shared — §4.4 — the pipe is not.)
- **A system/super actor for runs** — bypasses policies, breaks the T40 c3 red test, and
  makes automations a privilege-escalation vector. Owner-actor execution keeps every run
  inside the governed permission envelope.
- **Snapshot-based undo for update actions** — requires persisting prior attribute values,
  which may be PII; INV-1 outranks undo fidelity (§5.2 #4).
- **Compile-time AshOban triggers per tenant rule** — tenant cron is runtime data; the
  single next_fire_at scan trigger is the plain-Oban-compatible shape (§4.1).
- **ash_events for the run log** — rejected upstream (ADR-037 §5.5); outcomes-not-inputs is
  the INV-1-compatible log shape.
- **Freeform to-addresses on the email action** — a to-address is PII input flowing into an
  unattended sender; recipient selectors only this run, extension seam documented (§5.2 #2).

## 14 · Consequences

1. WS-E's Rules column closes on three adopted packages (reactor, ash_state_machine,
   ash_oban) + one ninth scope blueprint — no hand-built DAG executor, scheduler, or state
   machine.
2. SLA-breach and dunning attention unify onto one escalation primitive; their domain logic
   is untouched (adoption seams, §7.4) — future E5 clients (e.g. approval timeouts) get the
   chain walker for free.
3. One eligibility oracle now governs CDC projection, flag targeting, and automation
   predicates — a single place where "non-PII-keyable" is defined and verified.
4. Every automation fire is a recorded, attributable, killable run; the loop/rate guards
   make tenant-authored automation safe to expose by default.
5. New verifier/sabotage surface is added (§11); none is removed or weakened.

## 15 · References

- ADR-037 §5.5/§5.7/§5.8/§5.9/§5.13; ADR-038 (delivery chokepoint, ingress redaction);
  ADR-020 + `samen_core/lib/samen/feature_flags/target_rule.ex`; ADR-015 +
  `samen_core/lib/samen/cdc/projection.ex`; ADR-014/ADR-023/ADR-004.
- `samen_core/lib/samen/notifications/engine.ex` (host-wired seams, id-only envelopes);
  `samen_core/lib/samen/scopes/support/sla_breach_worker.ex`;
  `samen_core/lib/samen/billing/dunning.ex`.
- `spec/full-saas-readiness.md` §WS-E, INV-1..INV-6; `_orch/plan/spec-questions.md` c13;
  `_orch/tasks/{T39,T40,T41,T42}/handoff.md`.
