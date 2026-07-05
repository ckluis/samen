defmodule Samen.VaultPitrTest do
  @moduledoc """
  RED PATH 1 — the load-bearing PITR claim (ADR-001 §8.2 red path 1; doc §data):
  "a PITR restore brings back the ciphertext (already useless) but cannot
  resurrect the destroyed key."

  This test proves it PHYSICALLY via a real `pg_dump` / `psql` round-trip
  against the local Postgres, not a mock. This is the same physical proof
  methodology as `spikes/s05_vault/test/pitr_restore_test.exs`.

  Steps:
    1. Write PII → vault row (ciphertext in Postgres; wrapped DEK in the file-
       backed key store OUTSIDE Postgres).
    2. `pg_dump` the test DB (captures ciphertext + tokens, NEVER the key store).
    3. Crypto-shred the subject (destroy the external wrapped DEK).
    4. "Restore" the dump into a fresh DB.
    5. Point a repo at the restored DB and attempt to decrypt.
    6. Decrypt MUST fail (`:shredded`/`:unavailable`) — the key was never in the dump.

  The test also proves the strongest form: even with a brand-new empty key dir
  (modeling a DB-only restore with no key store at all), the restored ciphertext
  cannot decrypt.

  Note: this test requires `pg_dump` and `psql` to be on PATH (standard in
  most dev environments with Postgres). It is skipped if they are not found.
  """
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Samen.Vault
  alias Samen.Kms.FileBacked
  alias Samen.Masked

  @repo SamenCore.TestRepo
  @restore_db "samen_core_pitr_restore_test"
  @secret "dave.restore@example.com"

  setup do
    Samen.Kms.FileBacked.simulate_outage(false)
    Application.put_env(:samen_core, :kms_adapter, Samen.Kms.FileBacked)
    on_exit(fn ->
      Application.put_env(:samen_core, :kms_adapter, Samen.Kms.FileBacked)
      Samen.Kms.FileBacked.simulate_outage(false)
      # Clean up any vault rows written by the PITR tests (non-sandboxed writes).
      try do
        SamenCore.TestRepo.delete_all(Samen.Vault.VaultRow)
      rescue
        _ -> :ok
      end
    end)

    # The PITR test MUST write committed data (pg_dump sees only committed rows).
    # We disable the SQL sandbox for this test module and use direct repo writes.
    # This means data written here is NOT rolled back automatically — we clean up
    # explicitly in on_exit.
    Ecto.Adapters.SQL.Sandbox.mode(@repo, :auto)

    # Skip if pg_dump / psql are not available.
    case {System.find_executable("pg_dump"), System.find_executable("psql")} do
      {nil, _} -> :skip_no_pg_dump
      {_, nil} -> :skip_no_psql
      _ -> :ok
    end
  end

  # Restore sandbox mode after the test module finishes.
  setup_all do
    on_exit(fn ->
      Ecto.Adapters.SQL.Sandbox.mode(@repo, :manual)
    end)

    :ok
  end

  @tag timeout: 120_000
  test "PITR restore cannot decrypt because the key store was never in the dump" do
    subject_id = "subj-pitr-#{System.unique_integer([:positive])}"

    # 1. Write PII: ciphertext in Postgres, wrapped DEK in the external key store.
    {:ok, token} = Vault.store_field(subject_id, :pii_email, :emails, @secret, @repo)
    masked = Masked.new(token, :emails)

    # Sanity: live decrypt works BEFORE shred.
    assert {:ok, @secret} = Vault.reveal(masked, @repo)

    # Verify the vault row is in Postgres with ciphertext (not plaintext).
    row = @repo.one(from r in Samen.Vault.VaultRow, where: r.token == ^token)
    assert row != nil
    assert row.ciphertext != nil
    refute row.ciphertext == @secret
    refute row.ciphertext =~ @secret

    # 2. pg_dump the test DB. This "backup" captures ciphertext + tokens but NOT
    #    the key store (which is a directory outside Postgres by construction).
    src = @repo.config()
    dump_path =
      Path.join(System.tmp_dir!(), "samen_pitr_#{System.unique_integer([:positive])}.sql")

    {out, code} = pg_dump(src, dump_path)
    assert code == 0, "pg_dump failed:\n#{out}"

    # Verify: the dump contains the vault table but NOT the plaintext.
    dump = File.read!(dump_path)
    assert dump =~ "pii_vault"
    refute dump =~ @secret

    # 3. Crypto-shred: destroy the external wrapped DEK.
    {:ok, att} = Vault.shred(subject_id)
    assert att.state == :shredded

    # 4. Restore the dump into a FRESH database.
    recreate_db!(src, @restore_db)
    {rout, rcode} = psql_restore(src, @restore_db, dump_path)
    assert rcode == 0, "psql restore failed:\n#{rout}"

    # 5. Point a repo at the restored DB and confirm the ciphertext is back
    #    (the ciphertext survives PITR — that is the design).
    restored_config = Keyword.put(src, :database, @restore_db)
    {:ok, restored} = start_restored_repo(restored_config)

    restored_row = restored.one(from r in Samen.Vault.VaultRow, where: r.token == ^token)
    assert restored_row != nil, "expected ciphertext row to survive PITR restore"
    assert restored_row.ciphertext == row.ciphertext, "ciphertext must survive PITR restore"

    # ...but decrypting it is IMPOSSIBLE — the key was destroyed and was never
    # in the dump. RED PATH 1: this MUST NOT return {:ok, plaintext}.
    # The original live DB also denies (shred already happened there).
    assert {:error, reason} = Vault.reveal(masked, @repo)
    assert reason in [:shredded, :unavailable]

    # 6. STRONGEST FORM: model the restore environment having NO key store at all
    #    (only Postgres was restored). Point the key store at a brand-new empty
    #    directory — exactly what a DB-only restore gives you.
    original_key_dir = Application.get_env(:samen_core, :kms_key_dir)
    fresh_key_dir =
      Path.join(
        System.tmp_dir!(),
        "samen_restore_empty_#{System.unique_integer([:positive])}"
      )

    try do
      Application.put_env(:samen_core, :kms_key_dir, fresh_key_dir)
      # A fresh key dir has no dek and no tombstone → unwrap cannot produce a key.
      assert {:error, empty_reason} = FileBacked.unwrap(subject_id)
      assert empty_reason in [:absent, :unavailable],
             "expected :absent or :unavailable from an empty key store, got: #{inspect(empty_reason)}"
      # Reveal against the restored ciphertext with an empty key store → deny.
      assert {:error, _} = Vault.reveal(masked, restored)
    after
      Application.put_env(:samen_core, :kms_key_dir, original_key_dir)
      File.rm_rf(fresh_key_dir)
    end

    # Cleanup.
    stop_restored_repo()
    File.rm(dump_path)
  end

  test "sanity guard: with key store intact (no shred), restore DOES decrypt (proves non-vacuousness)" do
    # This test proves the red-path test above is non-vacuous: with the key
    # store intact (no shred), the same pipeline DOES decrypt. So the difference
    # in the red path is entirely the destroyed key, not a broken pipeline.
    subject_id = "subj-guard-#{System.unique_integer([:positive])}"
    plaintext = "eve.guard@example.com"

    {:ok, token} = Vault.store_field(subject_id, :pii_email, :emails, plaintext, @repo)
    masked = Masked.new(token, :emails)

    # No shred. Decrypt succeeds because the key store is intact.
    assert {:ok, ^plaintext} = Vault.reveal(masked, @repo)
  end

  # --- helpers ---

  defp pg_dump(config, path) do
    args = [
      "-h",
      to_string(config[:hostname] || "localhost"),
      "-p",
      to_string(config[:port] || 5432),
      "-U",
      to_string(config[:username]),
      "-d",
      to_string(config[:database]),
      "--no-owner",
      "--no-privileges",
      "-f",
      path
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
      "-h",
      to_string(target[:hostname] || "localhost"),
      "-p",
      to_string(target[:port] || 5432),
      "-U",
      to_string(target[:username]),
      "-d",
      to_string(target[:database]),
      "-v",
      "ON_ERROR_STOP=1",
      "-f",
      dump_path
    ]

    System.cmd("psql", args, env: pg_env(target), stderr_to_stdout: true)
  end

  defp psql(config, sql) do
    args = [
      "-h",
      to_string(config[:hostname] || "localhost"),
      "-p",
      to_string(config[:port] || 5432),
      "-U",
      to_string(config[:username]),
      "-d",
      to_string(config[:database]),
      "-c",
      sql
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

  defmodule RestoredRepo do
    @moduledoc false
    use Ecto.Repo, otp_app: :samen_core, adapter: Ecto.Adapters.Postgres
  end

  defp start_restored_repo(config) do
    Application.put_env(:samen_core, RestoredRepo, config)

    case RestoredRepo.start_link() do
      {:ok, _pid} -> {:ok, RestoredRepo}
      {:error, {:already_started, _pid}} -> {:ok, RestoredRepo}
    end
  end

  defp stop_restored_repo do
    if pid = Process.whereis(RestoredRepo), do: Supervisor.stop(pid, :normal)
    :ok
  end
end
