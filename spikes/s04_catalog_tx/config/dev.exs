import Config

config :s04_catalog_tx, S04CatalogTx.Repo,
  username: System.get_env("USER") || "postgres",
  password: "",
  hostname: "localhost",
  database: "samen_spike_s04_dev",
  pool_size: 10
