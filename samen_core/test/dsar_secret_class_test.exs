defmodule Samen.DsarSecretClassTest do
  @moduledoc """
  A subject export never carries authentication secrets (authorization and erasure round 4, D). A
  Credential vaults its TOTP secret and recovery-code digests under `:pii_secret` with
  `subject_id = credential id`, so a tenant-plane export of that id used to decrypt them into the
  bundle. Exclusion is decided by VAULT CLASS (`Samen.Vault.Class`), never by field name: a field
  with any name routed to a secret-class vault is excluded, one routed elsewhere is not.
  """
  use ExUnit.Case, async: false

  alias Samen.Dsar
  alias SamenCore.TestRepo, as: Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Samen.Kms.FileBacked.simulate_outage(false)
    Application.put_env(:samen_core, :kms_adapter, Samen.Kms.FileBacked)
    :ok
  end

  defp subj, do: "dsar-secret-subject-#{System.unique_integer([:positive])}"

  defp export(s), do: Dsar.export_subject(s, repo: Repo, plane: :tenant, org_id: "org-1")

  test "RED: a tenant-plane export does not decrypt the pii_secret vault; CONTROL: the personal-data vaults still export" do
    s = subj()
    {:ok, _} = Samen.Vault.store_field(s, :pii_secret, :totp_secret, "JBSWY3DPEHPK3PXP-SECRET", Repo)
    {:ok, _} = Samen.Vault.store_field(s, :pii_secret, :recovery_codes, "digest-of-recovery-code-SECRET", Repo)
    {:ok, _} = Samen.Vault.store_field(s, :pii_email, :emails, "alice@example.com", Repo)

    assert {:ok, bundle} = export(s)

    values = Enum.map(bundle.personal_data, & &1.value)
    assert "alice@example.com" in values
    refute Enum.any?(values, &(is_binary(&1) and &1 =~ "SECRET"))
    refute Enum.any?(bundle.personal_data, &(&1.vault == "pii_secret"))
    refute inspect(bundle) =~ "SECRET"
  end

  test "the class is the vault, not the field name: a secret-class vault is excluded whatever its fields are called; a non-secret vault is not" do
    s = subj()
    prev = Application.get_env(:samen_core, :secret_vaults)
    Application.put_env(:samen_core, :secret_vaults, [:pii_api_credential])
    on_exit(fn -> if prev, do: Application.put_env(:samen_core, :secret_vaults, prev), else: Application.delete_env(:samen_core, :secret_vaults) end)

    {:ok, _} = Samen.Vault.store_field(s, :pii_api_credential, :favourite_colour, "teal-VAULTCLASS", Repo)
    {:ok, _} = Samen.Vault.store_field(s, :pii_secret, :nickname, "nick-VAULTCLASS", Repo)
    {:ok, _} = Samen.Vault.store_field(s, :pii_name, :totp_secret, "Alice Anders", Repo)

    assert {:ok, bundle} = export(s)
    values = Enum.map(bundle.personal_data, & &1.value)

    refute Enum.any?(values, &(is_binary(&1) and &1 =~ "VAULTCLASS"))
    # a field NAMED like a secret but routed to a personal-data vault is personal data
    assert "Alice Anders" in values
    assert Samen.Vault.Class.secret?(:pii_secret)
    refute Samen.Vault.Class.secret?(:pii_name)
  end
end
