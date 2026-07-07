import Config

config :driftwood, Driftwood.Repo,
  username: System.get_env("USER") || "postgres",
  password: "",
  hostname: "localhost",
  database: "driftwood_test",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10

config :logger, level: :warning

config :driftwood, start_repo?: false

# T5.4 crypto-shred game-day: pin the FileBacked KMS keystore to a fixed directory
# when `DRIFTWOOD_KMS_KEY_DIR` is exported. The game-day driver seeds+shreds a real
# driver in ONE process, then shells out to `mix samen.verify.no_plaintext_pii
# --subject … --tiers all` as a SEPARATE process (the real auditor CLI contract).
# Both must read the SAME wrapped-DEK/tombstone store or the oracle's KMS
# attestation would see a fresh (never-keyed) store and mis-report :absent. Exporting
# this env var makes both processes share the store. Unset in the ordinary test
# suite → the test_helper's per-run temp keystore is used unchanged.
if dir = System.get_env("DRIFTWOOD_KMS_KEY_DIR") do
  config :samen_core, :kms_key_dir, dir
end

# In test: manual Oban (job rows visible but not auto-executed) + no plugins.
config :samen_core, Oban, testing: :manual, plugins: false
