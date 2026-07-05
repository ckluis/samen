# S0.4 — Catalog-in-Migration-Transaction — Spike Report

**Status:** `green`
**Date:** 2026-07-04
**Elixir 1.20.2 / OTP 29 · Ash 3.29.3 · ash_postgres 2.10.0 · spark 2.7.2 · ecto_sql 3.x · Postgres 14+ local**
**Risk retired:** R4 (catalog-in-migration-transaction has no native Ash codegen hook).

## Verdict

The doc's `BEGIN; ALTER TABLE …; INSERT INTO fld_field …; COMMIT — atomic ·
fail-closed` idiom is feasible and cheap, because Ecto already runs each
migration's `up/0`/`down/0` inside a single Postgres transaction on an adapter
that supports DDL transactions (Postgres does). Emitting the catalog `INSERT`s
from the same `up/0` as the DDL makes them literally the doc's one transaction —
no fork, no custom transaction plumbing. A crash injected between the DDL and the
catalog insert rolls back both, proven by the RED PATH test and verified
non-tautological by an anti-tautology probe (sabotage that disables the DDL
transaction makes the RED PATH assertion fail, as it must). All plan acceptance
criteria pass.

## Mechanism chosen: `Samen.Migration` wrapper macro (NOT a codegen extension)

The task asked to evaluate a custom Ash codegen extension vs a `Samen.Migration`
wrapper macro. Chosen: the wrapper macro.

- Codegen extension is intractable / high-surface. `mix ash.codegen` emits a
  closed set of DDL operations via ash_postgres's migration generator; it has no
  hook to interleave data rows (`INSERT INTO fld_field`). Adding one means forking
  `AshPostgres.MigrationGenerator`'s operation model — fragile against every
  ash_postgres release — and it still would not, by itself, give the transaction
  guarantee (that comes from Ecto, not codegen).
- The wrapper macro is a few dozen lines and gives the exact guarantee. Ecto
  already provides the transaction. `use Samen.Migration` = `use Ecto.Migration`
  plus a `catalog_sync/1,2` helper that diffs `Ash.Resource.Info` and emits the
  reversible catalog `execute` statements inside the current migration
  transaction.

Optional future enhancement (out of scope, noted for core): have `mix ash.codegen`
also generate the `catalog_sync(...)` call into the migration it writes, so
developers don't hand-write it — codegen as a convenience emitting the wrapper's
call, not codegen owning the transaction.

## What was built

- `Samen.Migration` — the wrapper macro. `use Samen.Migration` gives everything
  `Ecto.Migration` does plus:
  - `create_catalog_tables/0` — bootstrap `tam_table` / `fld_field`.
  - `catalog_sync/1` — reconcile a resource's full column set to `fld_field`
    inside the current tx (reverse deletes the whole resource's rows).
  - `catalog_sync/2` with `only: [:attr, …]` — scope to specific logical
    attributes so an additive "add one column" migration's `down` removes exactly
    that column's catalog row and leaves the table's other rows / `tam_table`
    entry intact.
  - All catalog writes are `execute(up_sql, down_sql)` (reversible) with
    `ON CONFLICT DO NOTHING` upserts; one `execute` per column so a mid-way
    failure still aborts the whole transaction.
- `Samen.Catalog` — pure introspection: turns a resource into `tam_table` /
  `fld_field` row descriptions keyed on the abbrev-prefixed storage name
  (`attribute.source`, from the reused S0.2 transformer), plus logical name and
  type. Purity is what lets the acceptance test assert "catalog == introspection"
  by comparing DB rows to `Samen.Catalog.fields/1` directly.
- Reused verbatim from S0.2: `Samen.Resource` base macro +
  `Samen.Transformers.AbbrevStorage` (so introspection yields `com_*` storage
  names that the catalog records).
- Fixtures: `S04CatalogTx.Crm.Contact` (`abbrev: "com"`) and three migration
  modules (`Bootstrap`, `AddPhone`, `AddPhoneCrashAfterDDL`).

## Acceptance results (plan task S0.4)

| Criterion | Result | Evidence (test) |
|---|---|---|
| migrate adds column + catalog row atomically | PASS | `atomic add: migration adds the column AND its catalog row together` |
| catalog contents match `Ash.Resource.Info` introspection | PASS | `catalog contents match Ash.Resource.Info introspection after add` — DB `fld_field` rows `==` `Samen.Catalog.fields/1`; `com_phone` row = `{com_phone, phone, String}` |
| rollback removes both | PASS | `rollback removes BOTH the column and the catalog row`; `RollbackDetailTest` proves scoped rollback removes only `com_phone`, leaves the 3 bootstrap rows + `tam_table` entry |
| RED PATH: crash between DDL and catalog insert leaves NEITHER | PASS (fail-closed proven) | `RED PATH: crash between DDL and catalog insert leaves NEITHER column NOR catalog row` |

Full suite: 6 passed.

### RED-path fail-closed verification (anti-tautology)

The RED-path test runs `AddPhoneCrashAfterDDL`, which `add`s `com_phone`,
`flush()`es the DDL, then `raise`s before `catalog_sync`. It asserts the raise
propagates and then that neither the column nor any `com_phone` catalog row
survived.

To prove this is not tautological, a sabotaged probe migration identical except
for `@disable_ddl_transaction true` was run: with the DDL transaction disabled the
`ALTER` commits before the crash, the column survives, and the assertion
`refute column_exists?("com_contact", "com_phone")` FAILS — confirming the
guarantee test passes only because DDL and catalog write share one transaction.
Probe removed after verification; main suite green (6 passed).

## Findings / caveats carried forward to core

- F1 — the transaction is Ecto's, and only exists on `@disable_ddl_transaction
  false` (the default). Any migration that legitimately disables it
  (`CREATE INDEX CONCURRENTLY`, chunked backfills — plan K2 carve-outs) cannot use
  in-transaction catalog coupling. Core must make `catalog_sync` REFUSE to run
  under `@disable_ddl_transaction true` (fail closed) rather than silently write a
  catalog row outside a transaction. Not yet enforced in the spike — top core
  follow-up.
- F2 — `catalog_sync/1` (unscoped) reconciles the WHOLE resource; its reverse
  deletes the whole resource's catalog rows. Correct for bootstrap / full-table
  migrations, wrong for additive single-column migrations. The spike resolves this
  with `catalog_sync(res, only: […])`; core should have codegen always scope the
  emitted call to the columns that migration changed.
- F3 — the catalog diff is driven by `Ash.Resource.Info` at migration compile
  time, not by the DDL in the migration file, so the `catalog_sync` column list
  must be kept in step with the `add`/`remove` DDL. The C1 `catalog_parity`
  verifier (S0.6) is the required backstop (checks `information_schema` ⇄
  `fld_field` both directions).
- F4 — SQL is string-built from developer-controlled identifiers (module /
  attribute / table names), single-quote-escaped defensively; never user input.
  Core should prefer parameterized inserts / Ecto fragments once the catalog
  tables are real Ash resources.
- F5 — catalog tables are plain Ecto tables here, not `use Samen.Resource`
  resources, to avoid a bootstrap chicken-and-egg. Core will model
  `tam_table`/`fld_field` as real resources and decide whether they self-catalog.

## How to reproduce

```
cd spikes/s04_catalog_tx
mix deps.get
mix test               # 6 tests incl. the RED PATH (creates samen_spike_s04_test)
```
