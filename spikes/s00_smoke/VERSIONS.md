# s00_smoke — Resolved Dependency Versions

Recorded: 2026-07-04
Elixir: 1.20.2 / OTP 29

## Direct dependencies

| Package      | Version |
|--------------|---------|
| ash          | 3.29.3  |
| ash_postgres | 2.10.0  |
| spark        | 2.7.2   |
| oban         | 2.23.0  |

## Transitive dependencies (full lock)

| Package      | Version    |
|--------------|------------|
| ash_sql      | 0.6.5      |
| crux         | 0.1.4      |
| db_connection | 2.10.1    |
| decimal      | 3.1.1      |
| ecto         | 3.14.0     |
| ecto_sql     | 3.14.0     |
| ets          | 0.9.0      |
| iterex       | 0.1.2      |
| jason        | 1.4.5      |
| multigraph   | 0.16.1-mg.4|
| postgrex     | 0.22.2     |
| reactor      | 1.0.2      |
| splode       | 0.3.1      |
| stream_data  | 1.3.0      |
| telemetry    | 1.4.2      |
| yamerl       | 0.10.0     |
| yaml_elixir  | 2.12.2     |
| ymlr         | 5.1.5      |

## Notes

All four target packages (Ash 3.x, ash_postgres, spark, oban) resolved and compiled
successfully against Elixir 1.20.2 / OTP 29. Only deprecation warnings from
upstream packages (yamerl, spark, multigraph) — no errors. `mix test` passes (2
tests: 1 doctest + 1 unit).
