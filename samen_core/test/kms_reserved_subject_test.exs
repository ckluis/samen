defmodule Samen.KmsReservedSubjectTest do
  @moduledoc """
  ADR-035 §4.1 — the reserved SYNTHETIC subject red path. `"sys:bidx"` is the
  blind-index HMAC purpose key (`Samen.Auth.BlindIndex`), provisioned through the
  ordinary `Samen.Kms` subject-key callbacks but PERMANENTLY EXCLUDED from
  `shred/1`: shredding it would break every login lookup, not erase one subject.

  This is the red test T02 owes (ADR-035 §4.1, §8): `shred("sys:bidx")` is REFUSED,
  through every call site that can trigger a shred (`Samen.Kms.shred/1` — the
  chokepoint itself, `Samen.Vault.shred/1`, and `Samen.Erasure.shred/2`) — plus the
  POSITIVE CONTROL (anti-tautology): an ordinary subject still shreds normally
  through the exact same call sites, so the refusal is a property of the reserved
  subject, not a blanket "shred is broken" regression.
  """
  use ExUnit.Case, async: false

  alias Samen.Erasure
  alias Samen.Kms
  alias Samen.Vault

  @repo SamenCore.TestRepo
  @reserved "sys:bidx"

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(@repo)
    Application.put_env(:samen_core, :kms_adapter, Samen.Kms.FileBacked)
    on_exit(fn -> Application.put_env(:samen_core, :kms_adapter, Samen.Kms.FileBacked) end)
    :ok
  end

  defp subj, do: "reserved-subject-test-#{System.unique_integer([:positive])}"

  describe "RED PATH: shred(\"sys:bidx\") is refused" do
    test "Samen.Kms.reserved_subject?/1 identifies the reserved synthetic subject" do
      assert Kms.reserved_subject?(@reserved)
      refute Kms.reserved_subject?(subj())
    end

    test "Samen.Kms.shred/1 — the chokepoint — refuses it BEFORE touching the adapter" do
      # Provision the reserved subject's key first (as BlindIndex would, via
      # generate_subject_key/unwrap) so a real, live key exists to prove the
      # refusal is NOT merely "there was nothing to shred".
      {:ok, _wrapped} = Kms.adapter().generate_subject_key(@reserved)
      assert {:ok, _dek} = Kms.adapter().unwrap(@reserved)

      assert {:error, :reserved_subject} = Kms.shred(@reserved)

      # The key material survives the refused shred — it was never touched.
      assert {:ok, _dek} = Kms.adapter().unwrap(@reserved)
      assert Kms.adapter().key_material_present?(@reserved)
    end

    test "Samen.Vault.shred/1 refuses it (rides the Kms.shred/1 chokepoint)" do
      {:ok, _} = Kms.adapter().generate_subject_key(@reserved)
      assert {:error, :reserved_subject} = Vault.shred(@reserved)
      assert Kms.adapter().key_material_present?(@reserved)
    end

    test "Samen.Erasure.shred/2 refuses it (fails closed, no report/sentinel written)" do
      {:ok, _} = Kms.adapter().generate_subject_key(@reserved)

      assert {:error, {:kms_shred_failed, :reserved_subject}} =
               Erasure.shred(@reserved, repo: @repo)

      # No erasure took place: the key is untouched.
      assert Kms.adapter().key_material_present?(@reserved)
    end
  end

  describe "POSITIVE CONTROL: an ordinary subject still shreds (anti-tautology)" do
    test "Samen.Kms.shred/1 shreds a normal subject" do
      s = subj()
      {:ok, _} = Kms.adapter().generate_subject_key(s)
      assert {:ok, attestation} = Kms.shred(s)
      assert attestation.state == :shredded
      refute Kms.adapter().key_material_present?(s)
    end

    test "Samen.Vault.shred/1 shreds a normal subject" do
      s = subj()
      {:ok, _} = Vault.store_field(s, :pii_email, :emails, "control@example.test", @repo)
      assert {:ok, attestation} = Vault.shred(s)
      assert attestation.state == :shredded
      refute Kms.adapter().key_material_present?(s)
    end

    test "Samen.Erasure.shred/2 shreds a normal subject end-to-end" do
      s = subj()
      {:ok, _} = Vault.store_field(s, :pii_email, :emails, "control2@example.test", @repo)
      assert {:ok, %{attestation: attestation}} = Erasure.shred(s, repo: @repo)
      assert attestation.state == :shredded
      assert Erasure.erased?(s, repo: @repo)
    end
  end
end
