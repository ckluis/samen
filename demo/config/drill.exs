import Config

# The T2.5 PITR game-day LOCAL SIMULATION environment.
#
# The drill orchestrator (docs/runbooks/pitr-gameday-sim.sh) creates and drops
# throwaway DBs and points this env at them via DRILL_DB. Nothing here touches
# demo_dev or demo_test. The repo pool is plain (NOT the SQL Sandbox) because the
# drill writes COMMITTED rows that must survive a pg_dump.
config :demo, Demo.Repo,
  username: System.get_env("USER") || "postgres",
  password: "",
  hostname: System.get_env("DRILL_PGHOST") || "localhost",
  port: String.to_integer(System.get_env("DRILL_PGPORT") || "5432"),
  database: System.get_env("DRILL_DB") || "samen_pitr_drill",
  pool_size: 4

config :logger, level: :warning

# The external KMS key dir — a directory OUTSIDE Postgres, never in any dump.
# The orchestrator points this at the live key dir for the base/expand/detect
# phases and at an EMPTY dir for the restore key-store-exclusion phase.
if dir = System.get_env("SAMEN_KMS_KEY_DIR") do
  config :samen_core, :kms_key_dir, dir
end

config :samen_core, :kms_adapter, Samen.Kms.FileBacked

# No Oban plugins in the drill (no cron/pruner) — the drill drives phases itself.
config :samen_core, Oban, testing: :manual, plugins: false

# Repo wiring the vault/erasure/reveal stack reads.
config :samen_core, :reveal_grant_repo, Demo.Repo
config :samen_core, :non_pii_repo, Demo.Repo
config :samen_core, :verify_repo, Demo.Repo
