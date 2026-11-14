defmodule Samen.VaultErasureProbeOutageTest do
  @moduledoc """
  The PITR key-absence verifier and the plaintext scan must not read a KMS outage as proof of erasure:
  `{:error, :unavailable}` is a probe failure (a leak/unknown), only `:shredded` / `:absent` / `:not_found`
  prove the key is gone. Every refusal is paired with a positive control through the same call.
  """
  use ExUnit.Case, async: false

  alias Samen.Kms.FileBacked
  alias Samen.Vault

  @repo SamenCore.TestRepo

  setup do
    Samen.TestSandbox.shared!(@repo)
    FileBacked.simulate_outage(false)
    prior = Application.get_env(:samen_core, :kms_adapter)
    Application.put_env(:samen_core, :kms_adapter, FileBacked)

    on_exit(fn ->
      FileBacked.simulate_outage(false)
      Application.put_env(:samen_core, :kms_adapter, prior || FileBacked)
    end)

    :ok
  end

  defp stored do
    subject = "vault-probe-#{System.unique_integer([:positive])}"
    {:ok, _token} = Vault.store_field(subject, :pii_email, :emails, "probe@example.com", @repo)
    subject
  end

  test "RED: a KMS outage is NOT proof that the key is absent (scan_pitr_key_absent)" do
    subject = stored()
    FileBacked.simulate_outage(true)

    assert {:leaks, [msg]} = Vault.scan_pitr_key_absent(subject, @repo)
    assert msg =~ "key-absence probe FAILED"
    assert msg =~ ":unavailable"
  end

  test "RED: a KMS outage is NOT 'no plaintext' (scan_no_plaintext)" do
    subject = stored()
    FileBacked.simulate_outage(true)

    assert {:leaks, [msg]} = Vault.scan_no_plaintext(subject, @repo)
    assert msg =~ "probe FAILED"
  end

  test "POSITIVE CONTROL: after a real shred the same calls prove the key absent" do
    subject = stored()
    assert {:ok, _} = Vault.shred(subject)

    assert {:ok, :key_absent} = Vault.scan_pitr_key_absent(subject, @repo)
    assert {:ok, :no_plaintext} = Vault.scan_no_plaintext(subject, @repo)
  end

  test "an unshredded subject with the KMS up still reports its decryptable ciphertext" do
    subject = stored()

    assert {:leaks, [leak]} = Vault.scan_pitr_key_absent(subject, @repo)
    assert leak =~ "decryptable ciphertext for token"
    assert {:leaks, [token]} = Vault.scan_no_plaintext(subject, @repo)
    assert String.starts_with?(token, "vt_")
  end
end
