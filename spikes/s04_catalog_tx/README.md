# s04_catalog_tx — Spike S0.4: catalog written in the migration transaction

Proves the doc's `BEGIN; ALTER TABLE …; INSERT INTO fld_field …; COMMIT` idiom:
when a migration adds a column, the `tam_table`/`fld_field` catalog rows are
written in the SAME Postgres transaction as the DDL — atomic and fail-closed.

Mechanism: a `Samen.Migration` wrapper macro (`use Ecto.Migration` + a
`catalog_sync/1,2` helper), chosen over a custom Ash codegen extension. Ecto
already runs each migration in one DDL transaction, so emitting the catalog
INSERTs from the same `up/0` gives the guarantee for free. See `REPORT.md`.

## Layout
- `lib/samen/migration.ex`  — the wrapper macro + `catalog_sync` (the mechanism)
- `lib/samen/catalog.ex`    — pure `Ash.Resource.Info` → catalog-row introspection
- `lib/samen/{resource,abbrev_storage}.ex` — reused from S0.2 (abbrev storage)
- `test/support/migrations.ex` — Bootstrap / AddPhone / AddPhoneCrashAfterDDL
- `test/catalog_tx_test.exs`    — acceptance tests incl. the RED PATH crash-injection
- `test/rollback_detail_test.exs` — scoped-rollback precision

## Run
```
mix deps.get
mix test          # 6 tests; creates samen_spike_s04_test on localhost:5432
```

RED PATH = `RED PATH: crash between DDL and catalog insert leaves NEITHER …`.
Verified non-tautological by an anti-tautology probe (disabling the DDL
transaction makes the assertion fail); see REPORT §anti-tautology.
