import Config

# The test harness creates the DB and starts the repo explicitly.
config :s05_vault, start_repo: false

config :s05_vault, Samen.Repo,
  username: System.get_env("PGUSER", System.get_env("USER", "clank")),
  password: System.get_env("PGPASSWORD", ""),
  hostname: System.get_env("PGHOST", "localhost"),
  port: String.to_integer(System.get_env("PGPORT", "5432")),
  database: System.get_env("PGDATABASE", "samen_spike_s05_test"),
  pool_size: 10,
  # NOTE: NOT Ecto.Adapters.SQL.Sandbox. The PITR/pg_dump red path needs the
  # data to be really committed to disk so a physical `pg_dump` captures it.
  # Tests reset state explicitly via the Support helpers.
  pool: DBConnection.ConnectionPool

# The KMS key store lives OUTSIDE the Postgres data dir and outside the repo.
# A per-run tmp dir. This is the whole point of the PITR red path: pg_dump can
# never capture what lives here.
config :s05_vault,
  kms_key_dir: Path.join(System.tmp_dir!(), "samen_s05_keystore_test")

config :logger, level: :warning
