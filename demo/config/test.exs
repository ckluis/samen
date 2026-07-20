import Config

config :demo, Demo.Repo,
  username: System.get_env("USER") || "postgres",
  password: "",
  hostname: "localhost",
  database: "demo_test",
  pool: Ecto.Adapters.SQL.Sandbox,
  # pool_size 20 + queue slack (mirrors samen_core config/test.exs, WS-B B9 gate F1 /
  # WS-F4 QA): the dogfood + verifier suite opens concurrent checkouts (incl. direct
  # Postgrex connections outside the sandbox for the parity DDL sweeps); the default 4s
  # queue timeout could hit checkout pressure under an unlucky seed. Headroom kills the
  # flake — not a correctness change.
  pool_size: 20,
  queue_target: 200,
  queue_interval: 2_000

config :logger, level: :warning

config :demo, start_repo?: false

# In test: manual mode (job rows visible but not auto-executed) + no plugins
# (cron/pruner don't run in test). This overrides the shared Oban config.
config :samen_core, Oban, testing: :manual, plugins: false

# NOTE (Gate-1 F3): the catalog_parity_allow_list moved to config/config.exs
# (shared) so `bash demo/ci.sh` is green in every env, not only :test.
