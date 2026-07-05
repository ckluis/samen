# s02_transformer — Resolved Dependency Versions

Recorded: 2026-07-04
Elixir: 1.20.2 / OTP 29
Postgres: localhost:5432, role = OS user, no password

## Direct dependencies

| Package      | Version |
|--------------|---------|
| ash          | 3.29.3  |
| ash_postgres | 2.10.0  |
| spark        | 2.7.2   |

## Key transitive dependencies

| Package       | Version |
|---------------|---------|
| ash_sql       | 0.6.5   |
| ecto          | 3.14.0  |
| ecto_sql      | 3.14.0  |
| postgrex      | 0.22.2  |
| igniter       | (pulled transitively; ResourceGenerator emits harmless undefined-fn warnings) |

Lock file (`mix.lock`) copied from `s00_smoke` for a consistent Phase-0 pin.

## Notes

- The whole idiom rides on **one field**: `Ash.Resource.Attribute.source`
  (see `deps/ash/lib/ash/resource/attribute.ex:21,92`). AshPostgres uses
  `attribute.source` verbatim as the physical column name in the migration
  generator (`deps/ash_postgres/lib/migration_generator/operation.ex`), and
  the SQL data layer emits it in every WHERE/SELECT. Setting `source` in a
  compile-time transformer is therefore the entire mechanism — no AshPostgres
  fork needed.
- `mix compile --warnings-as-errors` is clean for this spike's own modules;
  the only warnings are upstream (`igniter`/`owl`/`yamerl`/`spark`/`multigraph`
  deprecations) and do not touch Samen code.
