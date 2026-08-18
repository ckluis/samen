# Create (idempotently) and migrate the samen_core test DB, then start the repo
# under the SQL sandbox. Mirrors the S0.2/S0.3 spike harness convention.

alias SamenCore.TestRepo

# Fresh, per-run FileBacked KMS key store (T1.4 vault red paths). Without this,
# every `mix test` run shares `$TMPDIR/samen_core_keystore`, so stale subject
# tombstones/DEKs from a PRIOR run collide with a fresh run's reused
# `System.unique_integer/1` subject ids — a seed-dependent flake where
# `store_field` returns `{:error, :shredded}` because a stale tombstone exists.
# Isolating the key store per run makes the vault suite deterministic. (Test
# infra only — the FileBacked adapter and vault runtime are unchanged.)
kms_key_dir =
  Path.join(System.tmp_dir!(), "samen_core_keystore_test_#{System.system_time(:nanosecond)}")

File.rm_rf!(kms_key_dir)
Application.put_env(:samen_core, :kms_key_dir, kms_key_dir)
System.at_exit(fn _ -> File.rm_rf!(kms_key_dir) end)

# Drop + create + migrate so the schema always matches the generated migrations.
_ = Ecto.Adapters.Postgres.storage_down(TestRepo.config())
:ok = Ecto.Adapters.Postgres.storage_up(TestRepo.config())

{:ok, _} = TestRepo.start_link()

# T140: friendlier pgvector pre-check. The AI-embeddings migration (ADR-043 §7.1/M3) runs
# `CREATE EXTENSION vector`, which otherwise fails with an opaque "could not open extension
# control file .../vector.control" error on a server without pgvector. Fail early with a
# clear, actionable message instead. `pg_available_extensions` lists what CAN be installed
# (i.e. the control file is present) — the exact prerequisite the migration needs.
case TestRepo.query("SELECT 1 FROM pg_available_extensions WHERE name = 'vector'") do
  {:ok, %{num_rows: n}} when n >= 1 ->
    :ok

  _ ->
    IO.puts(:stderr, [
      "\n",
      "pgvector (CREATE EXTENSION vector) not installed — see ADR-043 §7.1.\n",
      "The samen_core AI-embeddings migration hard-requires the Postgres `vector` extension.\n",
      "Install it (e.g. `brew install pgvector`, or build 0.8.0 from source against your pg\n",
      "major) on the server backing SamenCore.TestRepo, then re-run.\n"
    ])

    System.halt(1)
end

Ecto.Migrator.run(TestRepo, :up, all: true)

# The `aud_event` migration creates only the FIXED launch-month (July 2026) partition; the daily
# `Samen.AuditEvent.PartitionManager` Oban job that rolls partitions forward in production never
# runs under the test harness. Ensure the CURRENT + upcoming months' partitions so audit-writing
# tests never hit "no partition of relation aud_event" once the wall clock rolls past the launch
# month (forward-safe; the ensure is idempotent).
Samen.AuditEvent.PartitionManager.ensure_upcoming_partitions(TestRepo, Date.utc_today(), 2)

# Start Oban (T1.6 same-tx reveal-grant auto-revoke) after the repo is up and
# migrated. In :manual testing mode (config/test.exs) queues do not auto-execute:
# `Oban.insert` writes the job row (so same-tx enqueue + rollback are observable)
# and tests drain the :reveal queue explicitly.
{:ok, _} = Oban.start_link(Application.fetch_env!(:samen_core, Oban))

Ecto.Adapters.SQL.Sandbox.mode(TestRepo, :manual)

# L4 (T90) multi-node Oban proof is OPT-IN: it boots real BEAM peer nodes against
# a dedicated non-sandbox DB (needs epmd + distribution), so it is excluded from
# the default fast suite. `SAMEN_MULTINODE=1 mix test` (the ci tier) includes it.
multinode_exclude =
  if System.get_env("SAMEN_MULTINODE") == "1", do: [], else: [:multinode]

ExUnit.start(exclude: multinode_exclude)
