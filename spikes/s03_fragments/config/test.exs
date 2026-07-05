import Config

config :s03_fragments, S03Fragments.Repo,
  username: System.get_env("USER") || "postgres",
  password: "",
  hostname: "localhost",
  database: "samen_spike_s03_test",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10

config :logger, level: :warning

# test_helper.exs owns the Repo lifecycle (storage_up + migrate before connect).
config :s03_fragments, start_repo?: false
