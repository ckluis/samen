defmodule Samen.ErasureBranchesTest do
  @moduledoc """
  ARCH-26 (ADR-049 watch-list): `Samen.Erasure` — the branches whose silent weakening would make an erasure REPORT
  say something the data does not back (the report is what the oracle and the operator read as proof):

    * the report's vault tier counts THIS subject's rows only (another subject's active rows must not leak in)
    * the audit row and the chain entry both carry the attestation id (not the "none" placeholder)
    * the outcome is `shredded` for a keyed subject with no vault rows, `already_shredded` for a re-run over sealed rows
    * `latest_report/2` / `erased?/2` work on the configured default repo, which resolves
      `:non_pii_repo` → `:reveal_grant_repo` → `:verify_repo` (and raises when none is set)
    * the transcript retention window: a junk or non-positive config degrades to the ratified 90 days
  """
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Samen.Erasure
  alias Samen.Reveal.Grants
  alias Samen.Vault

  @repo SamenCore.TestRepo
  @repo_keys [:non_pii_repo, :reveal_grant_repo, :verify_repo]

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(@repo)
    Samen.Kms.FileBacked.simulate_outage(false)
    Application.put_env(:samen_core, :kms_adapter, Samen.Kms.FileBacked)

    prior = for k <- @repo_keys, do: {k, Application.get_env(:samen_core, k)}
    prior_agent = Application.get_env(:samen_core, Samen.AI.Agent)

    on_exit(fn ->
      Samen.Kms.FileBacked.simulate_outage(false)
      Application.put_env(:samen_core, :kms_adapter, Samen.Kms.FileBacked)

      for {k, v} <- prior do
        if v == nil, do: Application.delete_env(:samen_core, k), else: Application.put_env(:samen_core, k, v)
      end

      if prior_agent == nil,
        do: Application.delete_env(:samen_core, Samen.AI.Agent),
        else: Application.put_env(:samen_core, Samen.AI.Agent, prior_agent)
    end)

    :ok
  end

  defp subj, do: "erasure-branch-#{System.unique_integer([:positive])}"

  defp seed(subject_id, n) do
    for i <- 1..n do
      {:ok, _} = Vault.store_field(subject_id, :pii_email, :emails, "p#{i}@example.com", @repo)
    end
  end

  defmodule UncoveredBidx do
    use Ash.Resource, domain: nil, data_layer: Ash.DataLayer.Ets

    attributes do
      uuid_primary_key(:id)
      attribute(:phone_bidx, :string)
    end
  end

  describe "the blind-index precondition runs BEFORE the irreversible key destruction" do
    test "RED: an uncovered _bidx column refuses the shred - the key is live, no report, nothing sealed" do
      mine = subj()
      seed(mine, 2)
      assert Samen.Kms.adapter().key_material_present?(mine)

      assert {:error, {:blind_index_uncovered, [{UncoveredBidx, :phone_bidx}]}} =
               Erasure.shred(mine, repo: @repo, resources: [UncoveredBidx])

      assert Samen.Kms.adapter().key_material_present?(mine), "refused AFTER the key was destroyed"
      assert @repo.aggregate(from(v in Samen.Vault.VaultRow, where: v.subject_id == ^mine and v.state == "active"), :count) == 2
      assert @repo.aggregate(from(r in Samen.Erasure.Report, where: r.subject_id == ^mine), :count) == 0

      # CONTROL: the identical call with a schema erasure can clear erases
      assert {:ok, _} = Erasure.shred(mine, repo: @repo)
      refute Samen.Kms.adapter().key_material_present?(mine)
    end

    test "RED: a derivation that finds NO resources is refused, not reported as nothing-to-clear" do
      mine = subj()
      seed(mine, 1)

      assert {:error, {:blind_index_no_resources, [resources: []]}} = Erasure.shred(mine, repo: @repo, resources: [])
      assert Samen.Kms.adapter().key_material_present?(mine)
    end

    test "the refusal matches only the coverage errors: a spec naming a missing table still fails the write, loudly" do
      mine = subj()
      seed(mine, 1)

      bad = [%{table_name: "no_such_table_zzz", bidx_column: "email_bidx", subject_column: "id"}]

      assert_raise Postgrex.Error, fn -> Erasure.shred(mine, repo: @repo, bidx_specs: bad) end
    end
  end

  describe "the report is about THIS subject" do
    test "vault tier counts only the erased subject's rows; another subject's rows stay active" do
      other = subj()
      mine = subj()
      seed(other, 2)
      seed(mine, 3)

      assert {:ok, %{attestation: att, report: report}} = Erasure.shred(mine)

      assert report.tiers["vault"]["rows_total"] == 3
      assert report.tiers["vault"]["rows_still_active"] == 0
      assert report.vault_rows_sealed == 3

      # POSITIVE CONTROL: the other subject's rows really are untouched and active.
      assert @repo.aggregate(from(v in Samen.Vault.VaultRow, where: v.subject_id == ^other and v.state == "active"), :count) == 2

      # The audit row and the chain entry both name the attestation.
      assert att.attestation_id
      [erased] = Grants.audit_for(mine) |> Enum.filter(&(&1.event == "erased"))
      assert erased.detail =~ "attestation_id=#{att.attestation_id}"
      refute erased.detail =~ "attestation_id=none"

      [entry] =
        @repo.all(from(e in Samen.AuditChain.Entry, where: e.subject_id == ^mine and e.event_type == "erasure"))

      assert entry.detail =~ "attestation_id=#{att.attestation_id}"
      refute entry.detail =~ "attestation_id=none"
    end
  end

  describe "outcome" do
    test "a keyed subject with NO vault rows is a plain 'shredded'; a re-run over sealed rows is 'already_shredded'" do
      keyed = subj()
      :ok = Vault.ensure_subject_key(keyed, @repo)
      assert {:ok, %{report: r}} = Erasure.shred(keyed)
      assert r.outcome == "shredded"
      assert r.vault_rows_sealed == 0

      sealed = subj()
      seed(sealed, 1)
      assert {:ok, %{report: first}} = Erasure.shred(sealed)
      assert first.outcome == "shredded"
      assert {:ok, %{report: again}} = Erasure.shred(sealed)
      assert again.outcome == "already_shredded"
    end
  end

  describe "read side on the configured default repo" do
    test "latest_report/1 and erased?/1 need no :repo option" do
      s = subj()
      seed(s, 1)
      refute Erasure.erased?(s)
      assert {:ok, _} = Erasure.shred(s)

      assert %{subject_id: ^s} = Erasure.latest_report(s)
      assert Erasure.erased?(s)
    end

    defmodule Rec do
      @moduledoc false
      def one(_query) do
        send(self(), {:repo_used, __MODULE__})
        nil
      end
    end

    defp only_repo_key(key) do
      for k <- @repo_keys, do: Application.delete_env(:samen_core, k)
      if key, do: Application.put_env(:samen_core, key, Rec)
    end

    for key <- [:non_pii_repo, :reveal_grant_repo, :verify_repo] do
      test "with only #{key} configured, the default repo IS that repo" do
        only_repo_key(unquote(key))
        assert Erasure.latest_report("nobody") == nil
        assert_received {:repo_used, Rec}
      end
    end

    test "with none configured it raises instead of guessing a repo" do
      only_repo_key(nil)
      assert_raise RuntimeError, ~r/needs a repo/, fn -> Erasure.latest_report("nobody") end
    end
  end

  describe "transcript retention window" do
    defp ttl_days do
      specs = Erasure.default_specs()[:retention_specs]
      assert [_ | _] = specs, "the kernel's transcript resource must derive a retention arm"
      specs |> Enum.map(&div(&1.ttl_seconds, 86_400)) |> Enum.uniq()
    end

    test "a configured positive window is honoured; zero, negative and junk degrade to the ratified 90 days" do
      Application.put_env(:samen_core, Samen.AI.Agent, transcript_retention_days: 30)
      assert ttl_days() == [30]

      Application.put_env(:samen_core, Samen.AI.Agent, transcript_retention_days: 1)
      assert ttl_days() == [1]

      for junk <- [0, -5, "30", nil, 1.5] do
        Application.put_env(:samen_core, Samen.AI.Agent, transcript_retention_days: junk)
        assert ttl_days() == [90], "#{inspect(junk)} must fall back to 90 days"
      end
    end
  end
end
