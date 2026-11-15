defmodule ErasureResumableTestAgents do
  @moduledoc false

  defmodule Durable do
    @moduledoc false
    use Samen.AI.Agent,
      name: "erz.durable",
      goal_prompt: "Work the goal step by step. Reply FINAL: <answer> when done."
  end
end

defmodule Samen.ErasureResumableTest do
  @moduledoc """
  `Samen.Erasure.shred/2` destroys the key (irreversible) BEFORE the transaction that withdraws the derived AI context
  (fold ledger + fold sources). The pseudonym `subject_ref` those arms need dies with the key, so a failure after the
  shred used to leave the retry with `:no_pseudonym` and a report that claimed completion while runs citing the subject
  were never withdrawn. The erasure is now RESUMABLE: the ref is committed as a `"pending"` marker before the shred.

    * every step of the seal transaction (2-5) is failed in turn AFTER the shred; the retry withdraws the ledger and
      the sources, `FoldSource.withdrawn?/2` fires for the citing run, and the report equals an uninterrupted run's
    * POSITIVE CONTROL: an uninterrupted erasure leaves no marker and withdraws
    * a shredded key with no marker and no earlier completed report fails loudly (tagged error + operator report)
  """
  use ExUnit.Case, async: false
  use Samen.AgentCase

  import Ecto.Query, only: [from: 2]
  import ExUnit.CaptureLog

  alias ErasureResumableTestAgents.Durable
  alias Samen.AI.Agent
  alias Samen.AI.Agent.{Breaker, FoldSource, Run}
  alias Samen.Erasure
  alias Samen.Erasure.Report
  alias Samen.{FaultRepo, Kms, Vault}

  require Ash.Query

  @repo SamenCore.TestRepo
  @summary "[fold #1] the earlier turns, summarized"

  # every named step of the seal transaction (STEPS 2-5), in order
  @steps [
    :seal_vault,
    :redact_non_pii,
    :rollups,
    :file_blobs,
    :blind_index,
    :custom_bag,
    :record_bag,
    :fold_ledger,
    :fold_sources,
    :clear_pending,
    :report,
    :audit,
    :aud_event
  ]

  setup do
    Samen.TestSandbox.shared!(@repo)
    FaultRepo.heal()
    FaultRepo.register_as_repo!()
    prior = Application.get_env(:samen_core, :kms_adapter)
    prior_agent = Application.get_env(:samen_core, Samen.AI.Agent, [])
    Application.put_env(:samen_core, :kms_adapter, Kms.FileBacked)
    Kms.FileBacked.simulate_outage(false)
    Samen.AI.Provider.Scripted.reset()
    Breaker.reset()

    on_exit(fn ->
      FaultRepo.heal()
      Kms.FileBacked.simulate_outage(false)
      Application.put_env(:samen_core, :kms_adapter, prior || Kms.FileBacked)
      Application.put_env(:samen_core, Samen.AI.Agent, prior_agent)
      Samen.AI.Provider.Scripted.reset()
      Breaker.reset()
    end)

    :ok
  end

  defp scope do
    org = Ash.UUID.generate()
    %Samen.Scope{actor: %{id: "u:#{org}", org_id: org, role: :member, plane: :tenant}}
  end

  defp reload(run) do
    [row] =
      Run
      |> Ash.Query.filter(id == ^run.id)
      |> Ash.Query.ensure_selected([:org_id, :transcript])
      |> Ash.read!(authorize?: false)

    row
  end

  defp folds_of(run) do
    {:ok, json} = Vault.reveal(reload(run).transcript, @repo, subject_id: run.id)
    Map.get(Jason.decode!(json), "folds", [])
  end

  defp fold_entry(run_id, pseudonym) do
    %{
      "n" => 1,
      "summary" => @summary,
      "sources" => [
        %{
          "run_id" => run_id,
          "seq" => 1,
          "digest" => :crypto.hash(:sha256, @summary) |> Base.encode16(case: :lower),
          "markers" => [
            %{"resource" => "Samen.Vault", "record_id" => "erz-1", "subject_ref" => Base.encode16(pseudonym, case: :lower)}
          ]
        }
      ]
    }
  end

  # A subject with a live key, and a run whose fold ledger cites it.
  defp seed! do
    sid = "erz-subject-#{System.unique_integer([:positive])}"
    {:ok, _} = Vault.store_field(sid, :pii_email, :emails, "#{sid}@example.com", @repo)
    {:ok, pseudonym} = Vault.pseudonym(sid)
    s = scope()
    Application.put_env(:samen_core, Samen.AI.Agent, provider: scripted_provider())
    script(final: "the answer")
    {:ok, run} = Agent.start(Durable, s, "goal #{sid}")
    {:ok, json} = Vault.reveal(reload(run).transcript, @repo, subject_id: run.id)
    folded = json |> Jason.decode!() |> Map.put("folds", [fold_entry(run.id, pseudonym)])
    run |> reload() |> Ash.Changeset.for_update(:advance, %{transcript: Jason.encode!(folded)}) |> Ash.update!(authorize?: false)
    {sid, s, run}
  end

  defp withdrawn?(run), do: FoldSource.withdrawn?(run.id, @repo)
  defp pending_rows(sid), do: @repo.all(from(p in Report, where: p.subject_id == ^sid and p.outcome == "pending"))

  # the report minus what is per-subject by construction (ids, timestamps)
  defp comparable(report) do
    %{
      outcome: report.outcome,
      sealed: report.vault_rows_sealed,
      redacted: report.non_pii_rows_redacted,
      tiers: update_in(report.tiers, ["kms"], &Map.delete(&1, "attestation_id"))
    }
  end

  test "POSITIVE CONTROL: an uninterrupted erasure withdraws the ledger and the sources, and leaves no marker" do
    {sid, s, run} = seed!()
    assert [%{"summary" => @summary}] = folds_of(run)
    refute withdrawn?(run)
    assert [%{pending: _}] = [%{pending: pending_rows(sid) |> length()}]

    assert {:ok, %{report: report}} = Erasure.shred(sid, repo: @repo, org_id: s.actor.org_id)

    assert [%{"summary" => "[withdrawn: fold #1, source withdrawn]"}] = folds_of(run)
    assert withdrawn?(run)
    assert report.tiers["derived_summaries"] == %{"invalidation" => "performed", "reason" => nil}
    assert pending_rows(sid) == []
    assert Erasure.pending(repo: @repo) |> Enum.all?(&(&1.subject_id != sid))
  end

  for step <- @steps do
    test "a failure after step #{step} (key already destroyed) is resumed: withdrawn, report equals an uninterrupted run's" do
      step = unquote(step)
      {ctl_sid, ctl_s, _} = seed!()
      {:ok, %{report: control}} = Erasure.shred(ctl_sid, repo: @repo, org_id: ctl_s.actor.org_id)

      {sid, s, run} = seed!()
      FaultRepo.fail([{:after_step, step}])

      capture_log(fn ->
        assert {:error, {:erasure_tx_failed, {:injected_after_step, ^step}}} =
                 Erasure.shred(sid, repo: FaultRepo, org_id: s.actor.org_id)
      end)

      FaultRepo.heal()

      # the key is gone, nothing of the tx committed, the marker survived
      refute Kms.FileBacked.key_material_present?(sid)
      assert {:error, :shredded} = Vault.pseudonym(sid)
      assert [%{"summary" => @summary}] = folds_of(run)
      refute withdrawn?(run)
      refute Erasure.erased?(sid, repo: @repo)
      assert [%{subject_id: ^sid}] = Enum.filter(Erasure.pending(repo: @repo), &(&1.subject_id == sid))

      assert {:ok, %{report: report}} = Erasure.shred(sid, repo: @repo, org_id: s.actor.org_id)

      assert [%{"summary" => "[withdrawn: fold #1, source withdrawn]"}] = folds_of(run)
      assert withdrawn?(run)
      assert Erasure.erased?(sid, repo: @repo)
      assert pending_rows(sid) == []
      assert comparable(report) == comparable(control)
    end
  end

  test "a second shred of a completed erasure is still idempotent (earlier completed report, no marker)" do
    {sid, s, _run} = seed!()
    assert {:ok, _} = Erasure.shred(sid, repo: @repo, org_id: s.actor.org_id)
    assert {:ok, %{report: again}} = Erasure.shred(sid, repo: @repo, org_id: s.actor.org_id)
    assert again.outcome == "already_shredded"
    assert again.tiers["derived_summaries"]["reason"] == "pseudonym_shredded"
  end

  test "a failed marker write aborts BEFORE the key is destroyed" do
    {sid, s, run} = seed!()
    FaultRepo.fail([:insert])

    capture_log(fn ->
      assert {:error, {:erasure_pending_failed, _}} = Erasure.shred(sid, repo: FaultRepo, org_id: s.actor.org_id)
    end)

    FaultRepo.heal()
    assert Kms.FileBacked.key_material_present?(sid)
    refute withdrawn?(run)
    assert {:ok, _} = Erasure.shred(sid, repo: @repo, org_id: s.actor.org_id)
    assert withdrawn?(run)
  end

  test "a crash between the marker and the shred is safe: the retry refreshes the one marker and completes" do
    {sid, s, run} = seed!()
    {:ok, pseudonym} = Vault.pseudonym(sid)
    ref = Base.encode16(pseudonym, case: :lower)

    # the state a process death after the marker commit and before Kms.shred leaves behind
    @repo.insert!(%Report{
      subject_id: sid,
      outcome: "pending",
      tiers: %{"pending" => %{"subject_ref" => ref, "disposition" => "performed"}},
      recorded_at: DateTime.utc_now()
    })

    assert Kms.FileBacked.key_material_present?(sid)
    assert {:ok, _} = Erasure.shred(sid, repo: @repo, org_id: s.actor.org_id)
    assert withdrawn?(run)
    assert pending_rows(sid) == []
  end

  describe "shredded but no reference recorded" do
    test "fails loudly with a tagged error and an operator report; never :no_pseudonym, never a success" do
      {sid, s, run} = seed!()
      # the key was destroyed out of band: no marker, no earlier completed report
      assert {:ok, _} = Kms.shred(sid)

      assert {:error, {:shred_reference_lost, %Report{} = report}} = Erasure.shred(sid, repo: @repo, org_id: s.actor.org_id)
      assert report.outcome == "operator_action_required"
      assert report.tiers["derived_summaries"]["reason"] == "shred_reference_lost"
      refute withdrawn?(run)
      assert [%{"summary" => @summary}] = folds_of(run)
      # nothing was sealed and no success report exists
      assert Enum.all?(@repo.all(from(v in Samen.Vault.VaultRow, where: v.subject_id == ^sid)), &(&1.state == "active"))
      refute Erasure.erased?(sid, repo: @repo)
      assert %Report{outcome: "operator_action_required"} = Erasure.latest_report(sid, repo: @repo)

      # asking again is just as loud (the operator report is not a completed erasure)
      assert {:error, {:shred_reference_lost, _}} = Erasure.shred(sid, repo: @repo, org_id: s.actor.org_id)
    end

    test "the operator override completes the DB tiers and DISCLOSES the withdrawal as unavailable" do
      {sid, s, _run} = seed!()
      assert {:ok, _} = Kms.shred(sid)

      assert {:ok, %{report: report}} =
               Erasure.shred(sid, repo: @repo, org_id: s.actor.org_id, acknowledge_lost_reference: true)

      assert report.tiers["derived_summaries"]["reason"] == "pseudonym_shredded"
      assert Erasure.erased?(sid, repo: @repo)
    end
  end
end
