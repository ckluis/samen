# LLM-grounding workflow — how an agent authors a resource on Samen

**Audience:** an LLM agent (or the human driving one) that authors a new resource,
field, or scope on a Samen host — and anyone who needs to understand *why* an
agent's wrong is bounded here instead of shipped. This is task **T6.3** (plan §7
Phase 6). It generalizes the substrate claim the vision doc makes in
["Software an agent builds"](../samen-foundry.txt) (:921–:923):

> Ask an LLM to build a SaaS from a blank schema and it invents a `users` table,
> guesses `status` is a string, hand-rolls a dunning state machine, pastes an
> email into a free-text column… Every one is a place the model can be wrong — and
> silently is. **Samen removes the blank page.** Every object and field is in the
> catalog, so the agent grounds on a known model. … A schema hallucination fails at
> compile time, net-new PII is caught by `mix samen.verify.pii_classify` before it
> merges, and a CI linter rejects any reference to a column that isn't catalogued —
> a hallucinated field doesn't compile.

The mechanism this guide documents has two halves:

1. **Grounding** — the agent reads `schema.dict.json`, a committed, resource-qualified,
   PII-flagged data dictionary. It is the ground the agent grounds on and *cannot
   invent off of*.
2. **The authoring loop** — the agent writes a change, then runs the fail-closed
   verifier gate. **The gate is the agent's correctness oracle**: a hallucinated
   column, net-new plaintext PII, an unprefixed column, a leaked vault value, or a
   missing cross-tenant guard each fails the build with an *actionable* diagnostic,
   not a silent bug.

A **runnable eval** proves this end-to-end:
`samen_core/test/agent_authoring_eval_test.exs` seeds six agent-authoring changes
(one correct, five wrong) and asserts the gate's exact exit behavior on each. See
§4.

---

## 1 · The grounding artifact: `schema.dict.json`

Every host commits a `schema.dict.json` at its project root, generated
deterministically by `mix samen.catalog.dump` (plan B3). It is the machine-readable
projection of the catalog (`tam_table` / `fld_field`) — the same catalog the
verifiers key on, so **what the agent grounds on and what the gate enforces are the
same source of truth.**

### Shape

```json
{
  "tables": [
    {
      "table_name": "per_person",
      "resource": "Demo.CrmScope.Person",
      "fields": [
        { "column_name": "per_full_name", "logical_name": "full_name", "type": "Samen.Type.VaultField", "pii": true },
        { "column_name": "per_id",        "logical_name": "id",        "type": "UUID", "pii": false },
        { "column_name": "per_org_id",    "logical_name": "org_id",    "type": "UUID", "pii": false }
      ]
    }
  ]
}
```

Each field carries four keys the agent needs:

| key | what it is | why the agent needs it |
|---|---|---|
| `column_name` | the **physical storage name** — globally self-qualifying (`per_full_name` carries the `per` abbrev) | the name that appears in the DB, CDC, logs, and raw SQL — never collides or drifts across a rename |
| `logical_name` | the **catalog / API field name** the agent writes Ash against (`:full_name`) — resource-scoped, NOT globally unique | what the agent puts in `Ash.Query`/`attribute`/policy code |
| `type` | the declared type (`UUID`, `Atom`, `Samen.Type.VaultField`, …) | so the agent never "guesses `status` is a string" |
| `pii` | **boolean** — is this field vault-routed PII? | so the agent routes the field through the vault + `:reveal`, never lands it in the clear (T6.3) |

### The two names, and which identity is unambiguous

The doc is precise about this (:923), and the agent must be too:

- The **physical storage column** (`column_name`) is globally self-qualifying —
  `per_full_name` carries its resource abbrev, so a stored column name never
  collides or drifts. There is genuinely no "which table's `per_status`?" question
  *at the storage layer*.
- The **catalog / API field name** (`logical_name`, e.g. `:status`, `:name`) is
  **resource-scoped, not globally unique** — two resources can each have a
  `:status`. So the agent disambiguates not by a bare field name but by the
  **resource-qualified catalog entry**: the `(table_name, resource)` pair + the
  `logical_name` under it names exactly one field on exactly one resource.

"No which-table ambiguity" is therefore the catalog's *resource-qualified entry*
doing the work, plus the self-qualifying storage name it maps to — not a fiction
that a bare `:status` is globally unique.

### The `pii` flag keys on the DECLARATION, not the name

`pii` is `true` iff the field is vault-routed (declared in a `pii do … end` block),
computed via `Samen.Pii.Info.vault_routed_columns/1` — **not** by matching a `pii_`
name prefix. This matters for two shapes:

- A **composite** PII field like `per_full_name` carries the resource abbrev with
  **no `pii_` prefix** — but it is vault-routed, so `"pii": true`. An agent keying
  on the name prefix would wrongly treat it as non-PII; keying on the flag is
  correct.
- A **scalar** PII field like `pii_drv_cdl_number` carries the `pii_` prefix and is
  also `"pii": true`.

This is the same declaration-not-name rule the `pii_reads` and `no_plaintext_pii`
verifiers use — so the agent's grounding and the gate's enforcement agree.

### How the agent consumes it

The agent reads `schema.dict.json` **before writing any code** and uses it to:

1. **Resolve a real field.** To read a person's name, the agent looks up
   `Demo.CrmScope.Person` → `full_name` (`per_full_name`, `pii: true`) — it does
   not invent `person.name` or guess a storage name.
2. **Route PII correctly.** Seeing `pii: true`, the agent knows the field's normal
   value is `%Masked{}` and plaintext is reachable only through the declared
   `:reveal` action under a grant — so it never writes `Logger.info(person.full_name)`.
3. **Refuse to hallucinate.** A field not in the dict does not exist. If the agent
   needs a new field, it *adds* it (a resource change + migration + `catalog_sync`)
   and regenerates the dict — it does not reference a name that isn't there.

The dict requires **no live DB** to read — it is a committed file — so an agent can
ground on the full model from the repo alone.

---

## 2 · The authoring loop: add a resource → run the gate → the gate is the oracle

The agent's workflow for a new resource / field / scope:

```
  read schema.dict.json  →  author the change  →  run the verifier gate  →  the gate
     (ground truth)          (native Ash)          (the correctness oracle)   is green?
        ▲                                                    │  no
        └──────────────  fix the named violation  ◀──────────┘
```

### Step 1 — ground

Read `schema.dict.json`. Reuse existing resource-qualified names; know which fields
are PII.

### Step 2 — author (native Ash, the scope-authoring pattern)

Follow [`scope-authoring.md`](./scope-authoring.md): `use Samen.Resource, abbrev:
"abc"`; org-scope policy; `pii do … end` for 🔒 fields with a `reveal :action`;
`change {Samen.Policy.SameOrgFk, relationships: […]}` on every `belongs_to`; a
migration ending in `catalog_sync(@resources)`; then regenerate the dict:
`mix samen.catalog.dump` and commit it.

### Step 3 — run the gate (the oracle)

The gate is the §runs CI pipeline (see any host's `ci.sh`). Each step is a
`mix samen.verify.*` task that exits **non-zero** on a violation
(`Samen.Verifier.halt_if_violations/2` calls `:erlang.halt(1)` — no cleanup hook
can swallow it). The load-bearing steps for an agent-authored change:

| verifier | catches | the agent's mistake it bounds |
|---|---|---|
| `catalog_parity` | a physical column with no `fld_field` row (and the reverse; ghost tables) | added a column to the DDL but forgot to catalog it — the "hallucinated field" bug class |
| `prefixes` | a physical column missing its resource abbrev | hand-wrote a bare column name, breaking self-qualifying storage |
| `pii_classify` | a NEW plain-typed `:string`/`:date` column that looks like PII | wrote `attribute :ssn, :string` — plaintext PII at rest |
| `pii_reads` | a vault-routed value reaching a log/span/sink outside `:reveal` | logged a name/CDL/email in the clear |
| `no_plaintext_pii` | plaintext PII in any projected tier; `db_statement` left enabled | leaked PII into a rollup / trace |
| `same_org_fk` | an org-scoped `belongs_to` with no `SameOrgFk` guard | opened a dangling cross-tenant FK |

**The gate IS the oracle.** The agent does not need a human to review whether it
hallucinated a column or landed PII in the clear — the build tells it, with a
diagnostic that names the offending item and (for `prefixes`) the expected fix.
Green means the change composes on idioms the substrate can verify; a non-zero exit
means the agent's wrong is *caught before it merges*, not shipped.

### Step 4 — fix and re-run

The diagnostics are actionable by design (they name the column, the resource, the
expected prefix, the leaked field). The agent fixes the named item and re-runs until
the gate is green.

---

## 3 · What the gate does NOT catch (the honest boundary)

The oracle is fail-closed but not omniscient. An agent (and its operator) must know
the residues:

- **`pii_classify` is a heuristic, not a proof.** It flags PII-shaped *names*
  (`ssn`/`dob`/`cdl`/`email`/…) and PII-shaped sample values. A non-obvious PII
  name it doesn't recognize is the `non_pii!` review gate's job (a distinct second
  reviewer), not the scanner's. It is flag-on-hit, not assume-all-strings-PII.
- **`pii_reads` is a dataflow match, not a sound taint proof.** It catches *direct*
  flows of a vault-declared value into a sink. A value laundered through a helper is
  the **sink-schema allow-list**'s job (`sink_schema` / `no_plaintext_pii`), not the
  AST walker's — the layered design is the accepted mitigation (plan C3).
- **`prefixes` / `catalog_parity` are storage/catalog checks, not
  semantic ones.** They prove a name exists and is prefixed and catalogued; they do
  not prove the agent used the *right* field for the business meaning. (A hallucinated
  *attribute* reference in Ash source is caught earlier still — it fails to compile via
  the Spark DSL verifiers under `--warnings-as-errors`. The former source-text
  `column_refs` linter was retired — ADR-045 A3 — as redundant with these two guards.)
- **The gate bounds correctness of the substrate idioms, not the agent's domain
  logic.** Settlement math, a dispatch gate, a clinical workflow — those the agent
  writes natively and tests itself; the substrate makes the *infrastructure* wrong
  bounded, not the *domain* wrong.

None of these is silently swallowed: each is a named posture, and the eval (§4)
documents which verifier owns which case.

---

## 4 · The agent-authoring eval (the proof)

`samen_core/test/agent_authoring_eval_test.exs` is a runnable eval that models "an
agent authored these changes" and drives each through the SAME `check/*` /
`violations/*` / `scan/*` entry point the mix task runs before halting. It asserts
the gate's exact exit behavior on six seeded cases:

| # | seeded wrong | owning verifier | expected exit |
|---|---|---|---|
| 1 | a **correct** resource (vaulted PII, guarded FK, no leak) | the whole gate | **exit 0** (passes) |
| 2 | a hallucinated / uncatalogued column | `catalog_parity` | exit 1 |
| 3 | net-new plaintext PII (`attribute :ssn, :string`) | `pii_classify` | exit 1 |
| 4 | an unprefixed physical column | `prefixes` | exit 1 |
| 5 | a vault value logged outside `:reveal` | `pii_reads` | exit 1 |
| 6 | a `belongs_to` with no `SameOrgFk` guard | `same_org_fk` | exit 1 |

Each seeded change is applied to a **scratch host** — the `SamenCore.TestRepo`
fixture DB (in-sandbox, rolled back) for the DB-backed cases (2, 4), or a
project-local scratch source dir / source string for the source-scan cases (2, 5),
or an introspection-only fixture resource for the compile-time cases (3, 6).

Case 1 is the **non-vacuous positive control**: the substrate does not merely fail
an agent's wrong — it *passes* an agent's right. Case 2 is also driven through a
**real `System.cmd/3` child OS process** to observe the true `:erlang.halt(1)` exit
code end-to-end (exit 1 on the seeded wrong, exit 0 on the clean host).

The eval scores every case against a rubric (`@rubric`) and its own final test
asserts all six score `:pass`. **Cases 2–6 are the eval's red paths** (must-fail),
case 1 is the must-pass control. An **anti-tautology probe** (documented in the test
moduledoc, run in a project-local scratch backup) sabotaged `pii_classify.check/3`
to fail open; case 3 flipped from caught to uncaught (surgically — cases 1/2/4/5/6
stayed green), then was reverted byte-identical. That proves case 3 exercises the
real gate, not a tautology.

Run it:

```
cd samen_core && MIX_ENV=test mix test test/agent_authoring_eval_test.exs --include exit_code
```

---

## 5 · Grounding-artifact sufficiency (part c)

**Claim:** `schema.dict.json` is a *sufficient* grounding artifact — an agent can
ground on the entire model (every resource, every field, every PII flag,
resource-qualified) from that one file, with no live DB and no separate
introspection call.

**What "sufficient" requires, and where each is verified:**

| requirement | how it's satisfied | verified by |
|---|---|---|
| **every resource present, resource-qualified** | each table carries `resource` (the module) + `table_name` (the physical table) | `mix samen.verify.catalog_parity` — the committed dict must match the migrated catalog (the host `ci.sh` drift check regenerates + diffs) |
| **every field present** | every attribute becomes a field entry with `column_name` + `logical_name` | `Samen.Catalog.fields/1` maps every `Ash.Resource.Info` attribute; the dict drift check fails if the file is stale |
| **PII flag present per field** | every field carries a boolean `pii`, keyed on the vault declaration | `samen_core/test/catalog_test.exs` — "every field entry carries a boolean `pii` flag" + "the `pii` flag keys on the vault DECLARATION for BOTH composite and scalar PII" (asserts composite `pat_full_name` and scalar `pii_pat_mrn` are both `pii:true`, non-PII `pat_id`/`pat_org_id` are `pii:false`, and that BOTH true and false appear — an anti-vacuity guard) |
| **resource-qualified** | the two-name model (self-qualifying `column_name` + resource-scoped `logical_name` under a named `resource`) disambiguates a bare field name | §1 above; enforced by `prefixes` (self-qualifying storage) + `catalog_parity` (resource ↔ `tam_table`) |
| **committed + drift-free** | the file is committed and CI fails if it diverges from the code | every host `ci.sh` runs `mix samen.catalog.dump` into a temp file and diffs against the committed copy |

The PII flag was **added in T6.3** (`mix samen.catalog.dump` now emits `pii` per
field). Before T6.3 the dict carried resource + field + type but not the PII flag,
so an agent had to make a *separate* introspection call to learn a field's PII
status; now the artifact is self-contained. All three host dicts
(`demo/schema.dict.json`, `driftwood/schema.dict.json`, `pawchart/schema.dict.json`)
were regenerated and committed with the flag, and each host's drift check confirms
the committed file matches the code.

**Honest residue:** the dict intentionally does NOT carry the *vault name* a PII
field routes to, the `reveal` action name, or the malleability-ladder tier — those
are introspection-available (`Samen.Pii.Info`) but out of scope for the grounding
artifact, which answers "what fields exist and which are PII", not "how the vault is
wired". An agent that needs the reveal-action name reads the resource; the grounding
claim is bounded to schema + PII, which is exactly what removes the blank page.
