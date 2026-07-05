import Config

config :demo, Demo.Repo,
  username: System.get_env("USER") || "postgres",
  password: "",
  hostname: "localhost",
  database: "demo_test",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10

config :logger, level: :warning

config :demo, start_repo?: false

config :samen_core, Oban, testing: :manual

# NOTE (Gate-1 F3): the catalog_parity_allow_list moved to config/config.exs
# (shared) so `bash demo/ci.sh` is green in every env, not only :test.
