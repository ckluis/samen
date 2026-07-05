# s03_fragments — S0.3 spike: fragment single-table composition

Proves Spark `Spark.Dsl.Fragment` composition folds a shared fragment
(`Core.Person`) into multiple resources, each compiling to ONE physical table,
with fragment columns inheriting the composing resource's abbrev and real
cross-table FKs — never Postgres table inheritance.

Reuses the S0.2 abbrev storage transformer verbatim (`lib/samen/transformers/
abbrev_storage.ex`). See `REPORT.md` for the full acceptance evidence.

## Run

```
mix deps.get
MIX_ENV=dev mix ash.codegen initial_spike   # (already committed under priv/)
MIX_ENV=test mix test                        # 15 passing incl. red paths
```

Uses local Postgres (role = OS user, no password), DB `samen_spike_s03_test`
(created + migrated by `test/test_helper.exs`).

## Layout

- `lib/samen/resource.ex` — base macro: `base:` composition + fail-closed
  fragment-extension allow-list gate (RED PATH).
- `lib/samen/pii.ex` + `lib/samen/transformers/materialize_pii.ex` — the `pii do`
  section stub (materializes columns; real vault is S0.5).
- `lib/samen/catalog.ex` — marker extension.
- `test/support/core_person.ex` — the shared fragment.
- `test/support/{patient,staff}.ex` — the two composed resources.
- `test/composition_test.exs` — acceptance suite.
- `test/red_path_test.exs` — must-fail suite + anti-tautology control.
