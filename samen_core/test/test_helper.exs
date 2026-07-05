# Create (idempotently) and migrate the samen_core test DB, then start the repo
# under the SQL sandbox. Mirrors the S0.2/S0.3 spike harness convention.

alias SamenCore.TestRepo

# Drop + create + migrate so the schema always matches the generated migrations.
_ = Ecto.Adapters.Postgres.storage_down(TestRepo.config())
:ok = Ecto.Adapters.Postgres.storage_up(TestRepo.config())

{:ok, _} = TestRepo.start_link()
Ecto.Migrator.run(TestRepo, :up, all: true)

Ecto.Adapters.SQL.Sandbox.mode(TestRepo, :manual)

ExUnit.start()
