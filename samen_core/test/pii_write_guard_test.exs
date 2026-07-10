defmodule Samen.PiiWriteGuardTest do
  @moduledoc """
  The **no-operator-plaintext-write** guard (`Samen.Pii.WriteGuard`) — WS-A design §1.2
  MC-1, ADR-016 Invariant L1 / RP-L1. A2 closed the READ path (operator sees `%Masked{}`
  → `••••`); A3 opens WRITE forms, a new PII surface. This proves the write-path dual:
  an OPERATOR-plane actor CANNOT create or update a vaulted PII attribute with plaintext.

  Exercised against the REAL Ash `:create`/`:update` actions of `Clinical.Patient`
  (vaulted `mrn`/`dob`, non-PII `consent_on_file`) — the same fixture the vault
  integration test uses — so the guard is proven at the actual write path, not a mock.

  ## The plane rule under test

    * `plane: :tenant`  → PII create/update ALLOWED (the legitimate surface; routes
      through the vault write path, MC-2).
    * `plane: nil`      → internal/seed write ALLOWED (not an operator).
    * `plane: :operator`→ PII plaintext create/update REFUSED, DB unchanged (RP-L1).

  ## Anti-tautology posture

  The GREEN controls (tenant + nil-plane writes succeed) prove the guard is not a blanket
  "reject all PII writes"; the RED paths (operator writes refused) prove it is not a
  no-op. The "operator may update a NON-PII field" case proves it fires on exactly the
  vaulted-attribute set, not on any operator touch of a PII-bearing row.
  """
  use ExUnit.Case, async: false

  require Ash.Query

  alias Samen.Masked
  alias SamenCore.Support.Clinical.Patient

  @repo SamenCore.TestRepo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(@repo)
    Samen.Kms.FileBacked.simulate_outage(false)
    Application.put_env(:samen_core, :kms_adapter, Samen.Kms.FileBacked)
    :ok
  end

  # Actor maps mirroring Samen.Web.Plane.scope/2 — only the bounded `:plane` marker
  # (+ impersonation for the operator) matters to the guard.
  defp tenant_actor(org_id),
    do: %{id: "broker:#{org_id}", org_id: org_id, role: :member, kind: :tenant, plane: :tenant}

  defp operator_actor(org_id),
    do: %{
      id: "operator:op-1",
      org_id: org_id,
      role: :member,
      kind: :operator,
      plane: :operator,
      impersonation: %{session_id: "op-session"}
    }

  defp create_with(actor, attrs) do
    Patient
    |> Ash.Changeset.for_create(:create, attrs, actor: actor, authorize?: false)
    |> Ash.create()
  end

  defp create_seed(org_id) do
    # A nil-plane internal write (the SEED path) — no actor plane.
    Patient
    |> Ash.Changeset.for_create(
      :create,
      %{org_id: org_id, mrn: "MRN-SEED-1", dob: ~D[1990-01-01]},
      authorize?: false
    )
    |> Ash.create!()
  end

  # ---------------------------------------------------------------------------
  # GREEN controls — the legitimate write surfaces are NOT blocked
  # ---------------------------------------------------------------------------

  test "TENANT plane: creating a patient with PII SUCCEEDS (the legitimate surface)" do
    org_id = Ash.UUID.generate()

    assert {:ok, p} =
             create_with(tenant_actor(org_id), %{
               org_id: org_id,
               mrn: "MRN-TENANT-7",
               dob: ~D[1985-05-05]
             })

    # And it went through the vault write path (MC-2): the column holds a token.
    %{rows: [[mrn_col]]} =
      @repo.query!("SELECT pii_pat_mrn FROM pat_patient WHERE pat_id = $1", [
        Ecto.UUID.dump!(p.id)
      ])

    assert String.starts_with?(mrn_col, "vt_")
    refute mrn_col =~ "TENANT"
  end

  test "NIL plane (internal/seed): a PII write SUCCEEDS (a seed is not an operator)" do
    org_id = Ash.UUID.generate()
    p = create_seed(org_id)
    assert %Masked{} = reload(p).mrn
  end

  # ---------------------------------------------------------------------------
  # RED PATH RP-L1 — operator-plane plaintext write is REFUSED, DB unchanged
  # ---------------------------------------------------------------------------

  test "RED PATH (RP-L1): OPERATOR plane CREATE with plaintext PII is REFUSED, no row written" do
    org_id = Ash.UUID.generate()

    before_count = patient_count()

    assert {:error, %Ash.Error.Invalid{} = err} =
             create_with(operator_actor(org_id), %{
               org_id: org_id,
               mrn: "MRN-OPERATOR-EVIL",
               dob: ~D[1970-07-07]
             })

    assert error_message(err) =~ "no-operator-plaintext-write"

    # DB UNCHANGED: no new patient row, and the plaintext never hit the vault.
    assert patient_count() == before_count

    %{rows: vault_rows} =
      @repo.query!("SELECT ciphertext FROM pii_vault WHERE ciphertext IS NOT NULL")

    refute Enum.any?(vault_rows, fn [ct] -> is_binary(ct) and ct =~ "EVIL" end)
  end

  test "RED PATH (RP-L1): OPERATOR plane UPDATE overwriting a vaulted attr is REFUSED, value unchanged" do
    org_id = Ash.UUID.generate()
    p = create_seed(org_id)

    %{rows: [[mrn_before]]} =
      @repo.query!("SELECT pii_pat_mrn FROM pat_patient WHERE pat_id = $1", [
        Ecto.UUID.dump!(p.id)
      ])

    assert {:error, %Ash.Error.Invalid{} = err} =
             p
             |> Ash.Changeset.for_update(:update, %{mrn: "MRN-OPERATOR-OVERWRITE"},
               actor: operator_actor(org_id),
               authorize?: false
             )
             |> Ash.update()

    assert error_message(err) =~ "no-operator-plaintext-write"

    # The stored token is UNCHANGED — the operator's plaintext never reached the vault.
    %{rows: [[mrn_after]]} =
      @repo.query!("SELECT pii_pat_mrn FROM pat_patient WHERE pat_id = $1", [
        Ecto.UUID.dump!(p.id)
      ])

    assert mrn_after == mrn_before
  end

  # ---------------------------------------------------------------------------
  # SCOPING — the guard fires on vaulted attrs ONLY, not any operator touch
  # ---------------------------------------------------------------------------

  test "OPERATOR plane may UPDATE a NON-PII field on a PII-bearing row (masked value round-trips)" do
    org_id = Ash.UUID.generate()
    p = create_seed(org_id)

    # Read back so the changeset carries the field's %Masked{} value (round-trip), and
    # update ONLY the non-PII consent flag. This must be ALLOWED — the operator is not
    # writing plaintext PII.
    reloaded = reload(p)

    assert {:ok, updated} =
             reloaded
             |> Ash.Changeset.for_update(:update, %{consent_on_file: true},
               actor: operator_actor(org_id),
               authorize?: false
             )
             |> Ash.update()

    assert updated.consent_on_file == true
  end

  test "OPERATOR plane CREATE of a PII-FREE row is ALLOWED (guard is scoped to vaulted attrs)" do
    org_id = Ash.UUID.generate()

    # No mrn/dob set → no vaulted attribute written → nothing for the guard to reject.
    assert {:ok, _p} =
             create_with(operator_actor(org_id), %{org_id: org_id, consent_on_file: false})
  end

  # ---------------------------------------------------------------------------
  # helpers
  # ---------------------------------------------------------------------------

  defp reload(p) do
    [rec] =
      Patient
      |> Ash.Query.filter(id == ^p.id)
      |> Ash.Query.ensure_selected([:mrn, :dob, :consent_on_file])
      |> Ash.read!()

    rec
  end

  defp patient_count do
    %{rows: [[n]]} = @repo.query!("SELECT count(*) FROM pat_patient")
    n
  end

  defp error_message(%Ash.Error.Invalid{errors: errors}) do
    errors |> Enum.map(&Exception.message/1) |> Enum.join(" ")
  end
end
