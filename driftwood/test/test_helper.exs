# Driftwood test helper — mirrors demo/samen_core setup: fresh KMS key store per
# run, DB lifecycle, Oban, SQL sandbox.

alias Driftwood.Repo

kms_key_dir =
  Path.join(System.tmp_dir!(), "driftwood_keystore_test_#{System.system_time(:nanosecond)}")

File.rm_rf!(kms_key_dir)
Application.put_env(:samen_core, :kms_key_dir, kms_key_dir)
System.at_exit(fn _ -> File.rm_rf!(kms_key_dir) end)

_ = Ecto.Adapters.Postgres.storage_down(Repo.config())
:ok = Ecto.Adapters.Postgres.storage_up(Repo.config())

{:ok, _} = Repo.start_link()
Ecto.Migrator.run(Repo, :up, all: true)

# The `aud_event` migration creates only the FIXED launch-month (July 2026) partition; the daily
# `Samen.AuditEvent.PartitionManager` Oban job that rolls partitions forward in production never
# runs under the test harness. Ensure a partition for EVERY month from the launch month through two
# months ahead, as a production database has one for every month since launch: with only the
# current months, a test row stamped a day in the past failed on the 1st of each month (idempotent).
Samen.AuditEvent.PartitionManager.ensure_contiguous_partitions(Repo, Date.utc_today(), 2)

{:ok, _} = Oban.start_link(Application.fetch_env!(:samen_core, Oban))

Ecto.Adapters.SQL.Sandbox.mode(Repo, :manual)

# The adversarial suite (test/adversarial/, tagged :adversarial) is EXCLUDED from
# the default `mix test` run and driven as its OWN CI step (`mix test --only adversarial`).
ExUnit.configure(exclude: [:adversarial])

ExUnit.start()
