# S0.6 test helper — recreates the spike DB fresh each run, then starts the
# repo. Tests run against real migrations (not the SQL sandbox for the migration
# tests). The catalog_parity check tests use the repo directly.

alias S06Verify.Repo

_ = Ecto.Adapters.Postgres.storage_down(Repo.config())
:ok = Ecto.Adapters.Postgres.storage_up(Repo.config())

{:ok, _} = Repo.start_link()

ExUnit.start()
