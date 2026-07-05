# Recreate the spike test DB fresh each run and start the repo. Unlike S0.2 this
# spike does NOT use the SQL sandbox: the whole point is to exercise real
# migration transactions (Ecto.Migrator opens its own connection + transaction),
# and the tests drive migrations up/down themselves. Each test resets the schema
# it needs. Migrations run against the live connection.

alias S04CatalogTx.Repo

_ = Ecto.Adapters.Postgres.storage_down(Repo.config())
:ok = Ecto.Adapters.Postgres.storage_up(Repo.config())

{:ok, _} = Repo.start_link()

ExUnit.start()
