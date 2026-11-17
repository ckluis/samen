defmodule Samen.Vault.WriteGuardNoTransactionTest do
  @moduledoc """
  WP28 review S1: a refused vault write is never durable, in every transaction mode.

  The guard (`Samen.Vault.Change`) used to return an error from its after_action and rely on Ash to roll
  back, but Ash commits anyway when the caller passes `transaction?: false` / `rollback_on_error?: false`
  or a bulk `transaction: false`. Under the Ecto sandbox `in_transaction?` is always true, so the
  no-transaction arms run here against COMMITTED writes (`Samen.TestSandbox.auto!/1`) and the test removes
  what it committed.

    * no transaction open: a vault-routing write is refused BEFORE any vault insert or row write;
    * transaction open but the caller disabled Ash's rollback: the guard rolls back itself.
  """
  use ExUnit.Case, async: false

  # MUTATION_OWNS: samen_core/lib/samen/vault/change.ex

  alias Samen.Vault
  alias SamenCore.Support.Clinical.Patient

  @repo SamenCore.TestRepo

  setup do
    Samen.Kms.FileBacked.simulate_outage(false)
    Application.put_env(:samen_core, :kms_adapter, Samen.Kms.FileBacked)
    Samen.TestSandbox.auto!(@repo)

    org = Ash.UUID.generate()
    tokens_before = MapSet.new(token_rows())

    # Registered after auto!/1 so it runs first, while the pool still has unsandboxed connections.
    on_exit(fn ->
      @repo.query!("DELETE FROM pat_patient WHERE pat_org_id = $1", [Ecto.UUID.dump!(org)])
      before = MapSet.to_list(tokens_before)
      @repo.query!("DELETE FROM pii_vault WHERE NOT (token = ANY($1))", [before])
    end)

    {:ok, org: org}
  end

  defp token_rows, do: @repo.query!("SELECT token FROM pii_vault", []).rows |> List.flatten()
  defp vault_rows, do: @repo.query!("SELECT count(*) FROM pii_vault", []).rows |> hd() |> hd()

  defp patients(org),
    do: @repo.query!("SELECT count(*) FROM pat_patient WHERE pat_org_id = $1", [Ecto.UUID.dump!(org)]).rows |> hd() |> hd()

  defp changeset(org, attrs), do: Ash.Changeset.for_create(Patient, :create, Map.merge(%{org_id: org}, attrs))

  # An action declared `transaction? false` (Ash opens no transaction for it).
  defp no_tx_changeset(org, attrs) do
    action = %{Ash.Resource.Info.action(Patient, :create) | transaction?: false}
    Ash.Changeset.for_create(Patient, action, Map.merge(%{org_id: org}, attrs))
  end

  describe "no transaction is open (action transaction? false, bulk transaction: false)" do
    test "a vault-routing create is refused before any vault insert or row write", %{org: org} do
      vault_before = vault_rows()

      assert {:error, %Ash.Error.Invalid{} = err} =
               org |> no_tx_changeset(%{job_title: "ntx", mrn: "MRN-NTX-SECRET"}) |> Ash.create()

      text = Exception.message(err)
      assert text =~ "requires an open transaction"
      refute text =~ "MRN-NTX-SECRET"
      assert vault_rows() == vault_before
      assert patients(org) == 0
    end

    test "a later hook that swaps in a foreign %Masked{} cannot leave the row durable", %{org: org} do
      victim = changeset(org, %{job_title: "victim", mrn: "MRN-VICTIM"}) |> Ash.create!()
      %{rows: [[foreign]]} = @repo.query!("SELECT pii_pat_mrn FROM pat_patient WHERE pat_id = $1", [Ecto.UUID.dump!(victim.id)])
      rows_before = patients(org)
      vault_before = vault_rows()

      assert {:error, %Ash.Error.Invalid{}} =
               org
               |> no_tx_changeset(%{job_title: "thief"})
               |> Ash.Changeset.before_action(&Ash.Changeset.force_change_attribute(&1, :mrn, Samen.Masked.new(foreign, :mrn)))
               |> Ash.create()

      assert patients(org) == rows_before
      assert vault_rows() == vault_before
    end

    test "bulk_create transaction: false refuses each record and writes nothing", %{org: org} do
      vault_before = vault_rows()

      result =
        Ash.bulk_create([%{org_id: org, job_title: "b1", mrn: "MRN-B1"}, %{org_id: org, job_title: "b2", mrn: "MRN-B2"}], Patient, :create,
          transaction: false,
          return_errors?: true,
          authorize?: false
        )

      assert %Ash.BulkResult{status: :error} = result
      assert vault_rows() == vault_before
      assert patients(org) == 0
    end

    test "CONTROL: the same create with the default transaction commits and reveals", %{org: org} do
      assert {:ok, p} = org |> changeset(%{job_title: "ctl", mrn: "MRN-CTL"}) |> Ash.create()
      assert patients(org) == 1

      %{rows: [[token]]} = @repo.query!("SELECT pii_pat_mrn FROM pat_patient WHERE pat_id = $1", [Ecto.UUID.dump!(p.id)])
      assert {:ok, "MRN-CTL"} = Vault.reveal(Samen.Masked.new(token, :mrn), @repo)
    end
  end
end
