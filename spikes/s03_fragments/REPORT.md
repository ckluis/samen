# S0.3 — Fragment single-table composition (spike report)

**Status: GREEN.** All acceptance criteria met; red path proven fail-closed.
Retires risk **R3** (fragment `base:` composition semantics unproven).

## What was built

Standalone mix project (`spikes/s03_fragments`) reusing the S0.2 abbrev storage
transformer verbatim and layering Spark fragment composition on top.

- **`Core.Person`** — a `Spark.Dsl.Fragment` of `Ash.Resource` (`extensions:
  [Samen.Pii, Samen.Catalog]`). Tableless bundle of shared attributes
  (`job_title`, `custom`) + a `pii do … end` section (`full_name`, `emails`,
  `phones`). No data layer, no table of its own.
- **`Samen.Pii`** — real Spark extension carrying the `pii` section + a
  `MaterializePii` transformer that turns each `pii_attribute` into a real column
  (S0.3-scoped stand-in for the S0.5 vault). `pii_attribute` fields are
  `sensitive?: true`.
- **`Samen.Catalog`** — no-op marker extension (fragment declares it; base macro
  must provide it) — gives the red-path gate a second extension to police.
- **`Samen.Resource`** — extended from S0.2 to accept `base: <fragment>`
  (→ Spark `fragments:`), inject the provided Samen extension allow-list
  (`Samen.Extension`, `Samen.Pii`, `Samen.Catalog`), and enforce the red-path gate.
- **`Clinical.Patient`** (`abbrev: "pat"`) + **`Clinical.Staff`** (`abbrev:
  "stf"`) — two resources, both `base: Core.Person`. Patient
  `belongs_to :primary_provider, Clinical.Staff`.

## Acceptance — evidence

| Criterion | Evidence |
|---|---|
| each composed resource = ONE physical table | Migration has exactly two `create table` calls: `pat_patient`, `stf_staff`. |
| the fragment has NO table | `Ash.Resource.Info.resource?(Core.Person) == false`; live `pg_inherits` empty. |
| fragment attributes inherit the composing resource's abbrev prefix | `:full_name` → `pat_full_name` on Patient, `stf_full_name` on Staff (job_title/custom/pii fields likewise). |
| belongs_to targets the Staff TABLE (real FK) | rel `destination == Clinical.Staff`; migration emits `references(:stf_staff, column: :stf_id)`. |
| generated DDL contains no `INHERITS` | (1) string scan of every migration for `/inherits/i`; (2) LIVE DB `SELECT count(*) FROM pg_inherits == 0`, both tables `relkind='r'`, `relhassubclass=false`. |

## RED PATH (must-fail) — proven fail-closed

`Samen.Resource, base: <fragment>` verifies every Samen-namespace extension the
fragment declares is provided by the base macro (allow-list: `Samen.Extension`,
`Samen.Pii`, `Samen.Catalog`). `RedPathFixtures.RogueFragment` declares
`[Samen.Pii, Samen.Audit]` where `Samen.Audit` is NOT provided → composing
resource raises `CompileError` at its own `use` line, naming `Samen.Audit`.

Load-bearing, not tautological:
- Spark itself would SILENTLY union the extra extension (`Spark.Dsl` ~line 332,
  `extensions |> Enum.concat(fragment_extensions)`). The gate is an explicit refusal.
- Anti-tautology control (passing): identical shape with `GoodFragment`
  (only-provided extensions) compiles AND folds its attribute in with the
  composer abbrev (`gud_note`). Red path fails for the right reason.
- Second red path: composed resource with no `abbrev` still fails compile.

## Test results

`MIX_ENV=test mix test` → **15 passed, 0 failed.** DB `samen_spike_s03_test`
(created/migrated by `test_helper.exs`). Our lib compiles with no warnings.

## Key findings (for the gate + ADR notes)

1. Fragment extensions are UNIONED, not validated, by Spark. The doc's "a
   fragment must declare the extension whose DSL it uses" rule is real but Spark
   enforces it permissively — a fragment can pull ANY extension into the composing
   resource. Samen needs its own allow-list gate in `Samen.Resource`; this is the
   mechanism the red path exercises and must carry into `samen_core` (A1).
2. Compile ordering: the gate calls `fragment.extensions/0` (defined at the
   fragment's `@before_compile`). `Code.ensure_loaded?/1` races; use
   `Code.ensure_compiled/1` to force the fragment to compile first.
3. `base:` → `fragments:` is a clean 1:1. No fight with AshPostgres codegen:
   `mix ash.codegen` emitted single-table DDL with prefixed columns + a real
   cross-table FK, no special handling. The S0.2 `after? BelongsToAttribute`
   ordering correctly prefixes the FK column on the composed resource.
4. PII stub vs S0.5: `pii_attribute` materializes a plain sensitive column here.
   Real vault split (pii_* table + token FK + ciphertext + crypto-shred) is S0.5.
   Doc composite types collapse to `:string`.
5. Sensitive fields NotLoaded by default after create — a fail-closed-by-omission
   preview of S0.5 masking; tests read PII back via `ensure_selected/2`.

## No-go / open items

None for R3 — composition works as designed. Carry-forward for `samen_core`: the
extension allow-list gate (finding 1) and the real vault (S0.5).
