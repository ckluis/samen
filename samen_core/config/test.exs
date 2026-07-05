import Config

config :samen_core, SamenCore.TestRepo,
  username: System.get_env("USER") || "postgres",
  password: "",
  hostname: "localhost",
  database: "samen_core_test",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10

config :logger, level: :warning

# test_helper.exs owns the Repo lifecycle (storage_up + migrate before connect).
config :samen_core, start_repo?: false

# Configure the verify_repo for mix samen.verify.column_refs in test.
config :samen_core, :verify_repo, SamenCore.TestRepo
