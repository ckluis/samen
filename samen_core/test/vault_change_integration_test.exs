defmodule Samen.VaultChangeIntegrationTest do
  @moduledoc """
  Integration red-path tests for the resource↔vault integration
  (`Samen.Vault.Change` + `Samen.Type.VaultField`), the mandatory P0 fix from the
  vault-stack audit.

  These exercise the REAL Ash `:create`/`:update`/`:read` actions of a composed
  resource (Clinical.Patient) — not the low-level `Samen.Vault` API — and assert
  the four properties the audit named:

    (a) the domain table column holds a `vt_*` token, NOT plaintext;
    (b) `pii_vault` has a ciphertext row for the value;
    (c) `Ash.read` returns `%Masked{}` as the field's normal value;
    (d) raw SQL / JSON of the row shows NO plaintext.
  """
  use ExUnit.Case, async: false

  require Ash.Query

  alias SamenCore.Support.Clinical.Patient
  alias Samen.Masked
  alias Samen.Vault

  @repo SamenCore.TestRepo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(@repo)
    Samen.Kms.FileBacked.simulate_outage(false)
    Application.put_env(:samen_core, :kms_adapter, Samen.Kms.FileBacked)
    :ok
  end

  defp create_patient do
    Patient
    |> Ash.Changeset.for_create(:create, %{
      org_id: Ash.UUID.generate(),
      full_name: %{first: "Grace", last: "Hopper"},
      mrn: "MRN-SECRET-42",
      dob: ~D[1906-12-09]
    })
    |> Ash.create!()
  end

  describe "create via the real Ash :create action" do
    test "(a) the domain column holds a vt_* token, NOT plaintext" do
      p = create_patient()

      %{rows: [[mrn_col, fname_col, dob_col]]} =
        @repo.query!(
          "SELECT pii_pat_mrn, pat_full_name, pii_pat_dob FROM pat_patient WHERE pat_id = $1",
          [Ecto.UUID.dump!(p.id)]
        )

      for col <- [mrn_col, fname_col, dob_col] do
        assert is_binary(col)
        assert String.starts_with?(col, "vt_"), "expected vault token, got #{inspect(col)}"
      end

      # RED PATH (a): the plaintext must NOT be in the domain column.
      refute mrn_col == "MRN-SECRET-42"
      refute mrn_col =~ "SECRET"
      refute fname_col =~ "Grace"
      refute fname_col =~ "Hopper"
    end

    test "(b) pii_vault has a ciphertext row per vaulted field" do
      p = create_patient()

      %{rows: rows} =
        @repo.query!(
          "SELECT field_name, ciphertext FROM pii_vault WHERE subject_id = $1",
          [p.id]
        )

      field_names = Enum.map(rows, fn [fn_, _ct] -> fn_ end) |> Enum.sort()
      assert field_names == ["dob", "full_name", "mrn"]

      # RED PATH (b): the ciphertext must exist and must NOT contain plaintext.
      for [_fn, ct] <- rows do
        assert is_binary(ct) and byte_size(ct) > 0
        refute ct =~ "SECRET"
        refute ct =~ "Grace"
        refute ct =~ "Hopper"
      end
    end

    test "(c) Ash.read returns %Masked{} as the field's normal value" do
      p = create_patient()

      [read_back] =
        Patient
        |> Ash.Query.filter(id == ^p.id)
        |> Ash.Query.ensure_selected([:full_name, :mrn, :dob])
        |> Ash.read!()

      assert %Masked{} = read_back.full_name
      assert %Masked{} = read_back.mrn
      assert %Masked{} = read_back.dob

      # RED PATH (c): the normal value is NOT plaintext.
      refute read_back.mrn == "MRN-SECRET-42"
      refute match?(%Samen.Type.FullName{}, read_back.full_name)
    end

    test "(d) JSON of the read-back record shows NO plaintext (only ••••)" do
      p = create_patient()

      [read_back] =
        Patient
        |> Ash.Query.filter(id == ^p.id)
        |> Ash.Query.ensure_selected([:full_name, :mrn, :dob])
        |> Ash.read!()

      json =
        Jason.encode!(%{
          full_name: read_back.full_name,
          mrn: read_back.mrn,
          dob: read_back.dob
        })

      # RED PATH (d): no plaintext leaks by omission through JSON serialization.
      refute json =~ "SECRET"
      refute json =~ "Grace"
      refute json =~ "Hopper"
      refute json =~ "1906"
      assert json =~ "••••"
    end

    test "reveal through the single chokepoint round-trips the plaintext" do
      p = create_patient()

      [read_back] =
        Patient
        |> Ash.Query.filter(id == ^p.id)
        |> Ash.Query.ensure_selected([:mrn])
        |> Ash.read!()

      assert {:ok, "MRN-SECRET-42"} = Vault.reveal(read_back.mrn, @repo)
    end

    test "after crypto-shred the field reveals :shredded, never plaintext" do
      p = create_patient()

      [read_back] =
        Patient
        |> Ash.Query.filter(id == ^p.id)
        |> Ash.Query.ensure_selected([:mrn])
        |> Ash.read!()

      {:ok, att} = Vault.shred(p.id)
      assert att.state == :shredded

      # RED PATH: post-shred, the domain token still points at ciphertext, but the
      # key is gone — reveal denies. The token column is unchanged (still no
      # plaintext) either way.
      assert {:error, :shredded} = Vault.reveal(read_back.mrn, @repo)
    end
  end

  describe "update via the real Ash :update action" do
    test "changing a PII field re-vaults it and never writes plaintext" do
      p = create_patient()

      p
      |> Ash.Changeset.for_update(:update, %{mrn: "MRN-CHANGED-99"})
      |> Ash.update!()

      [updated] =
        Patient
        |> Ash.Query.filter(id == ^p.id)
        |> Ash.Query.ensure_selected([:mrn])
        |> Ash.read!()

      assert %Masked{} = updated.mrn

      %{rows: [[mrn_col]]} =
        @repo.query!("SELECT pii_pat_mrn FROM pat_patient WHERE pat_id = $1", [
          Ecto.UUID.dump!(p.id)
        ])

      assert String.starts_with?(mrn_col, "vt_")
      refute mrn_col =~ "CHANGED"

      # The new value reveals through the chokepoint.
      assert {:ok, "MRN-CHANGED-99"} = Vault.reveal(updated.mrn, @repo)
    end

    test "an update that does not touch a PII field leaves its token intact" do
      p = create_patient()

      %{rows: [[mrn_before]]} =
        @repo.query!("SELECT pii_pat_mrn FROM pat_patient WHERE pat_id = $1", [
          Ecto.UUID.dump!(p.id)
        ])

      updated =
        p
        |> Ash.Changeset.for_update(:update, %{consent_on_file: true})
        |> Ash.update!()

      assert updated.consent_on_file == true

      %{rows: [[mrn_after]]} =
        @repo.query!("SELECT pii_pat_mrn FROM pat_patient WHERE pat_id = $1", [
          Ecto.UUID.dump!(p.id)
        ])

      assert mrn_after == mrn_before
    end
  end
end
