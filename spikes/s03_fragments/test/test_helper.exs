# Create (idempotently) and migrate the spike test DB, then start the repo
# under the SQL sandbox. Each spike owns its own database per the spikes README.

alias S03Fragments.Repo

# Drop + create + migrate so the schema always matches the generated migrations.
_ = Ecto.Adapters.Postgres.storage_down(Repo.config())
:ok = Ecto.Adapters.Postgres.storage_up(Repo.config())

{:ok, _} = Repo.start_link()
Ecto.Migrator.run(Repo, :up, all: true)

Ecto.Adapters.SQL.Sandbox.mode(Repo, :manual)

ExUnit.start()
