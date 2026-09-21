defmodule Samen.Hardening.PiiWriteGuardFailClosedTest do
  @moduledoc """
  Fail-closed PROOFS for the three `Samen.Pii.WriteGuard.plaintext_write?/2` clauses the
  ADR-049 mutation gate found SURVIVING (ledgered ACCEPTED_GAP as MG-08/09/10). Each is a
  NOT-a-plaintext-write clause: the guard must let the write through, because nothing about
  it is operator-authored plaintext.

  | MG | clause (absolute line on `0216ce8`)            | mutation        |
  |----|------------------------------------------------|-----------------|
  | 08 | line 119 `{:ok, %Masked{}} -> false`           | `false` → `true`|
  | 09 | line 120 `{:ok, "vt_" <> _} -> false`         | `false` → `true`|
  | 10 | line 121 `{:ok, nil} -> false`                | `false` → `true`|

  Each mutation makes the guard over-refuse — an operator re-setting the value they were
  SHOWN (a `%Masked{}`), handing back the raw token, or CLEARING the field would be rejected
  as if they had typed plaintext. Verified RED-FIRST by hand, one mutation at a time: the
  named test fails under the mutant and passes on the byte-exact restored source. The
  control below is the anti-tautology twin — real operator plaintext is still REFUSED.
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

  defp operator_actor(org_id),
    do: %{
      id: "operator:op-1",
      org_id: org_id,
      role: :member,
      kind: :operator,
      plane: :operator,
      impersonation: %{session_id: "op-session"}
    }

  # A genuine vaulted row, written on the TENANT plane (the only plane that may author
  # plaintext PII) — so the guard's decision below is about the operator's INPUT SHAPE, not
  # about how the row came to exist.
  defp tenant_patient!(org_id, mrn) do
    Patient
    |> Ash.Changeset.for_create(
      :create,
      %{org_id: org_id, mrn: mrn, dob: ~D[1985-05-05]},
      actor: %{
        id: "broker:#{org_id}",
        org_id: org_id,
        role: :member,
        kind: :tenant,
        plane: :tenant
      },
      authorize?: false
    )
    |> Ash.create!()
  end

  defp reload(p) do
    [rec] =
      Patient
      |> Ash.Query.filter(id == ^p.id)
      |> Ash.Query.ensure_selected([:mrn, :dob, :consent_on_file])
      |> Ash.read!()

    rec
  end

  defp raw_mrn(p) do
    %{rows: [[col]]} =
      @repo.query!("SELECT pii_pat_mrn FROM pat_patient WHERE pat_id = $1", [
        Ecto.UUID.dump!(p.id)
      ])

    col
  end

  defp operator_update(p, attrs, org_id) do
    p
    |> Ash.Changeset.for_update(:update, attrs, actor: operator_actor(org_id), authorize?: false)
    |> Ash.update()
  end

  defp error_message(%Ash.Error.Invalid{} = err), do: Exception.message(err)

  describe "MG-08 — a round-tripping %Masked{} is not a plaintext write (line 119)" do
    test "MG-08: an OPERATOR re-setting the %Masked{} value they were shown is ALLOWED" do
      org_id = Ash.UUID.generate()
      p = tenant_patient!(org_id, "MRN-MASKED-ROUNDTRIP")
      token_before = raw_mrn(p)

      masked = Masked.new(token_before, :mrn)

      # The operator sees `••••` and hands the SAME masked value back (the shape a form
      # re-submit produces). That is not authorship of plaintext, so the guard must allow it.
      assert {:ok, _updated} = operator_update(reload(p), %{mrn: masked}, org_id)

      # And the stored token is untouched — nothing was re-vaulted.
      assert raw_mrn(p) == token_before
    end
  end

  describe "MG-09 — a raw vt_* token is not a plaintext write (line 120)" do
    test "MG-09: an OPERATOR writing back the raw vt_* token is ALLOWED" do
      org_id = Ash.UUID.generate()
      p = tenant_patient!(org_id, "MRN-TOKEN-ROUNDTRIP")
      token_before = raw_mrn(p)
      assert String.starts_with?(token_before, "vt_")

      assert {:ok, _updated} = operator_update(reload(p), %{mrn: token_before}, org_id)

      assert raw_mrn(p) == token_before
    end
  end

  describe "MG-10 — an explicit nil (clear) is not a plaintext write (line 121)" do
    test "MG-10: an OPERATOR CLEARING a vaulted field is ALLOWED and the column is cleared" do
      org_id = Ash.UUID.generate()
      p = tenant_patient!(org_id, "MRN-TO-BE-CLEARED")
      assert String.starts_with?(raw_mrn(p), "vt_")

      # Clearing is the opposite of authoring plaintext — the operator removes a value, they
      # do not overwrite the tenant's with one of their own.
      assert {:ok, _updated} = operator_update(reload(p), %{mrn: nil}, org_id)

      assert raw_mrn(p) == nil
    end
  end

  describe "CONTROL (anti-tautology) — real operator plaintext is STILL refused" do
    test "an OPERATOR writing genuine plaintext into the same field is REFUSED, value unchanged" do
      org_id = Ash.UUID.generate()
      p = tenant_patient!(org_id, "MRN-CONTROL")
      token_before = raw_mrn(p)

      assert {:error, %Ash.Error.Invalid{} = err} =
               operator_update(reload(p), %{mrn: "MRN-OPERATOR-AUTHORED"}, org_id)

      assert error_message(err) =~ "no-operator-plaintext-write"
      assert raw_mrn(p) == token_before
    end
  end
end
