defmodule Samen.Vault.WriteGuardTest do
  @moduledoc """
  WP28 S1/N1: the write-side guard of `Samen.Vault.Change`, an after_action INSIDE the action
  transaction (token-binding design, ADR-001 §6.2).

    * A call-site `Ash.create(cs, upsert?: true)` onto an existing identity is refused after the
      write (inside the action Ash marks every create an upsert, so a before_action cannot tell),
      and the transaction rolls back the vault rows with the domain write.
    * A host before_action registered AFTER `Vault.Change` that swaps a vault attribute for an
      unchecked `%Masked{}` is refused.
    * An atomic write of a vault field never reaches the data layer: Ash refuses it (the type has no
      atomic cast, and `Vault.Change` has no `atomic/3`).

  Every red path has a positive control.
  """
  use ExUnit.Case, async: false

  # MUTATION_OWNS: samen_core/lib/samen/vault/change.ex

  require Ash.Query
  require Ash.Expr

  alias Samen.Masked
  alias Samen.Vault
  alias SamenCore.Support.Clinical.Patient

  @repo SamenCore.TestRepo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(@repo)
    Samen.Kms.FileBacked.simulate_outage(false)
    Application.put_env(:samen_core, :kms_adapter, Samen.Kms.FileBacked)
    # The test schema has no unique index for the `:title` identity; the DDL is rolled back with the sandbox.
    @repo.query!("CREATE UNIQUE INDEX wg_title ON pat_patient (pat_job_title)", [])
    :ok
  end

  defp create(attrs) do
    Patient |> Ash.Changeset.for_create(:create, attrs) |> Ash.create!()
  end

  defp upsert(attrs) do
    Patient
    |> Ash.Changeset.for_create(:create, attrs)
    |> Ash.create(upsert?: true, upsert_identity: :title)
  end

  defp reload!(p) do
    Patient |> Ash.Query.filter(id == ^p.id) |> Ash.Query.ensure_selected([:mrn]) |> Ash.read_one!()
  end

  defp raw_mrn(p) do
    %{rows: [[v]]} = @repo.query!("SELECT pii_pat_mrn FROM pat_patient WHERE pat_id = $1", [Ecto.UUID.dump!(p.id)])
    v
  end

  defp vault_rows, do: @repo.query!("SELECT count(*) FROM pii_vault", []).rows |> hd() |> hd()
  defp patient_rows, do: @repo.query!("SELECT count(*) FROM pat_patient", []).rows |> hd() |> hd()

  describe "S1: a call-site upsert onto an existing identity" do
    test "is refused, the existing row's token is unchanged and the vault rows roll back with the action" do
      org = Ash.UUID.generate()
      existing = create(%{org_id: org, job_title: "same", mrn: "MRN-ORIGINAL"})
      token_before = raw_mrn(existing)
      vault_before = vault_rows()
      rows_before = patient_rows()

      assert {:error, %Ash.Error.Invalid{} = err} =
               upsert(%{org_id: org, job_title: "same", mrn: "MRN-OVERWRITE"})

      text = Exception.message(err)
      assert text =~ "vault subject does not match the written row"
      refute text =~ "MRN-OVERWRITE"

      # The transaction rolled back: the minted vault row is gone (same repo, same transaction) ...
      assert vault_rows() == vault_before
      # ... and the domain write too.
      assert raw_mrn(existing) == token_before
      assert patient_rows() == rows_before
      assert {:ok, "MRN-ORIGINAL"} = Vault.reveal(reload!(existing).mrn, @repo)
    end

    test "CONTROL: an upsert that inserts a NEW row (no conflict) and a plain create are not refused" do
      org = Ash.UUID.generate()
      assert {:ok, fresh} = upsert(%{org_id: org, job_title: "fresh", mrn: "MRN-FRESH"})
      assert {:ok, "MRN-FRESH"} = Vault.reveal(reload!(fresh).mrn, @repo)

      plain = create(%{org_id: org, job_title: "plain", mrn: "MRN-PLAIN"})
      assert {:ok, "MRN-PLAIN"} = Vault.reveal(reload!(plain).mrn, @repo)
    end

    test "a conflicting upsert that only re-sets a BOUND %Masked{} (nothing minted) is refused too, and rolls back" do
      org = Ash.UUID.generate()
      existing = create(%{org_id: org, job_title: "same", mrn: "MRN-ORIGINAL"})
      token_before = raw_mrn(existing)

      # An id-preserving move: the token is bound to the PK the new row would carry, which is NOT the existing row's.
      pk = Ash.UUID.generate()
      {:ok, token} = Vault.store_field(pk, :pii_mrn, :mrn, "MRN-MOVED", @repo)
      vault_before = vault_rows()

      # `upsert_fields` leaves the key out, so the existing row keeps ITS key while taking a token bound to `pk`.
      assert {:error, %Ash.Error.Invalid{} = err} =
               Patient
               |> Ash.Changeset.for_create(:create, %{org_id: org, job_title: "same", mrn: Masked.new(token, :mrn)})
               |> Ash.Changeset.force_change_attribute(:id, pk)
               |> Ash.create(upsert?: true, upsert_identity: :title, upsert_fields: [:mrn, :job_title])

      assert Exception.message(err) =~ "vault subject does not match the written row"
      assert raw_mrn(existing) == token_before
      assert vault_rows() == vault_before

      # CONTROL: the same move as a plain create (no conflict) succeeds.
      assert {:ok, moved} =
               Patient
               |> Ash.Changeset.for_create(:create, %{org_id: org, job_title: "moved", mrn: Masked.new(token, :mrn)})
               |> Ash.Changeset.force_change_attribute(:id, pk)
               |> Ash.create()

      assert {:ok, "MRN-MOVED"} = Vault.reveal(reload!(moved).mrn, @repo)
    end

    test "a conflicting upsert that sets NO vault field is not refused (nothing was minted under the wrong subject)" do
      org = Ash.UUID.generate()
      existing = create(%{org_id: org, job_title: "same", mrn: "MRN-KEEP"})

      assert {:ok, _} = upsert(%{org_id: org, job_title: "same", consent_on_file: true})
      assert {:ok, "MRN-KEEP"} = Vault.reveal(reload!(existing).mrn, @repo)
    end
  end

  describe "S1: the guard undoes the write even when the caller turns Ash's rollback off" do
    test "a call-site upsert with rollback_on_error?: false is still refused and not durable" do
      org = Ash.UUID.generate()
      existing = create(%{org_id: org, job_title: "same", mrn: "MRN-ORIGINAL"})
      token_before = raw_mrn(existing)
      vault_before = vault_rows()
      rows_before = patient_rows()

      assert {:error, %Ash.Error.Invalid{} = err} =
               Patient
               |> Ash.Changeset.for_create(:create, %{org_id: org, job_title: "same", mrn: "MRN-OVERWRITE"})
               |> Ash.create(upsert?: true, upsert_identity: :title, rollback_on_error?: false)

      assert Exception.message(err) =~ "vault subject does not match the written row"
      assert raw_mrn(existing) == token_before
      assert vault_rows() == vault_before
      assert patient_rows() == rows_before
      assert {:ok, "MRN-ORIGINAL"} = Vault.reveal(reload!(existing).mrn, @repo)
    end

    test "a swapping hook with rollback_on_error?: false is refused and nothing is written" do
      org = Ash.UUID.generate()
      victim = create(%{org_id: org, job_title: "victim", mrn: "MRN-VICTIM"})
      foreign = reload!(victim).mrn
      rows_before = patient_rows()
      vault_before = vault_rows()

      assert {:error, %Ash.Error.Invalid{}} =
               Patient
               |> Ash.Changeset.for_create(:create, %{org_id: org, job_title: "thief", mrn: "MRN-THIEF"})
               |> Ash.Changeset.before_action(&Ash.Changeset.force_change_attribute(&1, :mrn, foreign))
               |> Ash.create(rollback_on_error?: false)

      assert patient_rows() == rows_before
      assert vault_rows() == vault_before
    end

    test "CONTROL: the same calls with rollback_on_error?: false succeed when nothing is refused" do
      org = Ash.UUID.generate()

      assert {:ok, p} =
               Patient
               |> Ash.Changeset.for_create(:create, %{org_id: org, job_title: "ok", mrn: "MRN-OK"})
               |> Ash.create(rollback_on_error?: false)

      assert {:ok, "MRN-OK"} = Vault.reveal(reload!(p).mrn, @repo)
    end
  end

  describe "N1: a later hook that swaps a vault attribute" do
    defp with_hook(attrs, fun) do
      Patient
      |> Ash.Changeset.for_create(:create, attrs)
      |> Ash.Changeset.before_action(fun)
      |> Ash.create()
    end

    test "is refused on create and nothing is written" do
      org = Ash.UUID.generate()
      victim = create(%{org_id: org, job_title: "victim", mrn: "MRN-VICTIM"})
      foreign = reload!(victim).mrn
      rows_before = patient_rows()
      vault_before = vault_rows()

      assert {:error, %Ash.Error.Invalid{} = err} =
               with_hook(%{org_id: org, job_title: "thief", mrn: "MRN-THIEF"}, fn cs ->
                 Ash.Changeset.force_change_attribute(cs, :mrn, foreign)
               end)

      assert Exception.message(err) =~ "changed after Samen.Vault.Change approved it"
      refute Exception.message(err) =~ foreign.token
      assert patient_rows() == rows_before
      assert vault_rows() == vault_before
    end

    test "is refused on update, and the row keeps its own token" do
      org = Ash.UUID.generate()
      a = create(%{org_id: org, job_title: "a", mrn: "MRN-A"})
      b = create(%{org_id: org, job_title: "b", mrn: "MRN-B"})
      foreign = reload!(a).mrn
      token_before = raw_mrn(b)

      assert {:error, %Ash.Error.Invalid{}} =
               b
               |> Ash.Changeset.for_update(:update, %{consent_on_file: true})
               |> Ash.Changeset.before_action(&Ash.Changeset.force_change_attribute(&1, :mrn, foreign))
               |> Ash.update()

      assert raw_mrn(b) == token_before
      assert {:ok, "MRN-B"} = Vault.reveal(reload!(b).mrn, @repo)
    end

    test "CONTROL: a later hook that leaves the vault attributes alone passes" do
      org = Ash.UUID.generate()

      assert {:ok, p} =
               with_hook(%{org_id: org, job_title: "ok", mrn: "MRN-OK"}, fn cs ->
                 Ash.Changeset.force_change_attribute(cs, :consent_on_file, true)
               end)

      assert {:ok, "MRN-OK"} = Vault.reveal(reload!(p).mrn, @repo)
    end

    test "a later hook that clears a vault attribute the change approved is refused" do
      org = Ash.UUID.generate()

      assert {:error, %Ash.Error.Invalid{}} =
               with_hook(%{org_id: org, job_title: "clr", mrn: "MRN-CLR"}, fn cs ->
                 Ash.Changeset.force_change_attribute(cs, :mrn, nil)
               end)
    end

    test "a later hook that restores the approved %Masked{} unchanged passes" do
      org = Ash.UUID.generate()

      assert {:ok, p} =
               with_hook(%{org_id: org, job_title: "same", mrn: "MRN-SAME"}, fn cs ->
                 {:ok, approved} = Ash.Changeset.fetch_change(cs, :mrn)
                 cs |> Ash.Changeset.force_change_attribute(:mrn, nil) |> Ash.Changeset.force_change_attribute(:mrn, approved)
               end)

      assert {:ok, "MRN-SAME"} = Vault.reveal(reload!(p).mrn, @repo)
    end
  end

  describe "N1: atomic writes of a vault field never reach the data layer" do
    @forged "vt_abcdefabcdefabcdefabcdefabcdefab"

    test "an expression atomic_update on update and create is refused by Ash (the type has no atomic cast)" do
      org = Ash.UUID.generate()
      p = create(%{org_id: org, job_title: "at", mrn: "MRN-AT"})
      token_before = raw_mrn(p)

      assert {:error, %Ash.Error.Unknown{} = e1} =
               p
               |> Ash.Changeset.for_update(:update, %{})
               |> Ash.Changeset.atomic_update(:mrn, Ash.Expr.expr(fragment("?", @forged)))
               |> Ash.update()

      assert Exception.message(e1) =~ "does not support atomic updates with expressions"
      assert raw_mrn(p) == token_before

      assert {:error, %Ash.Error.Unknown{} = e2} =
               Patient
               |> Ash.Changeset.for_create(:create, %{org_id: org, job_title: "at2"})
               |> Ash.Changeset.atomic_update(:mrn, Ash.Expr.expr(fragment("?", @forged)))
               |> Ash.create()

      assert Exception.message(e2) =~ "does not support atomic updates with expressions"
    end

    test "a LITERAL atomic_update is cast as plaintext and vaulted (the forged-looking token is not a token)" do
      p = create(%{org_id: Ash.UUID.generate(), job_title: "lit", mrn: "MRN-LIT"})

      assert {:ok, _} =
               p |> Ash.Changeset.for_update(:update, %{}) |> Ash.Changeset.atomic_update(:mrn, @forged) |> Ash.update()

      refute raw_mrn(p) == @forged
      assert {:ok, @forged} = Vault.reveal(reload!(p).mrn, @repo)
    end

    test "a strategy: :atomic bulk_update on a PII resource is refused (Vault.Change has no atomic/3), even for another field" do
      p = create(%{org_id: Ash.UUID.generate(), job_title: "bulk", mrn: "MRN-BULK"})

      for attrs <- [%{mrn: "MRN-BULK-2"}, %{consent_on_file: true}] do
        result =
          Patient
          |> Ash.Query.filter(id == ^p.id)
          |> Ash.bulk_update(:update, attrs, strategy: :atomic, return_errors?: true, authorize?: false)

        assert %Ash.BulkResult{status: :error, errors: [err]} = result
        assert Exception.message(err) =~ "Samen.Vault.Change does not implement `atomic/3`"
      end

      assert {:ok, "MRN-BULK"} = Vault.reveal(reload!(p).mrn, @repo)

      # CONTROL: the :stream strategy runs the change per record and succeeds.
      assert %Ash.BulkResult{status: :success} =
               Patient
               |> Ash.Query.filter(id == ^p.id)
               |> Ash.bulk_update(:update, %{mrn: "MRN-BULK-3"}, strategy: :stream, return_errors?: true, authorize?: false)

      assert {:ok, "MRN-BULK-3"} = Vault.reveal(reload!(p).mrn, @repo)
    end
  end
end
