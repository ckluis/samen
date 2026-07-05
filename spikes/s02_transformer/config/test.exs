import Config

config :s02_transformer, S02Transformer.Repo,
  username: System.get_env("USER") || "postgres",
  password: "",
  hostname: "localhost",
  database: "samen_spike_s02_test",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10

config :logger, level: :warning

# test_helper.exs owns the Repo lifecycle (storage_up + migrate before connect).
config :s02_transformer, start_repo?: false
