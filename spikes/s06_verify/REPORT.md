# S0.6 — Verifier Harness + `catalog_parity` v0 — Spike Report

**Status:** `green`
**Date:** 2026-07-04
**Elixir 1.20.2 / OTP 29 · Ash 3.29.3 · ash_postgres 2.10.0 · spark 2.7.2 · ecto_sql 3.x · Postgres 14+ local**
**Risk addressed:** verifier harness pattern (plan §C; C1 = `catalog_parity`).

## Verdict

The mix-task harness pattern is viable and the `catalog_parity` verifier proves it
against both directions of the column ⇄ `fld_field` invariant. All plan S0.6
acceptance criteria pass, including both red-path (must-fail) checks and the
exit-code layer (System.cmd-driven subprocess tests). 9/9 tests pass.

## Mechanism

### Harness pattern (`Samen.Verifier`)

Each verifier follows three steps:

1. **Introspect** — gather facts from the DB (`information_schema`, `fld_field`,
   `tam_table`) and/or from compiled resources (`Ash.Resource.Info`).
2. **Check** — compute violations as a plain list of human-readable strings.
3. **Report** — `Samen.Verifier.halt_if_violations/2` prints diagnostics then
   calls `:erlang.halt(1)` directly, bypassing cleanup hooks, so no rescue/catch
   can swallow the non-zero exit code.

`check/1` is factored out from the `Mix.Task` callback so tests can call it
directly without triggering `:erlang.halt/1` in the test VM. Exit-code assertions
use `System.cmd/3` in a child OS process, giving a true end-to-end exit-code test.

### `catalog_parity` (`Mix.Tasks.Samen.Verify.CatalogParity`)

Queries two scopes:

- **Physical columns** — `information_schema.columns` for tables listed in
  `tam_table` (Samen-managed tables only; ignores unmanaged tables so the verifier
  can run on a partial schema without noise).
- **Catalogued columns** — `fld_field` rows for the same managed tables.

Computes the symmetric difference:

- `physical − catalogued` → "uncatalogued column: table.column"
- `catalogued − physical` → "orphan fld_field row: table.column"

All violations are reported together before exit so a single run surfaces all
problems, not just the first one.

### Repo lifecycle in the subprocess

The mix task calls `Mix.Task.run("app.start")` then calls
`ensure_repo_started!/1` which does `repo.start_link([])`, tolerating
`{:error, {:already_started, pid}}`. This means the task works in both:

- Normal dev/CI runs (Application supervisor already started the repo).
- Test subprocess spawned by System.cmd (Application has `start_repo?: false`
  because the test_helper owns the lifecycle; the task starts the repo directly).

## What was built

- `lib/samen/verifier.ex` — `Samen.Verifier.halt_if_violations/2`: the harness
  print-and-halt entry point.
- `lib/samen/tasks/catalog_parity.ex` — `Mix.Tasks.Samen.Verify.CatalogParity`:
  the C1 verifier. `run/1` drives the task; `check/1` is the pure violation
  computer (callable from tests without triggering halt).
- `lib/samen/abbrev_storage.ex`, `lib/samen/resource.ex`, `lib/samen/catalog.ex`,
  `lib/samen/migration.ex` — reused verbatim from S0.4 (no changes).
- `test/support/contact.ex` — `S06Verify.Crm.Contact` (`abbrev: "com"`).
- `test/support/migrations.ex` — three migration modules:
  - `Bootstrap` — creates catalog tables + `com_contact` with all columns
    catalogued correctly (green baseline).
  - `AddUncataloguedColumn` — adds `com_phone` to the physical table WITHOUT
    calling `catalog_sync` (red-path fixture 1).
  - `InsertOrphanCatalogRow` — inserts a `fld_field` row for `com_old_field`
    which does not exist in the physical table (red-path fixture 2).

## Acceptance results (plan task S0.6)

| Criterion | Result | Evidence |
|---|---|---|
| Parity passes on a correctly-catalogued spike app | PASS | `parity passes when storage and catalog are in sync` |
| RED PATH: uncatalogued column fails with exit 1; diagnostic names the column | PASS | `RED PATH: uncatalogued column produces a violation naming the column` + `mix task exits 1 with diagnostic when uncatalogued column present` |
| RED PATH: orphan `fld_field` row fails with exit 1; diagnostic names the row | PASS | `RED PATH: orphan fld_field row produces a violation naming the row` + `mix task exits 1 with diagnostic when orphan fld_field row present` |
| Diagnostics name the offending column/row | PASS | Violations include table AND column name: `"uncatalogued column: com_contact.com_phone"` |
| Mix task exits 0 on clean DB (no false positives) | PASS | `mix task exits 0 when catalog is in sync` |
| Violations clear after rollback | PASS | Two rollback-and-recheck tests |

Full suite: **9 passed**.

## Test anti-tautology notes

The red-path tests are non-tautological by construction:

- `AddUncataloguedColumn` deliberately omits `catalog_sync` — the DDL runs but no
  catalog row is written. The verifier catches the gap because it independently
  reads both `information_schema` and `fld_field`; the test would fail if the
  verifier returned no violations.
- `InsertOrphanCatalogRow` inserts a `fld_field` row for a column never added to
  the physical table. The verifier catches this because `information_schema` returns
  no such column.
- The exit-code layer runs in a child OS process via `System.cmd/3`; the child
  actually calls `:erlang.halt(1)` which the parent observes as a process exit
  code, not an exception — impossible to fake.

## Findings / caveats carried forward to core

- **F1 — tam_table scope.** The verifier only checks tables listed in `tam_table`.
  If a Samen resource is migrated but its `tam_table` row is missing, the verifier
  silently skips it. Core should add a separate check: every resource known to
  `Ash.Resource.Info` appears in `tam_table`.
- **F2 — information_schema skips system columns.** The query naturally excludes
  Postgres system columns (`ctid`, `xmin`, etc.), which is correct. If
  ash_postgres emits shadow columns outside the abbrev scheme (e.g. from
  AshCloak), those would appear as uncatalogued violations. Core must document
  which physical columns are intentionally excluded and teach the verifier an
  allow-list.
- **F3 — Repo lifecycle in the task.** The `ensure_repo_started!/1` fallback
  works for the spike but is fragile in multi-repo apps. Core should accept
  `--repo` as a task arg or discover repos from `Application.get_env(otp_app,
  :ecto_repos)`.
- **F4 — Diagnostic quality.** Violations currently name `table.column` pairs.
  Future iterations should also print the owning resource module name (from
  `tam_table`) to help developers find the right file.

## How to reproduce

```
cd spikes/s06_verify
mix deps.get
mix test               # 9 tests incl. all RED PATHs and exit-code layer
```
