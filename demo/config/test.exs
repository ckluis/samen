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

# catalog_parity allow-list: the cnt_contact table has a non-Ash raw DDL column
# cnt_notes (the non_pii! reviewed plaintext column) added by migration.
config :demo, :catalog_parity_allow_list, [
  {"cnt_contact", "cnt_notes"},
  {"cnt_contact", "cnt_subject_id"}
]
