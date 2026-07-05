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

# T1.7 erasure: the repo backing the non_pii! registry + erasure reports. The
# reveal-grant audit log the erasure path writes to uses :reveal_grant_repo
# (already configured in config/config.exs).
config :samen_core, :non_pii_repo, SamenCore.TestRepo

# Oban in :manual testing mode: `Oban.insert` writes the job row (so the same-tx
# enqueue and its rollback are observable), but queues do NOT auto-execute. The
# auto-revoke test drains the :reveal queue explicitly with
# `Oban.drain_queue/2`. This is what lets the crash test assert "no job row" and
# the auto-revoke test assert "job flips revoked_at".
config :samen_core, Oban, testing: :manual

# T1.8a catalog_parity allow-list: intentional columns that live in the DB but
# are NOT Ash resource attributes (so Samen.Catalog.fields/1 doesn't include them
# and catalog_sync never emitted fld_field rows for them). These are raw DDL
# columns added by migration-level code (the T1.7 erasure fixtures) that the
# erasure system reads directly. They are genuinely non-PII operational columns
# cleared at the migration level — not the T1.8c `non_pii!` review-gate flow.
config :samen_core, :catalog_parity_allow_list, [
  {"pat_patient", "pat_care_note"},
  {"pat_patient", "pat_subject_id"}
]
