defmodule Samen.Vault.TokenInputTest do
  @moduledoc """
  A raw string written to a vault field is ALWAYS plaintext (token-binding design D1, T-W1/T-W2).

  Only an internal `%Samen.Masked{}` means "already vaulted". Before this, `VaultField.cast_input/2`
  treated any `"vt_"`-prefixed string as a token and `Vault.Change` skipped it, so (a) a tenant who
  held another subject's token could plant it through a form, a CSV cell or an inbound mail body and
  read that subject's PII, and (b) a plaintext that merely started with `"vt_"` was stored unencrypted.

  Each red path pairs with a positive control. The CSV leg lives in `samen_web`
  (`csv_masking_test.exs`); the operator-plane leg in `hardening/pii_write_guard_fail_closed_test.exs`.
  """
  use ExUnit.Case, async: false

  # MUTATION_OWNS: samen_core/lib/samen/type/vault_field.ex

  alias Samen.Masked
  alias Samen.Pii.Plaintext
  alias Samen.Type.VaultField
  alias Samen.Vault
  alias SamenCore.Support.Clinical.Patient

  @repo SamenCore.TestRepo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(@repo)
    Samen.Kms.FileBacked.simulate_outage(false)
    Application.put_env(:samen_core, :kms_adapter, Samen.Kms.FileBacked)
    :ok
  end

  defp create_patient(mrn) do
    Patient
    |> Ash.Changeset.for_create(:create, %{org_id: Ash.UUID.generate(), mrn: mrn, dob: ~D[1990-01-01]})
    |> Ash.create!()
  end

  defp raw_mrn(p) do
    %{rows: [[v]]} =
      @repo.query!("SELECT pii_pat_mrn FROM pat_patient WHERE pat_id = $1", [Ecto.UUID.dump!(p.id)])

    v
  end

  defp vault_row_count, do: @repo.query!("SELECT count(*) FROM pii_vault", []).rows |> hd() |> hd()

  defp reveal_raw(token), do: Vault.reveal(Masked.new(token, :mrn), @repo)

  describe "the type layer" do
    test "cast_input: every string is plaintext, a vt_ one included; only %Masked{} and nil pass" do
      token = Vault.generate_token()
      masked = Masked.new(token, :mrn)

      for s <- [token, "vt_", "vt_ please help", "plain"] do
        assert {:ok, %Plaintext{value: ^s}} = VaultField.cast_input(s, [])
      end

      assert {:ok, ^masked} = VaultField.cast_input(masked, [])
      assert {:ok, nil} = VaultField.cast_input(nil, [])
    end

    test "dump_to_native persists only token-shaped values (a Masked or a bare minted token)" do
      token = Vault.generate_token()

      assert {:ok, ^token} = VaultField.dump_to_native(token, [])
      assert {:ok, ^token} = VaultField.dump_to_native(Masked.new(token, :mrn), [])
      assert {:ok, nil} = VaultField.dump_to_native(nil, [])

      for bad <- ["vt_ please help", "vt_", "vt_" <> String.duplicate("A", 32), "plain"] do
        assert :error == VaultField.dump_to_native(bad, [])
        assert :error == VaultField.dump_to_native(Masked.new(bad, :mrn), [])
      end
    end
  end

  describe "T-W1 create/update cannot name another subject's token" do
    test "create with another record's live token string vaults it as NEW plaintext; the victim is untouched" do
      victim = create_patient("MRN-VICTIM-SECRET")
      victim_token = raw_mrn(victim)
      assert Vault.token?(victim_token)

      attacker = create_patient(victim_token)
      attacker_token = raw_mrn(attacker)

      refute attacker_token == victim_token
      assert Vault.token?(attacker_token)
      # reveal returns the literal string the attacker typed, never the victim's value
      assert {:ok, ^victim_token} = reveal_raw(attacker_token)
      # the victim's row still decrypts to the victim's own value, and is still the victim's
      assert {:ok, "MRN-VICTIM-SECRET"} = reveal_raw(victim_token)
      assert raw_mrn(victim) == victim_token
    end

    test "update with another record's live token string re-vaults it as plaintext too" do
      victim = create_patient("MRN-VICTIM-2")
      victim_token = raw_mrn(victim)
      attacker = create_patient("MRN-ATTACKER")
      before_token = raw_mrn(attacker)

      attacker
      |> Ash.Changeset.for_update(:update, %{mrn: victim_token})
      |> Ash.update!()

      after_token = raw_mrn(attacker)
      refute after_token in [before_token, victim_token]
      assert {:ok, ^victim_token} = reveal_raw(after_token)
    end

    test "CONTROL: an ordinary plaintext still vaults and reveals" do
      p = create_patient("MRN-ORDINARY")
      assert Vault.token?(raw_mrn(p))
      assert {:ok, "MRN-ORDINARY"} = reveal_raw(raw_mrn(p))
    end
  end

  describe "T-W2 a vt_-prefixed plaintext is encrypted, not stored raw" do
    test "the column holds a minted token, never the body; reveal returns the body" do
      body = "vt_ please help me with my order"
      p = create_patient(body)
      raw = raw_mrn(p)

      refute raw == body
      assert Vault.token?(raw)
      assert {:ok, ^body} = reveal_raw(raw)
    end

    test "a vt_-prefixed plaintext adds a vault row (it is not skipped)" do
      before = vault_row_count()
      _ = create_patient("vt_ not a token")
      assert vault_row_count() > before
    end
  end
end
