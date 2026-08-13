defmodule Samen.DsarAuditPreconditionTest do
  @moduledoc """
  O9 — the DSAR "who exported what" access record is a HARD PRECONDITION of returning the
  bundle, NOT best-effort. Under any audit-chain outage the export must FAIL (no bundle),
  so `Samen.Dsar.export_subject/2` never hands back an export it could not account for on
  the tamper-evident, non-repudiation compliance surface.

  Positive control (anti-tautology): a NORMAL export still returns `{:ok, bundle}` AND
  writes the `dsar_export` audit record.
  """
  use ExUnit.Case, async: false

  alias SamenCore.TestRepo, as: Repo
  alias Samen.Dsar
  alias Samen.Vault

  @repo Repo

  # A repo whose CHAIN APPEND fails (insert returns an error) while reads still work — models
  # a chain outage (repo/table/seq error) local to the audit write. Reads delegate so the
  # export can still build (and thus we prove the export is refused DESPITE having the data).
  defmodule FailingChainRepo do
    def all(q), do: SamenCore.TestRepo.all(q)
    def one(q), do: SamenCore.TestRepo.one(q)
    def insert(_row), do: {:error, :audit_ledger_down}
    def insert(_row, _opts), do: {:error, :audit_ledger_down}
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    Samen.Kms.FileBacked.simulate_outage(false)
    Application.put_env(:samen_core, :kms_adapter, Samen.Kms.FileBacked)
    Application.put_env(:samen_core, :non_pii_repo, Repo)
    on_exit(fn -> Application.delete_env(:samen_core, :non_pii_repo) end)
    :ok
  end

  defp subj, do: "dsar-precond-#{System.unique_integer([:positive])}"

  defp seed(subject_id) do
    {:ok, _} = Vault.store_field(subject_id, :pii_email, :emails, "alice@example.com", @repo)
    {:ok, _} = Vault.store_field(subject_id, :pii_name, :full_name, "Alice Anders", @repo)
    :ok
  end

  describe "audit write FAILS → export is REFUSED (no bundle, no unaccounted export)" do
    test "returns {:error, {:audit_write_failed, _}} and writes NO dsar_export record" do
      s = subj()
      seed(s)

      # Operator plane, no grant → the bundle is fully buildable (masked values), so the ONLY
      # reason to fail is the audit-write precondition — not a missing-data artifact.
      assert {:error, {:audit_write_failed, _reason}} =
               Dsar.export_subject(s, repo: FailingChainRepo, plane: :operator, grant?: false, org_id: "org-1")

      # Non-repudiation intact: because the append failed, NO access record exists for `s`.
      refute s in Dsar.affected_subjects(repo: @repo)
    end
  end

  describe "positive control — a normal export still succeeds AND records the access" do
    test "returns {:ok, bundle} and the dsar_export record lands on the chain" do
      s = subj()
      seed(s)

      assert {:ok, bundle} = Dsar.export_subject(s, repo: @repo, plane: :tenant, org_id: "org-1")
      assert bundle.subject_id == s

      # The access WAS recorded — the subject now appears on the tamper-evident chain, and a
      # subsequent export sees the prior dsar_export event on its own trail.
      assert s in Dsar.affected_subjects(repo: @repo)
      assert {:ok, bundle2} = Dsar.export_subject(s, repo: @repo, plane: :tenant, org_id: "org-1")
      assert "dsar_export" in Enum.map(bundle2.audit_trail, & &1.event_type)
    end
  end
end
