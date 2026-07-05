import Config

config :s04_catalog_tx, S04CatalogTx.Repo,
  username: System.get_env("USER") || "postgres",
  password: "",
  hostname: "localhost",
  database: "samen_spike_s04_test",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10

config :logger, level: :warning

# test_helper.exs owns the Repo lifecycle (storage_up before connect).
config :s04_catalog_tx, start_repo?: false
