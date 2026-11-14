defmodule Samen.VaultKeyColumnScanTest do
  @moduledoc """
  ADR-001 / ARCH-26 (ADR-049 watch-list): `Samen.Vault.scan_pitr_key_absent/2` must flag a key-material-shaped
  column on `pii_vault` — the wrapped DEK must NEVER be a Postgres column, or a PITR restore resurrects it.

  Each column-name shape the detector claims (`wrapped_dek`, `dek`, `*_dek`, `master_key`, `key_material`) is
  planted ALONE (DDL is transactional, so the sandbox rolls it back) and must be reported; an innocent column
  and the untouched table are the positive controls (a detector that flags everything, or nothing, fails one side).
  """
  use ExUnit.Case, async: false

  alias Samen.Vault

  @repo SamenCore.TestRepo
  @subject "subj-keycol-scan"

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(@repo)
    :ok
  end

  defp plant!(col), do: @repo.query!(~s(ALTER TABLE pii_vault ADD COLUMN "#{col}" text))

  test "POSITIVE CONTROL: the unmodified pii_vault proves the key absent" do
    assert {:ok, :key_absent} = Vault.scan_pitr_key_absent(@subject, @repo)
  end

  test "an innocent extra column is not mistaken for key material" do
    plant!("note_text")
    plant!("wrapped")
    plant!("master")
    plant!("key")
    assert {:ok, :key_absent} = Vault.scan_pitr_key_absent(@subject, @repo)
  end

  for col <- ["wrapped_dek", "dek", "subject_dek", "master_key", "key_material", "Master_Key_X"] do
    test "RED: a #{col} column on pii_vault is reported as a PITR key leak" do
      plant!(unquote(col))

      assert {:leaks, [msg]} = Vault.scan_pitr_key_absent(@subject, @repo)
      assert msg =~ "key-material-shaped column '#{String.downcase(unquote(col))}'" or
               msg =~ "key-material-shaped column '#{unquote(col)}'"
    end
  end
end
