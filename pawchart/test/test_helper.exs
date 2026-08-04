# PawChart test helper — mirrors demo/driftwood setup: fresh KMS key store per run,
# DB lifecycle, Oban, SQL sandbox.

alias PawChart.Repo

kms_key_dir =
  Path.join(System.tmp_dir!(), "pawchart_keystore_test_#{System.system_time(:nanosecond)}")

File.rm_rf!(kms_key_dir)
Application.put_env(:samen_core, :kms_key_dir, kms_key_dir)
System.at_exit(fn _ -> File.rm_rf!(kms_key_dir) end)

_ = Ecto.Adapters.Postgres.storage_down(Repo.config())
:ok = Ecto.Adapters.Postgres.storage_up(Repo.config())

{:ok, _} = Repo.start_link()
Ecto.Migrator.run(Repo, :up, all: true)

# The `aud_event` migration creates only the FIXED launch-month (July 2026) partition; the daily
# `Samen.AuditEvent.PartitionManager` Oban job that rolls partitions forward in production never
# runs under the test harness. Ensure the CURRENT + upcoming months' partitions so audit-writing
# tests never hit "no partition of relation aud_event" once the wall clock rolls past the launch
# month (forward-safe; the ensure is idempotent).
Samen.AuditEvent.PartitionManager.ensure_upcoming_partitions(Repo, Date.utc_today(), 2)

{:ok, _} = Oban.start_link(Application.fetch_env!(:samen_core, Oban))

Ecto.Adapters.SQL.Sandbox.mode(Repo, :manual)

ExUnit.start()
