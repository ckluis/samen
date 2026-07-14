import Config

config :samen_core, SamenCore.TestRepo,
  username: System.get_env("USER") || "postgres",
  password: "",
  hostname: "localhost",
  database: "samen_core_test",
  pool: Ecto.Adapters.SQL.Sandbox,
  # pool_size 20 + queue slack: verify_vault_declared_parity opens direct
  # Postgrex connections outside the sandbox for DDL; under an unlucky seed the
  # concurrent checkout pressure hit the 4s queue timeout ~1-in-8 full runs
  # (WS-B B9 gate F1). Not a correctness issue — headroom kills the flake.
  pool_size: 20,
  queue_target: 200,
  queue_interval: 2_000

config :logger, level: :warning

# Gate-1 F1 red-path hook: the empty-registry exit-code test runs the pii_reads
# task in a child OS process with SAMEN_EMPTY_ASH_DOMAINS=1, which clears the
# discovered domains so the built PII registry is empty. This lets the test prove
# the task exits 1 (fail-closed) on a vacuous check rather than exit 0.
if System.get_env("SAMEN_EMPTY_ASH_DOMAINS") == "1" do
  config :samen_core, ash_domains: []
end

# test_helper.exs owns the Repo lifecycle (storage_up + migrate before connect).
config :samen_core, start_repo?: false

# Configure the verify_repo for mix samen.verify.column_refs in test.
config :samen_core, :verify_repo, SamenCore.TestRepo

# T1.7 erasure: the repo backing the non_pii! registry + erasure reports. The
# reveal-grant audit log the erasure path writes to uses :reveal_grant_repo
# (already configured in config/config.exs).
config :samen_core, :non_pii_repo, SamenCore.TestRepo

# T3.8 Tier-1 custom fields: the repo backing the `tnt_field` catalog + the
# validated-at-write change. Host apps configure their own; the change resolves
# the resource's AshPostgres repo first and falls back to :vault_repo.
config :samen_core, :vault_repo, SamenCore.TestRepo

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

# ADR-014 RP-D3 suppression fixture (test/support/suppression_fixture.ex) mounts the
# Marketing scope under `sx*` abbrevs to prove the kernel suppression check is portable.
# Its Subscriber declares the standard vault-routed `email` (column `pii_sxs_email`), so
# the column is a real vault promise — but the fixture domain is deliberately NOT in
# `:ash_domains` (kept out of the CI verifier/catalog sweeps), so `vault_declared_parity`
# cannot discover the route. Allow-list the pair: the route IS declared, just not on a
# registered domain. (catalog_parity is satisfied because catalog_sync catalogs it.)
config :samen_core, :vault_declared_parity_allow_list, [
  {"sxs_subscriber", "pii_sxs_email"},
  # WS-A A4 notifications engine fixture (test/support/notification_fixture.ex):
  # Notification.rendered_body is vault-routed (column pii_nen_rendered_body) but the
  # fixture domain is NOT in :ash_domains, so vault_declared_parity cannot discover
  # the route. The route IS declared — allow-list the pair (same posture as sx*).
  {"nen_notification", "pii_nen_rendered_body"},
  # Same fixture, same posture: the Primitives blueprint's Webhook declares the
  # vault-routed signing_secret (column pii_nwh_signing_secret), but the fixture
  # domain is NOT in :ash_domains so vault_declared_parity cannot discover the
  # route. The route IS declared — allow-list the pair.
  {"nwh_webhook", "pii_nwh_signing_secret"}
]

# T2.6 OTel test config: use the pid exporter so tests receive spans as messages
# and can assert on attributes inline. The simple processor sends spans
# synchronously (no buffer) so spans are delivered before the test assertion.
config :opentelemetry,
  span_processor: :simple,
  traces_exporter: {:otel_exporter_pid, self()}
