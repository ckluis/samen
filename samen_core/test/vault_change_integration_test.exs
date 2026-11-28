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
  import Samen.VaultTokenAssert
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

  # ===========================================================================
  # Token binding (evaluation 2026-11-13, T-W4): a %Masked{} set on a record is bound to
  # THAT record's subject (its primary key), vault and field, or the write is refused.
  # ===========================================================================
  describe "T-W4 binding at the chokepoint" do
    @prefix SamenCore.TestRepo.config()[:telemetry_prefix] || [:samen_core, :test_repo]

    defp patient_in(org_id, mrn \\ "MRN-#{System.unique_integer([:positive])}") do
      Patient
      |> Ash.Changeset.for_create(:create, %{
        org_id: org_id,
        full_name: %{first: "Grace", last: "Hopper"},
        mrn: mrn,
        dob: ~D[1906-12-09]
      })
      |> Ash.create!()
    end

    # PII fields are not selected by default: select them so the record carries its own %Masked{} values.
    defp reload!(p) do
      Patient
      |> Ash.Query.filter(id == ^p.id)
      |> Ash.Query.ensure_selected([:org_id, :full_name, :mrn, :dob])
      |> Ash.read_one!()
    end

    defp raw(p, col) do
      %{rows: [[v]]} =
        @repo.query!("SELECT #{col} FROM pat_patient WHERE pat_id = $1", [Ecto.UUID.dump!(p.id)])

      v
    end

    defp vault_rows, do: @repo.query!("SELECT count(*) FROM pii_vault", []).rows |> hd() |> hd()

    # Run `fun`, returning {result, [sql]} of every repo query it issued.
    defp queries(fun) do
      ref = make_ref()
      parent = self()
      id = {__MODULE__, ref}

      :telemetry.attach(id, @prefix ++ [:query], fn _e, _m, meta, _ -> send(parent, {ref, meta.query}) end, nil)

      try do
        result = fun.()
        {result, drain(ref, [])}
      after
        :telemetry.detach(id)
      end
    end

    defp drain(ref, acc) do
      receive do
        {^ref, q} -> drain(ref, [q | acc])
      after
        0 -> Enum.reverse(acc)
      end
    end

    defp vault_queries(qs), do: Enum.filter(qs, &(&1 =~ "pii_vault"))

    defp set_mrn(p, value) do
      p |> Ash.Changeset.for_update(:update, %{mrn: value}) |> Ash.update()
    end

    defp error_text(%Ash.Error.Invalid{} = e), do: Exception.message(e)

    test "a %Masked{} copied from A into B (same org) is refused, B unchanged, no new vault rows, no token in the error" do
      org = Ash.UUID.generate()
      a = patient_in(org)
      b = patient_in(org)
      a_masked = reload!(a).mrn
      b_before = raw(b, "pii_pat_mrn")
      rows_before = vault_rows()

      assert {:error, %Ash.Error.Invalid{} = err} = set_mrn(reload!(b), a_masked)

      text = error_text(err)
      assert text =~ "mrn"
      assert text =~ "not bound to this record"
      assert text =~ "foreign_subject"
      refute text =~ a_masked.token
      refute inspect(err) =~ a_masked.token

      assert raw(b, "pii_pat_mrn") == b_before
      assert vault_rows() == rows_before
      # the victim is intact and still reveals
      assert {:ok, _} = Vault.reveal(reload!(a).mrn, @repo)
    end

    test "a %Masked{} copied from A into B in ANOTHER org is refused too" do
      a = patient_in(Ash.UUID.generate())
      b = patient_in(Ash.UUID.generate())
      a_masked = reload!(a).mrn
      b_before = raw(b, "pii_pat_mrn")

      assert {:error, %Ash.Error.Invalid{}} = set_mrn(reload!(b), a_masked)
      assert raw(b, "pii_pat_mrn") == b_before
    end

    test "a field swap within the SAME record is refused: dob's token set as the mrn" do
      a = reload!(patient_in(Ash.UUID.generate()))
      dob_token = a.dob.token

      assert {:error, %Ash.Error.Invalid{} = err} = set_mrn(a, Masked.new(dob_token, :mrn))
      assert error_text(err) =~ "field_mismatch"
      refute error_text(err) =~ dob_token
    end

    test "a token with no vault row is refused (not_found)" do
      a = reload!(patient_in(Ash.UUID.generate()))

      assert {:error, %Ash.Error.Invalid{} = err} =
               set_mrn(a, Masked.new(Vault.generate_token(), :mrn))

      assert error_text(err) =~ "not_found"
    end

    test "the refusal is reported once per reason with the reason only (no token) in the telemetry" do
      org = Ash.UUID.generate()
      a = patient_in(org)
      b = patient_in(org)
      a_masked = reload!(a).mrn
      test_pid = self()
      id = {__MODULE__, :unbound}

      :telemetry.attach(
        id,
        [:samen, :core, :write, :error],
        fn _e, _m, meta, _ -> send(test_pid, {:failure, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(id) end)

      assert {:error, _} = set_mrn(reload!(b), a_masked)
      assert_receive {:failure, %{write: :vault_token_unbound, cause: "foreign_subject"} = meta}
      refute_vault_token(inspect(meta))
      refute_receive {:failure, %{write: :vault_token_unbound}}, 50
    end

    test "a token row that matches on ONE of vault/field but not the other is still refused (field_mismatch)" do
      a = reload!(patient_in(Ash.UUID.generate()))

      # right subject and vault, wrong field
      {:ok, other_field} = Vault.store_field(a.id, :pii_mrn, :renamed_field, "x", @repo)
      assert {:error, %Ash.Error.Invalid{} = e1} = set_mrn(a, Masked.new(other_field, :mrn))
      assert error_text(e1) =~ "field_mismatch"

      # right subject and field, wrong vault
      {:ok, other_vault} = Vault.store_field(a.id, :pii_dob, :mrn, "x", @repo)
      assert {:error, %Ash.Error.Invalid{} = e2} = set_mrn(a, Masked.new(other_vault, :mrn))
      assert error_text(e2) =~ "field_mismatch"

      # CONTROL: a token minted for exactly this subject, vault and field IS accepted
      {:ok, exact} = Vault.store_field(a.id, :pii_mrn, :mrn, "MRN-EXACT", @repo)
      assert {:ok, _} = set_mrn(a, Masked.new(exact, :mrn))
      assert {:ok, "MRN-EXACT"} = Vault.reveal(reload!(a).mrn, @repo)
    end

    test "the report names the record's org (from the new attributes on a create, from the stored row on an update)" do
      import ExUnit.CaptureLog

      org = Ash.UUID.generate()
      victim = reload!(patient_in(org))
      holder = reload!(patient_in(org))

      update_log = capture_log([level: :error], fn -> assert {:error, _} = set_mrn(holder, victim.mrn) end)
      assert update_log =~ "write=vault_token_unbound"
      assert update_log =~ "org=#{org}"

      create_org = Ash.UUID.generate()

      create_log =
        capture_log([level: :error], fn ->
          assert {:error, _} =
                   Patient
                   |> Ash.Changeset.for_create(:create, %{org_id: create_org, mrn: victim.mrn})
                   |> Ash.create()
        end)

      assert create_log =~ "org=#{create_org}"
    end

    test "CONTROL: re-setting the record's OWN %Masked{} succeeds and costs ZERO vault queries" do
      a = reload!(patient_in(Ash.UUID.generate()))
      before = raw(a, "pii_pat_mrn")

      {result, qs} =
        queries(fn ->
          a
          |> Ash.Changeset.for_update(:update, %{
            # the shape a form re-submit produces: the same token under the field's own label, which
            # is NOT equal to the stored `:vault`-labelled struct, so Ash records it as a change
            mrn: Masked.new(a.mrn.token, :mrn),
            dob: Masked.new(a.dob.token, :dob),
            consent_on_file: true
          })
          |> Ash.update()
        end)

      assert {:ok, _} = result
      assert raw(a, "pii_pat_mrn") == before
      assert vault_queries(qs) == [], "an untouched round-trip must not query pii_vault, got: #{inspect(qs)}"
    end

    test "CONTROL (counter works): a CHANGED %Masked{} costs exactly ONE batched vault query for all its fields" do
      org = Ash.UUID.generate()
      a = patient_in(org)
      b = reload!(patient_in(org))
      a = reload!(a)

      {result, qs} =
        queries(fn ->
          b
          |> Ash.Changeset.for_update(:update, %{mrn: a.mrn, dob: a.dob})
          |> Ash.update()
        end)

      assert {:error, %Ash.Error.Invalid{} = err} = result
      assert error_text(err) =~ "mrn" and error_text(err) =~ "dob"
      assert length(vault_queries(qs)) == 1, inspect(vault_queries(qs))
    end

    test "CONTROL: after the plaintext is re-set, the new token is the record's own and re-sets cleanly" do
      a = patient_in(Ash.UUID.generate())
      {:ok, updated} = set_mrn(reload!(a), "MRN-REPLACED")
      assert {:ok, _} = set_mrn(reload!(updated), reload!(updated).mrn)
      assert {:ok, "MRN-REPLACED"} = Vault.reveal(reload!(a).mrn, @repo)
    end

    test "create WITHOUT a primary key can never carry a %Masked{}; WITH the matching explicit PK it can" do
      org = Ash.UUID.generate()
      victim = reload!(patient_in(org))

      assert {:error, %Ash.Error.Invalid{} = err} =
               Patient
               |> Ash.Changeset.for_create(:create, %{org_id: org, mrn: victim.mrn})
               |> Ash.create()

      assert error_text(err) =~ "foreign_subject"

      # an id-preserving move: the token is minted under the PK the new row will carry
      pk = Ash.UUID.generate()
      {:ok, token} = Vault.store_field(pk, :pii_mrn, :mrn, "MRN-MOVED", @repo)

      assert {:ok, moved} =
               Patient
               |> Ash.Changeset.for_create(:create, %{org_id: org, mrn: Masked.new(token, :mrn)})
               |> Ash.Changeset.force_change_attribute(:id, pk)
               |> Ash.create()

      assert moved.id == pk
      assert raw(moved, "pii_pat_mrn") == token
      assert {:ok, "MRN-MOVED"} = Vault.reveal(reload!(moved).mrn, @repo)
    end

    test "an upsert-create on a PII resource is refused" do
      assert {:error, %Ash.Error.Invalid{} = err} =
               Patient
               |> Ash.Changeset.for_create(:create, %{org_id: Ash.UUID.generate(), mrn: "MRN-UPSERT"}, upsert?: true)
               |> Ash.create()

      assert error_text(err) =~ "upsert"
    end
  end
end
