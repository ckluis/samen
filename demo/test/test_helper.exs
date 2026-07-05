# Demo dogfood app test helper (T1.9).
# Mirrors samen_core's test setup: fresh KMS key store per run, DB lifecycle,
# Oban, SQL sandbox.

alias Demo.Repo

# Per-run FileBacked KMS key store isolation (same reason as samen_core).
kms_key_dir =
  Path.join(System.tmp_dir!(), "demo_keystore_test_#{System.system_time(:nanosecond)}")

File.rm_rf!(kms_key_dir)
Application.put_env(:samen_core, :kms_key_dir, kms_key_dir)
System.at_exit(fn _ -> File.rm_rf!(kms_key_dir) end)

# Drop + create + migrate.
_ = Ecto.Adapters.Postgres.storage_down(Repo.config())
:ok = Ecto.Adapters.Postgres.storage_up(Repo.config())

{:ok, _} = Repo.start_link()
Ecto.Migrator.run(Repo, :up, all: true)

# Start Oban (same-tx auto-revoke).
{:ok, _} = Oban.start_link(Application.fetch_env!(:samen_core, Oban))

Ecto.Adapters.SQL.Sandbox.mode(Repo, :manual)

ExUnit.start()
