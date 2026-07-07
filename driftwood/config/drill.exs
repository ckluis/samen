import Config

# T5.5 — PITR / reverse-migration GAME-DAY #2 LOCAL SIMULATION environment.
#
# The drill orchestrator (priv/gameday/pitr_gameday_sim.sh) creates and drops
# throwaway DBs (driftwood_pitr_drill_base / _restore) and points this env at them
# via DRILL_DB. Nothing here touches driftwood_dev or driftwood_test. The repo pool
# is a plain connection pool (NOT the SQL Sandbox): the drill writes a
# production-sized COMMITTED dataset that must survive a real pg_dump.
#
# This mirrors demo/config/drill.exs (the T2.5 machinery this game-day reuses),
# adapted for the Driftwood repo + domains.
config :driftwood, Driftwood.Repo,
  username: System.get_env("USER") || "postgres",
  password: "",
  hostname: System.get_env("DRILL_PGHOST") || "localhost",
  port: String.to_integer(System.get_env("DRILL_PGPORT") || "5432"),
  database: System.get_env("DRILL_DB") || "driftwood_pitr_drill_base",
  pool_size: 8

config :logger, level: :warning

# The external KMS key dir — a directory OUTSIDE Postgres, never in any pg_dump.
# The orchestrator points this at the live key dir for the base/expand/detect phases
# and at an EMPTY dir for the restore key-store-exclusion phase (T5.5 clause (c)).
if dir = System.get_env("DRIFTWOOD_KMS_KEY_DIR") do
  config :samen_core, :kms_key_dir, dir
end

config :samen_core, :kms_adapter, Samen.Kms.FileBacked

# The drill phase script starts the repo itself (mix run --no-start), so the OTP
# app must NOT auto-start the repo/web tree — no Endpoint, no port conflict, no
# Oban cron. Matches priv/gameday/crypto_shred_gameday.exs's boot pattern (T5.4).
config :driftwood, start_repo?: false

# No Oban plugins in the drill (no cron/pruner) — the drill drives phases itself.
config :samen_core, Oban, testing: :manual, plugins: false

# Repo wiring the vault/erasure/reveal + FMCSA-gate + non_pii stack reads (mirror of
# config.exs; re-declared here because config.exs's import_config picks drill.exs but
# these repo keys must resolve to Driftwood.Repo in the drill env too).
config :samen_core, :reveal_grant_repo, Driftwood.Repo
config :samen_core, :non_pii_repo, Driftwood.Repo
config :samen_core, :verify_repo, Driftwood.Repo
config :samen_core, :vault_repo, Driftwood.Repo
config :driftwood, :vault_repo, Driftwood.Repo
