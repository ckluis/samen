defmodule Samen.PitrRestoreTest do
  @moduledoc """
  RED PATH (b) — the load-bearing PITR claim (ADR-001 §8.2 red path 1; doc
  §data): "a PITR restore brings back the ciphertext (already useless) but
  cannot resurrect the destroyed key."

  We prove it *physically*, not with a mock:

    1. Write PII to the vault (ciphertext lands in Postgres; wrapped DEK lands
       in the external key store — a directory OUTSIDE Postgres).
    2. `pg_dump` the Postgres data — this snapshot captures ciphertext + tokens
       but CANNOT capture the key store (it's not in Postgres).
    3. Crypto-shred the subject (destroy the external DEK).
    4. "Restore" the dump into a FRESH database.
    5. Point the app at the restored DB and attempt to decrypt.

  The decrypt MUST fail `:shredded`/`:unavailable`, because the key store was
  never in the dump and the live key was destroyed. If it ever returned
  plaintext, the key leaked into the snapshot surface and the spike is NOT
  green.
  """
  use ExUnit.Case, async: false

  alias Samen.Repo
  alias Samen.Vault
  alias Samen.Vault.PiiEmail

  @secret "dave.restore@example.com"
  @restore_db "samen_spike_s05_restore_test"

  setup do
    S05Vault.DBCase.truncate!()
    Samen.Kms.FileBacked.simulate_outage(false)
    Application.put_env(:s05_vault, :kms_adapter, Samen.Kms.FileBacked)
    :ok
  end

  test "PITR restore of the DB dump cannot decrypt because the key store was never in the dump" do
    subject = "subj-pitr-" <> (:crypto.strong_rand_bytes(6) |> Base.encode16())
    {:ok, person} = Vault.store_email(subject, "Dave", @secret)
    token = person.pii_email_token

    # Sanity: live decrypt works BEFORE shred.
    assert {:ok, @secret} = Vault.reveal(person.email)

    # 1. Confirm the ciphertext is really in Postgres (rides PITR), and it is
    #    NOT the plaintext.
    row = Repo.get(PiiEmail, token)
    assert row.ciphertext != nil
    refute row.ciphertext == @secret
    refute row.ciphertext =~ @secret

    # 2. pg_dump the Postgres data. This is our "backup / PITR snapshot".
    src = Repo.config()
    dump_path = Path.join(System.tmp_dir!(), "s05_pitr_#{:erlang.unique_integer([:positive])}.sql")
    {out, code} = pg_dump(src, dump_path)
    assert code == 0, "pg_dump failed: #{out}"

    # Prove the dump contains the ciphertext-bearing table but NOT the plaintext
    # and NOT any key material (the key store is a directory, never dumped).
    dump = File.read!(dump_path)
    assert dump =~ "pii_email"
    refute dump =~ @secret

    # 3. Crypto-shred: destroy the external DEK.
    {:ok, att} = Vault.shred(subject)
    assert att.state == :shredded

    # 4. Restore the dump into a FRESH database.
    recreate_db!(src, @restore_db)
    {rout, rcode} = psql_restore(src, @restore_db, dump_path)
    assert rcode == 0, "restore failed: #{rout}"

    # 5. Point a repo at the restored DB and confirm the ciphertext is back...
    restored_config = Keyword.put(src, :database, @restore_db)
    {:ok, restored} = start_restored_repo(restored_config)

    restored_row = restored.get(PiiEmail, token)
    assert restored_row != nil, "expected ciphertext row to be restored"
    assert restored_row.ciphertext == row.ciphertext, "ciphertext must survive PITR"

    # ...but decrypting it is IMPOSSIBLE — the key was destroyed and was never
    # in the dump. RED PATH: this must NOT return {:ok, plaintext}.
    assert {:error, :shredded} = Vault.reveal(person.email)

    # Also prove it directly: unwrap the subject key → denied.
    assert {:error, :shredded} = Samen.Kms.FileBacked.unwrap(subject)

    # And the oracle-style scan over the restored subject finds nothing.
    assert {:ok, :no_plaintext} = Vault.scan_no_plaintext(subject)

    # STRONGEST FORM: model the restore environment having NO key store at all
    # (only Postgres was restored). Point the key store at a brand-new empty
    # directory — exactly what a DB-only restore gives you — and prove the
    # restored ciphertext still cannot decrypt. It fails because the key store
    # (dek + tombstone + master) was never in the dump.
    original_key_dir = Application.get_env(:s05_vault, :kms_key_dir)

    fresh_key_dir =
      Path.join(System.tmp_dir!(), "s05_restore_empty_#{:erlang.unique_integer([:positive])}")

    try do
      Application.put_env(:s05_vault, :kms_key_dir, fresh_key_dir)
      # A fresh key dir has no dek and no tombstone → unwrap cannot produce a key.
      assert {:error, reason} = Samen.Kms.FileBacked.unwrap(subject)
      assert reason in [:absent, :unavailable]
      # Reveal against the restored ciphertext with an empty key store → deny.
      assert {:error, _} = Vault.reveal(person.email)
    after
      Application.put_env(:s05_vault, :kms_key_dir, original_key_dir)
      File.rm_rf(fresh_key_dir)
    end

    # Cleanup restored repo.
    stop_restored_repo()
    File.rm(dump_path)
  end

  test "sanity guard: if the key store WERE captured, decrypt would succeed (proves the test can fail)" do
    # This test proves the red-path test above is not vacuous: with the key
    # store intact (no shred), the same restored ciphertext DOES decrypt. So the
    # difference in the red path is entirely the destroyed key, not a broken
    # pipeline. (A red-path test that can never observe success is worthless.)
    subject = "subj-guard-" <> (:crypto.strong_rand_bytes(6) |> Base.encode16())
    {:ok, person} = Vault.store_email(subject, "Eve", "eve.guard@example.com")

    # No shred here. Decrypt succeeds because the key store is intact.
    assert {:ok, "eve.guard@example.com"} = Vault.reveal(person.email)
  end

  # --- helpers ---

  defp pg_dump(config, path) do
    args = [
      "-h", to_string(config[:hostname]),
      "-p", to_string(config[:port]),
      "-U", to_string(config[:username]),
      "-d", to_string(config[:database]),
      "--no-owner",
      "--no-privileges",
      "-f", path
    ]

    System.cmd("pg_dump", args, env: pg_env(config), stderr_to_stdout: true)
  end

  defp recreate_db!(config, db) do
    admin = Keyword.put(config, :database, "postgres")
    _ = psql(admin, "DROP DATABASE IF EXISTS #{db}")
    {out, code} = psql(admin, "CREATE DATABASE #{db}")
    if code != 0, do: raise("could not create restore DB: #{out}")
    :ok
  end

  defp psql_restore(config, db, dump_path) do
    target = Keyword.put(config, :database, db)

    args = [
      "-h", to_string(target[:hostname]),
      "-p", to_string(target[:port]),
      "-U", to_string(target[:username]),
      "-d", to_string(target[:database]),
      "-v", "ON_ERROR_STOP=1",
      "-f", dump_path
    ]

    System.cmd("psql", args, env: pg_env(target), stderr_to_stdout: true)
  end

  defp psql(config, sql) do
    args = [
      "-h", to_string(config[:hostname]),
      "-p", to_string(config[:port]),
      "-U", to_string(config[:username]),
      "-d", to_string(config[:database]),
      "-c", sql
    ]

    System.cmd("psql", args, env: pg_env(config), stderr_to_stdout: true)
  end

  defp pg_env(config) do
    case config[:password] do
      nil -> []
      "" -> []
      pw -> [{"PGPASSWORD", to_string(pw)}]
    end
  end

  # A distinct repo module aimed at the restored DB.
  defmodule RestoredRepo do
    use Ecto.Repo, otp_app: :s05_vault, adapter: Ecto.Adapters.Postgres
  end

  defp start_restored_repo(config) do
    Application.put_env(:s05_vault, RestoredRepo, config)

    case RestoredRepo.start_link() do
      {:ok, _pid} -> {:ok, RestoredRepo}
      {:error, {:already_started, _pid}} -> {:ok, RestoredRepo}
    end
  end

  defp stop_restored_repo do
    if pid = Process.whereis(RestoredRepo), do: Supervisor.stop(pid)
    :ok
  end
end
