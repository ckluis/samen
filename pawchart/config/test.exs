import Config

config :pawchart, PawChart.Repo,
  username: System.get_env("USER") || "postgres",
  password: "",
  hostname: "localhost",
  database: "pawchart_test",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10

config :logger, level: :warning

config :pawchart, start_repo?: false

# In test: manual Oban (job rows visible but not auto-executed) + no plugins.
config :samen_core, Oban, testing: :manual, plugins: false
