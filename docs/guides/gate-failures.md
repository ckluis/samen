# Gate-Failure Index

*Error message → which verifier fired → what it means → the fix* (WS-D D9 / AC-G10-4), for
every `samen.verify.*` verifier plus the gate's drift check. Every quoted error string below
is lifted from the verifier's source, and `samen_core/test/doc_recipes_test.exs` asserts (a)
every `samen_core/lib/mix/tasks/samen.verify.*.ex` task has an entry here and (b) each
quoted load-bearing string still exists in the cited source — the index cannot drift from
what the gate actually prints.

**The shared failure shape.** Sixteen of the seventeen verifiers report through
`Samen.Verifier.halt_if_violations/2` (`samen_core/lib/samen/verifier.ex`) and exit
non-zero via `:erlang.halt(1)`:

```text
FAIL: <task name> found N violation(s):
  • <violation>
```

On success each prints `<task name>: OK — no violations found.` Step numbers below are the
generated app's 18-step `ci.sh` (emitted by `mix samen.gen.app`); Driftwood's 20-step and
PawChart's 17-step gates run the same tiers in the same order.

---

## Step 1b — `schema.dict.json` drift check

**Error** (from the emitted `ci.sh`, `samen_core/lib/samen/gen/templates.ex`):

```text
FAILED: schema.dict.json is stale — run 'mix samen.catalog.dump --output schema.dict.json' and commit.
```

**Meaning:** the committed schema dictionary no longer matches what `mix samen.catalog.dump`
regenerates from the live catalog — you changed a resource/migration without re-baselining.
**Fix:**

```bash
mix samen.catalog.dump --output schema.dict.json
```

and commit the result. (If you did NOT intend a schema change, the diff printed under the
failure shows what drifted — revert that instead.)

---

## Step 2 — `mix samen.verify.catalog_parity`

**Errors** (`samen_core/lib/mix/tasks/samen.verify.catalog_parity.ex`):

```text
uncatalogued column: <table>.<column>
orphan fld_field row: <table>.<column>
ghost table: <table> (resource <Module> not in tam_table)
```

**Meaning:** the physical DB and the `tam_table`/`fld_field` catalog disagree — a migration
created a table/column without `catalog_sync`, or a catalog row outlived its DDL.
**Fix:** every migration must `use Samen.Migration`, end `up/0` with
`catalog_sync(@resources)` and start `down/0` with `catalog_sync_down(@resources)` — the
catalog writes ride the same transaction as the DDL (scope-authoring guide §8). For an
orphan row, remove it via the migration's down/`catalog_sync` pair, not by hand-editing.

---

## Step 3 — `mix samen.verify.prefixes`

**Errors** (`samen_core/lib/mix/tasks/samen.verify.prefixes.ex`):

```text
unprefixed column: <table>.<column> [expected prefix: <abbrev>_, resource: <Module>]
unprefixed fld_field row: <table>.<column> [expected prefix: <abbrev>_]
```

**Meaning:** a physical column (or its catalog row) does not carry the resource's reserved
3-letter abbrev prefix — the global column-naming invariant that makes every storage name
self-identifying.
**Fix:** name the column `<abbrev>_<name>` in the migration (scalar vault fields:
`pii_<abbrev>_<name>`). The abbrev is the one reserved for this resource in
`samen_core/priv/abbrev_registry.json`; `mix samen.gen.resource` gets this right by
construction.

---

## Step 4 — `mix samen.verify.pii_reads`

**Errors** (`samen_core/lib/samen/pii_reads/harness.ex`):

```text
PII LEAK  <file>:<line>  <sink>(...) <- :<pii_field>  [outside :reveal, <Module>]
PARSE ERR <file>:<line>  <message>
```

and the fail-closed refusal (`samen_core/lib/mix/tasks/samen.verify.pii_reads.ex`):

```text
FAIL: samen.verify.pii_reads refusing to run against an EMPTY PII registry (0 PII attributes discovered).
```

**Meaning:** source code passes a PII-declared attribute to a sink call (`Logger`,
telemetry, inspect-into-string, …) outside a declared `:reveal` action — a plaintext leak
path. `LAUNDERED …` lines are advisories only (never fail). The empty-registry refusal
means no PII resources were discovered at all — a vacuous check would pass every leak, so it
refuses instead of printing a misleading OK.
**Fix:** route the value through the resource's declared `reveal` action (under a grant), or
stop sinking it — log the bounded ID/token, not the field. For the refusal: configure
`ash_domains` so your PII resources are discoverable.

---

## Step 5 — `mix samen.verify.pii_classify`

**Error** (`samen_core/lib/samen/pii_classify.ex`):

```text
likely-PII column: <table>.<column> (<Module>, logical :<name>, type: :string) — <reasons>
```

**Meaning:** a NEW column (absent from the committed `schema.dict.json` baseline) is
plain-typed but its logical name matches the PII heuristic token-list
(email/ssn/dob/phone/name-ish/…) — you probably forgot the `pii do` vault declaration.
**Fix:** either vault it (cookbook Recipe 5: `pii_attribute` + `pii_<abbrev>_` column) or,
if it is genuinely not PII, register a reviewed `non_pii!` exemption. Then re-baseline with
`mix samen.catalog.dump`.

---

## Step 6 — `mix samen.verify.no_plaintext_pii`

**Errors** — violations print as `[<tier>] <subject> — <detail>` per surface tier
(`domain_rows`, `aud_event`, `audit_chain`, `trace_sink`, `oban_jobs`, `rollup`, `catalog`,
`log_telemetry`, `vault_declarations`; `samen_core/lib/samen/no_plaintext_pii/tier.ex`),
e.g. a domain row holding plaintext where a `vt_*` token must be. Registered exemptions
print as `[<tier>] EXEMPT (non_pii!): …` and do not fail. Mode misuse fails with
(`samen_core/lib/mix/tasks/samen.verify.no_plaintext_pii.ex`):

```text
samen.verify.no_plaintext_pii post-shred mode requires `--tiers all` (got ...).
```

**Meaning:** the at-rest oracle found plaintext PII on a surface that must carry only
tokens/bounded values — a write bypassed the `Samen.Vault.Change` chokepoint (raw SQL, a
seed not going through `Samen.Factory`, an un-vaulted 🔒 field). A tier that cannot
introspect its surface reports a violation too (never a silent pass).
**Fix:** write through the resource action path (the vault chokepoint) — for seeds, use the
`Samen.Factory.create!/3` idiom the generated `Seeds` module uses. If the flagged column is
truly non-PII, register `non_pii!` (exempt-but-listed). In post-shred (game-day) mode,
always pass `--tiers all` — a partial post-shred scan is not supported, fail-closed.

---

## Step 7 — `mix samen.verify.migrations`

**Errors** (`samen_core/lib/samen/migration/down_check.ex`):

```text
<Module> (v<version>): down/0 FAILED — <exception>. Every :expand migration must ship a tested, reversible down/0 (doc §runs 2b).
<Module> (v<version>): rolling down to v<n-1> did not roll back this expand (rolled ...) — check migration ordering / down/0.
<Module> (v<version>): re-apply after down did not re-run this migration (re-applied ...) — down/0 is not a clean round trip.
```

plus config failures: `migrations path does not exist: <path>` and
`no repo: pass --repo or set config :samen_core, :verify_repo`.
**Meaning:** an `:expand`-phase migration's `down/0` is missing, raises, or is not a clean
down→up round trip when exercised in a throwaway scratch DB (`<db>_downcheck_<rand>`).
`:contract`-phase migrations are covered by PITR, not `down/0`, and are skipped.
**Fix:** write the real reverse DDL in `down/0` (including `catalog_sync_down`), and keep
expand migrations additive so the reverse is possible. Never mark an expand migration
`:contract` just to dodge the check.

---

## Step 8 — `mix samen.verify.sink_schema`

**Errors** (`samen_core/lib/samen/wide_event/schema.ex`):

```text
field :<name> is typed :string — a FORBIDDEN (name-carrier) type. Wide-event/span fields must be one of [...] (bounded ID / token / enum / number). ...
enum field :<name> declares no closed `allowed:` set. ...
```

**Meaning:** the wide-event/span sink schema declares a field that could carry laundered
plaintext PII into the trace sink — a `:string`/`:binary`/`:map` name-carrier, or an enum
without a closed `allowed:` set.
**Fix:** retype the field as a bounded ID, token, closed enum or number; if you need a
label, make it a closed `allowed: [...]` enum. Free text never enters the sink schema.

---

## Step 9 — `mix samen.verify.metric_labels`

**Error** (`samen_core/lib/mix/tasks/samen.verify.metric_labels.ex` — its own format, not
the shared shape):

```text
[label-lint] FAIL:
  - <Module>: "<metric.name>" uses forbidden tag :org_id
Raw org_id/actor_id/subject_id labels cause unbounded Prometheus cardinality.
Use bounded labels: action, route, result, tenant_tier.
** (Mix) label-lint: forbidden metric tags found — exit 1
```

**Meaning:** a telemetry metric declares a raw per-entity tag (`org_id` / `actor_id` /
`subject_id`) — unbounded Prometheus label cardinality.
**Fix:** drop the tag or replace it with a bounded one (`action`, `route`, `result`,
`tenant_tier`). Per-org analysis belongs in the analytics tier, not metric labels.

---

## Step 9b — `mix samen.verify.oban_queues`

**Errors** (`samen_core/lib/mix/tasks/samen.verify.oban_queues.ex`):

```text
[oban-queue-parity] FAIL: queues enqueued to but NOT configured:
  - :webhooks_in <- Samen.Webhook.IngestWorker
Jobs on an unconfigured queue sit `available` FOREVER — no error, no retry, no DLQ.
Register the queue in Samen.Jobs.default_queue_config/0 (the single source of truth).
** (Mix) oban-queue-parity: unconfigured worker queues — exit 1

[oban-queue-parity] FAIL: discovered ZERO Oban workers.
A parity check that discovers nothing verifies nothing — this is a FAILURE, not a pass.
** (Mix) oban-queue-parity: empty discovery — exit 1
```

**Meaning:** a compiled `Oban.Worker` (hand-written, or one of the worker/scheduler
modules AshOban generates per `trigger`) enqueues to a queue that has no producer in
this app's resolved runtime Oban config. This never surfaces at runtime: `Oban.insert`
returns `{:ok, job}`, the row sits at `state = 'available'` forever, nothing claims it,
and the DLQ stays empty because nothing was ever attempted — so the enqueuing surface
(a webhook ingress answering 200, an operator "replay" button) reports success while the
work silently never happens.

**Fix:** add the queue to `Samen.Jobs.default_queue_config/0` — the single source of
truth. Do NOT add it to a host's `config :samen_core, Oban` `queues:` list: hosts derive
the taxonomy at boot through `Samen.Jobs.install_defaults/1`, and hand-maintained
per-host lists are what caused the drift this gate exists to prevent. A host may list a
queue ONLY to retune its limit (host limits win; omissions are backfilled).

The empty-discovery variant means the `Oban.Worker` introspection itself broke (e.g. a
dependency stopped emitting real worker modules). It fails closed on purpose: containment
over an empty set is trivially true, so a green line there would verify nothing.

---

## Step 13b — `mix samen.verify.erasure_completeness`

**Errors** (`samen_core/lib/mix/tasks/samen.verify.erasure_completeness.ex`):

```text
[erasure-completeness] FAIL: out-of-envelope residues with NO erasure arm:
  - UNREGISTERED derived-linkable column <table>.<col>_bidx (...): a `_bidx`-shaped blind index that is NOT in Samen.DerivedLinkable ...
  - UNREACHED derived-linkable column <table>.email_bidx (...): registered ... but NO :blind_index_erasure_specs entry covers it ...
  - UNREACHED storage_key blob on <resource> (...): NO :file_erasure_specs entry names this file_module ...
** (Mix) erasure-completeness: unreached residues — exit 1

[erasure-completeness] FAIL: discovered ZERO derived_linkable residues.
** (Mix) erasure-completeness: empty derived_linkable discovery — exit 1
```

**Meaning (ADR-046 §6):** `Samen.Erasure.shred/2` is a KEY-destruction job — it makes
every *vaulted* value undecryptable at once, but a plaintext-or-linkable value that lives
OUTSIDE the per-subject-DEK envelope is not reached by key destruction. This gate
DISCOVERS every such residue from the LIVE schema + registries (never `schema.dict.json`,
which grandfathers pre-existing columns — the exact mechanism that let `email_bidx` ship
un-erasable) and ASSERTS a registered `subject_id`-keyed arm reaches each:

- **derived-linkable (`_bidx`) columns** — blind indexes (keyed HMAC of PII) leave an
  equality oracle over the input space that survives a shred. Discovered via the
  `Samen.DerivedLinkable` marker registry plus the structural `_bidx` backstop; each must
  be registered there AND covered by a `:blind_index_erasure_specs` tombstone arm. An
  UNREGISTERED `_bidx` column fails — a new blind index cannot ship silently.
- **`storage_key` blobs** — raw file bytes. A subject-linked blob (the resource carries a
  data-subject field, e.g. `uploaded_by_id`) must be covered by a `:file_erasure_specs`
  blob-delete arm. An **org-asset** blob (no data-subject field, e.g. CRM `attachment` /
  CMS `media`) is NOT a per-subject-erasure residue; it is a NOTE-level org-lifecycle
  residual (deleted on row destroy / retention), named in the output, not gated.
- **`pii_declared`-capable `:custom` bags** — masking is automatic (the resolver reads
  every org's `tnt_field`) and erasure is guaranteed at the `define_field` chokepoint (a
  `pii_declared: true` field is REFUSED unless a `:custom_bag_erasure_specs` arm covers
  the table). The gate asserts both mechanisms are live.

**Fix:** register the missing arm framework-first, never per-host by hand. The specs are
DERIVED from each host's live schema by `Samen.Erasure.install_default_specs/1` (the
`Samen.Jobs.install_defaults/1` twin, called at `application.ex` boot), so a fresh
`gen.app` is complete by construction. A new blind index goes in `Samen.DerivedLinkable`
(logical name → owning-principal subject column); a new subject-linked file resource is
picked up automatically once it carries a recognized subject field.

The empty-discovery variant fails closed on purpose: `email_bidx` + `storage_key` columns
exist in every host that mounts identity + primitives, so an empty residue set is a broken
verifier (containment over an empty set is trivially true), never a green line.

---

## Step 10 — `mix samen.verify.vault_declared_parity`

**Errors** (`samen_core/lib/mix/tasks/samen.verify.vault_declared_parity.ex`):

```text
de-vaulted PII column: <table>.<column> matches the vault storage shape ...
FAIL: samen.verify.vault_declared_parity discovered ZERO resources — cannot verify vault parity. ... A vacuous parity check must not pass (fail-closed).
```

**Meaning:** a physical `pii_<abbrev>_*` column exists in the DB with no matching `pii do`
declared route on any resource — someone dropped the vault declaration while the column
survived (the *de-vault* defect; this verifier reads DB truth, so it catches free-text 🔒
fields the `pii_classify` heuristic cannot). The ZERO-resources refusal is the same
fail-closed anti-vacuity stance as `pii_reads`.
**Fix:** restore the `pii do` block (vault + `pii_attribute` + reveal), or if the field is
being removed for real, drop the column in a proper contract-phase migration. For the
refusal: fix `ash_domains` discovery.

---

## Step 11 — `mix samen.verify.tnt_catalog`

**Errors** (`samen_core/lib/mix/tasks/samen.verify.tnt_catalog.ex`):

```text
orphan tnt_field: org=<org> table=<table> field=<field> (table not in tam_table)
uncatalogued custom field: <table>.<key> (org=<org>, no tnt_field row)
orphan custom-object field: org=<org> object=<key> field=<field> ...
orphan tnt_record: org=<org> object=<key> (no tnt_object row)
```

**Meaning:** the Tier-1/Tier-2 tenant-malleability catalog (`tnt_*`) disagrees with reality
— a jsonb bag carries a custom-field key with no `tnt_field` row, or `tnt_*` rows point at
objects/tables that no longer exist.
**Fix:** custom fields/objects are only ever created through the governed Tier-1/Tier-2
write paths (which maintain `tnt_field`/`tnt_object` rows transactionally) — never write the
jsonb bag or the `tnt_*` tables directly. Repair by replaying the governed path or removing
the orphan through it.

---

## Step 12 — `mix samen.verify.tnt_boundary`

**Errors** (`samen_core/lib/mix/tasks/samen.verify.tnt_boundary.ex`):

```text
system resource <Module> declares relationship <name> ...
FK constraint <name> targets tenant-regime table <table> — no system ...
```

**Meaning:** a system-regime (operator-plane) resource or FK reaches across the two-plane
boundary into a tenant-regime table — the planes must stay referentially separate.
**Fix:** remove the cross-plane relationship/FK; cross-plane reads go through the sanctioned
interfaces (impersonation, the token-blind aggregate plane), never a direct FK.

---

## Step 13 — `mix samen.verify.same_org_fk`

**Error** (`samen_core/lib/mix/tasks/samen.verify.same_org_fk.ex`):

```text
<Module> declares belongs_to :<rel> → <Target> ... `change {Samen.Policy.SameOrgFk, relationships: [:<rel>, ...]}` — the scope-authoring guide §10 mandates a SameOrgFk guard on every org-scoped belongs_to FK (F3.5). ...
```

**Meaning:** a tenant-plane, org-scoped `belongs_to` FK has no `SameOrgFk` change guard — a
write could store a dangling cross-org reference.
**Fix:** add `change {Samen.Policy.SameOrgFk, relationships: [:<rel>]}` to the resource's
create/update actions (exactly what the error message prints).

---

## Step 14 — `mix samen.verify.no_pii_columns`

**Error** (`samen_core/lib/mix/tasks/samen.verify.no_pii_columns.ex`):

```text
aggregate-plane resource <Module> (table <table>) has physical column <col> matching the vault shape `pii_*`. ...
```

**Meaning:** the token-blind aggregate plane physically contains a vault-shaped column —
the aggregate tier must not be able to *hold* PII, by schema.
**Fix:** remove the column from the aggregate resource/migration; aggregates carry bounded
cohort keys and numeric value columns only.

---

## Step 14b — `mix samen.verify.no_pan_columns`

**Error** (`samen_core/lib/mix/tasks/samen.verify.no_pan_columns.ex`):

```text
resource <Module> declares attribute <attr>, which is PAN/CVC-shaped. No samen resource may EVER store a raw card number or a card security code (ADR-038 §3.5 B5 no-PAN invariant) ...
resource <Module> (table <table>) has PHYSICAL column <col> that is PAN/CVC-shaped. ...
```

**Meaning:** a resource (any plane) or a live table carries a column shaped like a raw card
number (PAN) or a card security code (CVC/CVV) — card-on-file must live exclusively in the
hosted billing provider's own vault (ADR-038 §3.5 B5); samen never stores a PAN.
**Fix:** remove/rename the attribute. Non-PAN display metadata (`brand`, `last4`,
`exp_month`, `exp_year`) is explicitly allowed and never flagged.

---

## Step 15 — `mix samen.verify.aggregate_privacy`

**Errors** (`samen_core/lib/mix/tasks/samen.verify.aggregate_privacy.ex`):

```text
aggregate-plane resource <Module> declares no fail-closed cohort ... k-anonymity / l-diversity floors (T4.5) cannot be enforced without one — every ...
aggregate-plane resource <Module>'s cohort spec has no cohort_count_column (k-anon needs a cohort size).
aggregate-plane resource <Module>'s cohort spec has empty value_columns (nothing to suppress when a floor fires).
```

**Meaning:** an aggregate-plane resource is missing its cohort spec (or the spec is
incomplete) — without a cohort count and value columns, the k-anonymity/l-diversity
suppression floors cannot fire, so small cohorts could be re-identified.
**Fix:** declare the full cohort spec on the aggregate resource: the cohort key, the
`cohort_count_column`, and the `value_columns` to suppress when a floor fires (see the
generated app's aggregate resource for the reference shape).

---

## Step 16 — `mix samen.verify.api_contract`

**Errors** (`samen_core/lib/samen/api_contract.ex`,
`samen_core/lib/mix/tasks/samen.verify.api_contract.ex`):

```text
route_dropped: <type> <METHOD> <path> was in the v1 contract but is no longer present — NOTE: semantic breaks ... are not caught by this structural diff ...
field_removed: <type>.<field> was in the v1 contract but is no longer exposed — ...
type_narrowed: <type>.<field> changed type from "<a>" to "<b>" — ...
Snapshot file not found: <path>
```

**Meaning:** the live `/api/v1` contract structurally broke against the committed
`api_contract.v1.json` — a route disappeared, an exposed field was dropped from
`show_fields`, or a field's type narrowed. Additions do not fail; un-versioned removals do.
**Fix:** if the break is intentional, version it consciously:

```bash
mix samen.verify.api_contract --version v1 --update
```

and commit the snapshot (reviewers see the break in the diff). Otherwise restore the
route/field (cookbook Recipe 6). A missing snapshot means the app was never baselined — run
the same `--update` once and commit.

---

## Step 18 — the anti-tautology probe

Not a `samen.verify.*` task: `mix run priv/anti_tautology_probe.exs` sabotages a real
mechanism (the generated app's vault path on `pii_<abbrev>_secret`) and FAILS if the gate
does *not* flip — proving the verifiers above are non-vacuous. If it fails with the gate
still green under sabotage, a verifier regressed: fix the verifier, not the probe.

---

## Off-gate verifiers

These two `samen.verify.*` tasks are not steps of the generated 18-step gate but are part of
the verifier suite (AC-G10-4 covers every task in `samen_core/lib/mix/tasks/`):

### `mix samen.verify.column_refs`

**Error** (`samen_core/lib/mix/tasks/samen.verify.column_refs.ex`):

```text
unknown storage column reference: <token> at <path>:<line>
```

**Meaning:** a freeform artifact (SQL fragment, projection, doc) references a physical
column name that does not exist in the catalog — the anti-hallucination check for
hand-written (or agent-written) storage references. Exercised by the samen_core suite
(`catalog_test.exs`, the agent-authoring eval) rather than a fixed gate step.
**Fix:** use the real abbrev-prefixed column name — introspect with `Samen.Catalog.fields/1`
or read `schema.dict.json`; never guess storage names.

### `mix samen.verify.never_read_current`

**Error** (`samen_core/lib/samen/cdc/never_read_current.ex`):

```text
read (<fun>/…) against the CDC analytics repo in a module NOT marked `@cdc_analytics_read true` — never read a 'current' value from the analytics tier (doc line 635). If this is a report, mark the module; otherwise read live truth from the primary repo.
```

**Meaning:** code reads a "current" value from the CDC analytics tier — eventually-consistent
analytics data must never be treated as live truth. With the CDC tier off (the default) the
task prints `Nothing to lint — never-read-current is vacuously satisfied (tier default off)`
and passes; Driftwood runs it as gate step 16b.
**Fix:** read live truth from the primary repo; if the module genuinely is an analytics
report, mark it `@cdc_analytics_read true` (an explicit, reviewable claim).

### `mix samen.verify.ai_prompt_masking`

**Errors** (`samen_core/lib/mix/tasks/samen.verify.ai_prompt_masking.ex`):

```text
<Module>: embeddable field <field> is vault-routed (🔒) — a vault-routed value must never enter vector space (grants never unlock embedding; ADR-043 §7.2). ...
<Module>: Prompt template <name> body contains a `vt_` vault-token sentinel — a committed template must never embed a raw vault FK token (ADR-043 §7.5).
```

**Meaning:** the D2 INV-7 (no-PII-egress) STRUCTURAL gate (ADR-043 §3.4, T65) — the
persisted-egress backstops: (b) a resource declared a vault-routed field embeddable (a vector
outlives any grant and is invertible, so vault values must never enter vector space — grants
never unlock embedding), or (c) a managed Prompt template body embeds a raw `vt_` vault token.
The RUNTIME half — the permanent canary red-team firing a PII canary through every egress class
EG1–EG6 (prompt, tool args, embedding, MCP, grounding, and the EG6 log/telemetry/error shadow),
RP-AI-9/10 — runs under `samen_core`'s `mix test` gate
(`samen_core/test/ai/ai_prompt_masking_test.exs`), sabotage-refutable via
`scripts/sabotages/44-d2-ai-egress-history-remask-bypass.patch` (the §3.2a per-turn history
re-mask) and `scripts/sabotages/45-t65-ai-egress-scrub-shape-blind-tuple-hole.patch` (the
§3.2 step-3 scrub ALLOWLIST — re-opening the tuple/keyword/map shape hole egresses a raw
`vt_*` token wrapped in EG2 tool args). Wired as
a demo/vertical `ci.sh` step (the root gate runs demo's `ci.sh`).
**Fix:** drop the vault-routed field from the embeddable set (or de-vault it); remove the raw
`vt_` token from the Prompt template body — a template must reference values by binding, resolved
+masked at egress by `Samen.AI.Chokepoint`, never embed a raw token.

### `mix samen.verify.agent_coverage`

**Errors** (`samen_core/lib/mix/tasks/samen.verify.agent_coverage.ex`):

```text
<file>: a `tool_schema/0`-exporting module (an agent-callable tool) calls `Samen.AI.Agent.start/run` — this reopens the raw-spawn recursion escape the F-4 static lock forbids (ADR-047 §10a row 19). ...
NON-VACUITY: discovery found ZERO `use Samen.AI.Agent` modules under any app lib/ ...
the agent-run resource Samen.AI.Agent.Run has NO derived `:shred` retention spec ...
<file>: a vertical `lib/` file references the `Samen.AI.Agent` kernel but is NEITHER an agent definition NOR a router ...
```

**Meaning:** the ADR-047 §9#6 coverage gate (batch A7) — the agent loop A1–A6 built is
self-defending. It scans the WHOLE umbrella tree from `samen_core` and asserts: (1) THE F-4
RAW-SPAWN AST LOCK — no `tool_schema/0` module may name `Samen.AI.Agent.start/run` (a tool that
cannot re-enter the loop cannot reopen the raw-spawn recursion escape, ADR-047 §10a row 19);
(2) every opted-in tool declares both callbacks and carries a test; (3) the agent-run resource
carries its `:shred` retention arm (§7.4); (4) a NON-VACUITY floor (≥1 agent + ≥1 opted-in
tool); (5) every agent ships an `AgentCase` proof; (6) the TREE-WIDE leverage guard (a vertical's
only kernel-referencing `lib/` files are its agent definitions + router). Wired into the ROOT
`ci.sh`, sabotage-refutable via `scripts/sabotages/268-a7-agent-coverage-f4-reentry-lock.patch`
(a tool that names `Agent.start` flips the gate red).
**Fix:** remove the `Samen.AI.Agent.start/run` call from the tool module (a tool proposes/reads,
never re-enters the loop); add the missing `AgentCase` proof / tool test / retention arm; move
re-implemented agent behaviour out of the vertical into the framework.

### `mix samen.verify.fleet_wire`

**Errors** (`samen_core/lib/mix/tasks/samen.verify.fleet_wire.ex`):

```text
field type <type> is not a member of Samen.WideEvent.Schema.bounded_types/0 ... — the fleet wire must never widen the inherited discipline
Samen.Fleet.Report.Schema.bounded_types/0 [...] is NOT a subset of Samen.WideEvent.Schema.bounded_types/0 [...]
<host> declares <sentinel> in :fleet_wire_catalogs but the list is empty or malformed ...
P8 smoke-check FAILED for <sentinel>: a label (...) that is NOT a member of the declared closed catalog [...] was ACCEPTED by Schema.validate/2 ...
route <VERB> <PATH> is mounted on <Router> but is NOT in Samen.Fleet.RouteTable.declared/0 (ADR-044 §4.4a) — an undeclared fleet route was added.
Samen.Fleet.RouteTable.declared/0 promises <VERB> <PATH> but <Router> does not mount it.
```

**Meaning:** ADR-044 §5.2 point 4 / §5.2b's "closed member list" premise (WS-J J2,
T84b) — three independent checks: (1) RP-J-4, the `FleetReport` wire's four-class
type discipline (`Samen.Fleet.Report.Schema.class_discipline_violations/0` — no
field of a text-carrying class can exist, so a PII value has nowhere to land) and
that the schema never WIDENS the inherited `Samen.WideEvent.Schema.bounded_types/0`
discipline; (2) P8 (`phase6-punchlist.md`) — a host that declares
`:fleet_wire_catalogs` (`Samen.Fleet.Report.Catalogs`) for one of the four closed-
catalog sentinels (`checks[].name` / `mrr_by_tier[].tier` / `oban[].queue` /
`activity_counts[].event_kind`) gets a LIVE smoke-check proving
`Samen.Fleet.Report.Schema.validate/2` actually REJECTS an out-of-catalog label,
not merely shape-checks it — an empty/malformed declared catalog fails outright; a
host that has not adopted cohort/catalog data at all is untouched (opt-in); (3)
RP-J-4b, the route-surface cross-check against `Samen.Fleet.RouteTable.declared/0`
(ADR-044 §4.4a + §5.3's tier-2 resolve routes) — only runs with `--router
MyAppWeb.Router`, skipped (not a violation) otherwise. Not wired into any
generated-app gate step (fleet cohorts are opt-in, ADR-044 §5.3); a host that
adopts the fleet wire runs it directly (`mix samen.verify.fleet_wire`), and
`samen_web/ci.sh` runs it against the framework's own test fixtures.
**Fix:** for (1), remove/replace the offending field type with one of
`:opaque_id`/`:token`/`:enum`/`:number`; for (2), populate the declared catalog
with the real per-vertical member list (or remove the empty declaration); for (3),
mount the missing route via `samen_fleet_routes`/`samen_operator_routes(...,
fleet_cockpit: true)`, or remove the undeclared one.
