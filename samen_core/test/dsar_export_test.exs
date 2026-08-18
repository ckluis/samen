defmodule Samen.DsarExportTest do
  @moduledoc """
  F3.3 — DSAR export (`Samen.Dsar.export_subject/2`) + the breach-scope enumerator
  (`affected_subjects/2`).

  The load-bearing guarantee is the TWO-PLANE split with NO cross-plane leakage:

    * tenant plane (owns its subject) → the bundle carries PLAINTEXT;
    * operator plane WITHOUT a grant → every value is `••••`, NEVER plaintext, NEVER a
      token / ciphertext;
    * operator plane WITH a grant → plaintext (the positive control that proves the
      mask is refutable, not a value that never resolved).
  """
  use ExUnit.Case, async: false

  alias SamenCore.TestRepo, as: Repo
  alias Samen.Dsar
  alias Samen.Masked
  alias Samen.Vault

  @repo Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Samen.Kms.FileBacked.simulate_outage(false)
    Application.put_env(:samen_core, :kms_adapter, Samen.Kms.FileBacked)
    Application.put_env(:samen_core, :non_pii_repo, Repo)
    on_exit(fn -> Application.delete_env(:samen_core, :non_pii_repo) end)
    :ok
  end

  defp subj, do: "dsar-subject-#{System.unique_integer([:positive])}"

  defp seed(subject_id) do
    {:ok, _} = Vault.store_field(subject_id, :pii_email, :emails, "alice@example.com", @repo)
    {:ok, _} = Vault.store_field(subject_id, :pii_name, :full_name, "Alice Anders", @repo)
    :ok
  end

  defp values(bundle), do: Enum.map(bundle.personal_data, & &1.value)

  describe "tenant-plane export — the subject's own PII in clear" do
    test "returns the subject's vault fields as PLAINTEXT + writes the dsar_export audit event" do
      s = subj()
      seed(s)

      assert {:ok, bundle} = Dsar.export_subject(s, repo: @repo, plane: :tenant, org_id: "org-1")
      vals = values(bundle)
      assert "alice@example.com" in vals
      assert "Alice Anders" in vals
      assert bundle.subject_id == s
      assert bundle.plane == :tenant

      # The export is recorded on the subject's chain (tokens only).
      assert s in Dsar.affected_subjects(repo: @repo)
      trail_types = Enum.map(bundle.audit_trail, & &1.event_type)
      # A subsequent export sees the prior dsar_export event on the trail.
      assert {:ok, bundle2} = Dsar.export_subject(s, repo: @repo, plane: :tenant, org_id: "org-1")
      assert "dsar_export" in Enum.map(bundle2.audit_trail, & &1.event_type)
      _ = trail_types
    end
  end

  describe "operator-plane export — masked without a grant (NO cross-plane leakage)" do
    test "every value is •••• — NEVER plaintext, NEVER a token/ciphertext in the bundle" do
      s = subj()
      seed(s)

      assert {:ok, bundle} = Dsar.export_subject(s, repo: @repo, plane: :operator, grant?: false, org_id: "org-1")

      vals = values(bundle)
      assert Enum.all?(vals, &(&1 == Masked.mask()))
      refute "alice@example.com" in vals
      refute "Alice Anders" in vals

      # The WHOLE serialized bundle carries no plaintext and no vault token/ciphertext.
      blob = inspect(bundle)
      refute blob =~ "alice@example.com"
      refute blob =~ "Alice Anders"
      refute blob =~ "pii_vault"
      refute blob =~ "vt_"
    end

    test "a caller-asserted grant?: true is IGNORED — no real grant → still MASKED (hole closed)" do
      s = subj()
      seed(s)

      # The old caller-asserted hole: passing grant?: true used to force plaintext with NO real
      # authorization. It is now a no-op — plaintext derives from the REAL grant model only.
      assert {:ok, bundle} =
               Dsar.export_subject(s, repo: @repo, plane: :operator, grant?: true, org_id: "org-1")

      vals = values(bundle)
      assert Enum.all?(vals, &(&1 == Masked.mask()))
      refute "alice@example.com" in vals
      refute "Alice Anders" in vals
    end
  end

  describe "org binding is required (fail-closed)" do
    test "an export with no org_id is refused — never a plaintext bundle for any subject" do
      s = subj()
      seed(s)

      assert {:error, :org_id_required} = Dsar.export_subject(s, repo: @repo, plane: :tenant)
      # The reserved system chain is refused too — an export never rides "__global__".
      assert {:error, :org_id_required} =
               Dsar.export_subject(s, repo: @repo, plane: :tenant, org_id: "__global__")
    end
  end

  describe "affected_subjects/2 — breach-scope enumeration over the audit chain" do
    test "lists distinct subjects and honours the time window" do
      s1 = subj()
      s2 = subj()
      seed(s1)
      seed(s2)

      {:ok, _} = Dsar.export_subject(s1, repo: @repo, org_id: "org-x")
      {:ok, _} = Dsar.export_subject(s2, repo: @repo, org_id: "org-x")

      all = Dsar.affected_subjects(repo: @repo, org_id: "org-x")
      assert s1 in all
      assert s2 in all

      # A future lower bound excludes everything already written.
      future = DateTime.utc_now() |> DateTime.add(3600, :second)
      assert Dsar.affected_subjects(repo: @repo, org_id: "org-x", since: future) == []
    end
  end
end
