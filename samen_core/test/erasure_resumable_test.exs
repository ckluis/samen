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
    assert pending_rows(sid) == []

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

  test "the retry takes the subject_ref from the marker: the fold ledger and sources are withdrawn after a post-shred failure" do
    {sid, s, run} = seed!()
    FaultRepo.fail([{:after_step, :aud_event}])

    capture_log(fn ->
      assert {:error, {:erasure_tx_failed, _}} = Erasure.shred(sid, repo: FaultRepo, org_id: s.actor.org_id)
    end)

    FaultRepo.heal()
    assert {:error, :shredded} = Vault.pseudonym(sid)
    refute withdrawn?(run)

    assert {:ok, %{report: report}} = Erasure.shred(sid, repo: @repo, org_id: s.actor.org_id)
    assert withdrawn?(run)
    assert [%{"summary" => "[withdrawn: fold #1, source withdrawn]"}] = folds_of(run)
    assert report.tiers["derived_summaries"]["invalidation"] == "performed"
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

  defp put_marker!(subject_id, ref) do
    @repo.insert!(%Report{
      subject_id: subject_id,
      outcome: "pending",
      tiers: %{"pending" => %{"subject_ref" => ref, "disposition" => "performed"}},
      recorded_at: DateTime.utc_now()
    })
  end

  defmodule ShredOutageKms do
    @moduledoc false
    @behaviour Samen.Kms
    alias Samen.Kms.FileBacked
    @impl true
    def generate_subject_key(s), do: FileBacked.generate_subject_key(s)
    @impl true
    def unwrap(s), do: FileBacked.unwrap(s)
    @impl true
    def shred(_s), do: {:error, :unavailable}
    @impl true
    def attest(s), do: FileBacked.attest(s)
    @impl true
    def backups_disabled?, do: FileBacked.backups_disabled?()
    @impl true
    def key_material_present?(s), do: FileBacked.key_material_present?(s)
    @impl true
    def list_active_subjects, do: FileBacked.list_active_subjects()
    @impl true
    def pseudonym(a, b), do: FileBacked.pseudonym(a, b)
  end

  test "marker bookkeeping touches only THIS subject's pending row: another subject's marker and this subject's non-pending report are left alone" do
    {sid, s, _run} = seed!()
    other = "erz-other-#{System.unique_integer([:positive])}"
    other_row = put_marker!(other, "cafe01")

    prior =
      @repo.insert!(%Report{subject_id: sid, outcome: "shredded", tiers: %{"keep" => "me"}, recorded_at: DateTime.utc_now()})

    assert {:ok, _} = Erasure.shred(sid, repo: @repo, org_id: s.actor.org_id)

    # the other subject's marker: untouched (not refreshed to our ref, not cleared)
    assert [%{id: id, tiers: %{"pending" => %{"subject_ref" => "cafe01"}}}] = pending_rows(other)
    assert id == other_row.id
    # this subject's earlier non-pending row: untouched
    assert %Report{outcome: "shredded", tiers: %{"keep" => "me"}} = @repo.get!(Report, prior.id)
    assert pending_rows(sid) == []
  end

  defmodule ShredThenTimeoutKms do
    @moduledoc false
    @behaviour Samen.Kms
    alias Samen.Kms.FileBacked
    @impl true
    def generate_subject_key(s), do: FileBacked.generate_subject_key(s)
    @impl true
    def unwrap(s), do: FileBacked.unwrap(s)
    # a remote delete that SUCCEEDS and whose response then times out
    @impl true
    def shred(s) do
      _ = FileBacked.shred(s)
      {:error, :timeout}
    end
    @impl true
    def attest(s), do: FileBacked.attest(s)
    @impl true
    def backups_disabled?, do: FileBacked.backups_disabled?()
    @impl true
    def key_material_present?(s), do: FileBacked.key_material_present?(s)
    @impl true
    def list_active_subjects, do: FileBacked.list_active_subjects()
    @impl true
    def pseudonym(a, b), do: FileBacked.pseudonym(a, b)
  end

  # CORRECTED EXPECTATION (review S1): this test used to assert the marker was DROPPED on any shred error, on the
  # premise that the key provably survived. The Kms contract does not promise that (see ShredThenTimeoutKms), so the
  # marker is KEPT: it may be the only durable copy of the ref. The retry refreshes it (key live) or reads it (key gone).
  test "a shred error KEEPS this subject's marker (the key may or may not survive); a healthy retry completes" do
    {sid, s, run} = seed!()
    other = "erz-other-#{System.unique_integer([:positive])}"
    put_marker!(other, "cafe02")

    prior =
      @repo.insert!(%Report{subject_id: sid, outcome: "shredded", tiers: %{"keep" => "me"}, recorded_at: DateTime.utc_now()})

    Application.put_env(:samen_core, :kms_adapter, ShredOutageKms)

    assert {:error, {:kms_shred_failed, :unavailable}} = Erasure.shred(sid, repo: @repo, org_id: s.actor.org_id)

    Application.put_env(:samen_core, :kms_adapter, Kms.FileBacked)
    assert [%{tiers: %{"pending" => %{"subject_ref" => ref}}}] = pending_rows(sid)
    assert is_binary(ref)
    assert [%{tiers: %{"pending" => %{"subject_ref" => "cafe02"}}}] = pending_rows(other)
    assert %Report{outcome: "shredded"} = @repo.get!(Report, prior.id)
    assert Kms.FileBacked.key_material_present?(sid)

    # key still live: the retry refreshes the one marker and completes
    assert {:ok, %{report: report}} = Erasure.shred(sid, repo: @repo, org_id: s.actor.org_id)
    assert withdrawn?(run)
    assert report.tiers["derived_summaries"]["invalidation"] == "performed"
    assert pending_rows(sid) == []
  end

  test "a shred that DESTROYED the key but reported a timeout keeps the marker, and the retry withdraws from it" do
    {sid, s, run} = seed!()
    Application.put_env(:samen_core, :kms_adapter, ShredThenTimeoutKms)

    assert {:error, {:kms_shred_failed, :timeout}} = Erasure.shred(sid, repo: @repo, org_id: s.actor.org_id)

    Application.put_env(:samen_core, :kms_adapter, Kms.FileBacked)
    refute Kms.FileBacked.key_material_present?(sid)
    assert [%{tiers: %{"pending" => %{"subject_ref" => _}}}] = pending_rows(sid)
    refute withdrawn?(run)

    assert {:ok, %{report: report}} = Erasure.shred(sid, repo: @repo, org_id: s.actor.org_id)
    assert withdrawn?(run)
    assert [%{"summary" => "[withdrawn: fold #1, source withdrawn]"}] = folds_of(run)
    assert report.tiers["derived_summaries"]["invalidation"] == "performed"
    assert pending_rows(sid) == []
  end

  describe "not inside a caller's transaction (review S2)" do
    test "inside Repo.transaction/1 it refuses, tagged, before anything is read or shredded" do
      {sid, s, run} = seed!()

      assert {:ok, {:error, :erasure_in_transaction}} =
               @repo.transaction(fn -> Erasure.shred(sid, repo: @repo, org_id: s.actor.org_id) end)

      assert Kms.FileBacked.key_material_present?(sid)
      assert pending_rows(sid) == []
      refute withdrawn?(run)
    end

    test "POSITIVE CONTROL: the same call outside a transaction proceeds" do
      {sid, s, run} = seed!()
      assert {:ok, _} = Erasure.shred(sid, repo: @repo, org_id: s.actor.org_id)
      assert withdrawn?(run)
    end
  end

  describe "a citing run the withdrawal walk cannot open (review M1)" do
    defmodule RunKeyOutageKms do
      @moduledoc false
      @behaviour Samen.Kms
      alias Samen.Kms.FileBacked
      @impl true
      def generate_subject_key(s), do: FileBacked.generate_subject_key(s)
      # an outage on ONE subject's key (the citing run's), the rest of the store is healthy
      @impl true
      def unwrap(s) do
        if s == Application.get_env(:samen_core, :erz_blocked_subject), do: {:error, :unavailable}, else: FileBacked.unwrap(s)
      end

      @impl true
      def shred(s), do: FileBacked.shred(s)
      @impl true
      def attest(s), do: FileBacked.attest(s)
      @impl true
      def backups_disabled?, do: FileBacked.backups_disabled?()
      @impl true
      def key_material_present?(s), do: FileBacked.key_material_present?(s)
      @impl true
      def list_active_subjects, do: FileBacked.list_active_subjects()
      @impl true
      def pseudonym(a, b), do: FileBacked.pseudonym(a, b)
    end

    setup do
      on_exit(fn -> Application.delete_env(:samen_core, :erz_blocked_subject) end)
    end

    test "is NOT counted as withdrawn: the tx rolls back, the marker survives, the report is not written, the retry completes" do
      {sid, s, run} = seed!()
      Application.put_env(:samen_core, :kms_adapter, RunKeyOutageKms)
      Application.put_env(:samen_core, :erz_blocked_subject, run.id)

      assert {:error, {:erasure_tx_failed, {:fold_ledger_unavailable, run_id, :transcript_unreadable}}} =
               Erasure.shred(sid, repo: @repo, org_id: s.actor.org_id)

      assert run_id == run.id
      # nothing claims the withdrawal happened
      assert [%{tiers: %{"pending" => %{"subject_ref" => _}}}] = pending_rows(sid)
      refute Erasure.erased?(sid, repo: @repo)
      assert Erasure.latest_report(sid, repo: @repo) == nil
      refute withdrawn?(run)

      # the store heals: the retry resumes from the marker and really withdraws
      Application.put_env(:samen_core, :kms_adapter, Kms.FileBacked)
      Application.delete_env(:samen_core, :erz_blocked_subject)
      assert [%{"summary" => @summary}] = folds_of(run)

      assert {:ok, %{report: report}} = Erasure.shred(sid, repo: @repo, org_id: s.actor.org_id)
      assert [%{"summary" => "[withdrawn: fold #1, source withdrawn]"}] = folds_of(run)
      assert withdrawn?(run)
      assert report.tiers["derived_summaries"]["invalidation"] == "performed"
      assert pending_rows(sid) == []
    end

    test "POSITIVE CONTROL: a citing run whose OWN key was shredded (unreadable by design) is skipped, not a failure" do
      {sid, s, run} = seed!()
      assert {:ok, _} = Kms.shred(run.id)

      assert {:ok, %{report: report}} = Erasure.shred(sid, repo: @repo, org_id: s.actor.org_id)
      assert report.tiers["derived_summaries"]["invalidation"] == "performed"
      assert pending_rows(sid) == []
    end
  end

  test "pending/1 lists unfinished erasures on the configured default repo, oldest first, and not completed ones" do
    prior = for k <- [:non_pii_repo, :reveal_grant_repo, :verify_repo], do: {k, Application.get_env(:samen_core, k)}
    Application.put_env(:samen_core, :non_pii_repo, @repo)

    on_exit(fn ->
      for {k, v} <- prior do
        if v == nil, do: Application.delete_env(:samen_core, k), else: Application.put_env(:samen_core, k, v)
      end
    end)

    a = "erz-pend-a-#{System.unique_integer([:positive])}"
    put_marker!(a, "aa")
    {done, ds, _} = seed!()
    assert {:ok, _} = Erasure.shred(done, repo: @repo, org_id: ds.actor.org_id)

    pending = Erasure.pending()
    assert Enum.any?(pending, &(&1.subject_id == a))
    refute Enum.any?(pending, &(&1.subject_id == done))
  end

  describe "a stuck erasure is reported (review S3)" do
    test "a marker older than the age is reported value-free; a fresh one is not" do
      old = "erz-stuck-#{System.unique_integer([:positive])}"
      fresh = "erz-fresh-#{System.unique_integer([:positive])}"
      @repo.insert!(%Report{subject_id: old, outcome: "pending", tiers: %{"pending" => %{"subject_ref" => "abcd1234feed"}}, recorded_at: DateTime.add(DateTime.utc_now(), -3600, :second)})
      put_marker!(fresh, "beef5678cafe")

      log = capture_log(fn -> assert Erasure.report_stuck(repo: @repo) == 1 end)
      assert log =~ "erasure_stuck_marker"
      refute log =~ old
      refute log =~ fresh
      refute log =~ "abcd1234feed"
      refute log =~ "beef5678cafe"
    end

    test "POSITIVE CONTROL: with only fresh markers nothing is reported" do
      put_marker!("erz-fresh-#{System.unique_integer([:positive])}", "beef5678cafe")
      log = capture_log(fn -> assert Erasure.report_stuck(repo: @repo) == 0 end)
      refute log =~ "erasure_stuck_marker"
    end

    test "Retention.sweep surfaces it on every sweep" do
      sid = "erz-stuck-#{System.unique_integer([:positive])}"
      @repo.insert!(%Report{subject_id: sid, outcome: "pending", tiers: %{"pending" => %{"subject_ref" => "abcd1234feed"}}, recorded_at: DateTime.add(DateTime.utc_now(), -3600, :second)})
      log = capture_log(fn -> Samen.Retention.sweep([], repo: @repo) end)
      assert log =~ "erasure_stuck_marker"
      refute log =~ sid
    end
  end

  test "a pending marker is not a report: latest_report ignores it, and a marker newer than a completed report does not shadow it" do
    {sid, s, _run} = seed!()
    assert {:ok, %{report: done}} = Erasure.shred(sid, repo: @repo, org_id: s.actor.org_id)
    put_marker!(sid, "ff00")
    assert %Report{id: id, outcome: "shredded"} = Erasure.latest_report(sid, repo: @repo)
    assert id == done.id

    only = "erz-only-pending-#{System.unique_integer([:positive])}"
    put_marker!(only, "ff01")
    assert Erasure.latest_report(only, repo: @repo) == nil
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

      assert report.tiers["derived_summaries"]["reason"] == "shred_reference_lost_acknowledged"
      assert report.tiers["derived_summaries"]["invalidation"] == "unavailable"
      assert Erasure.erased?(sid, repo: @repo)

      # the override is AUDITED: the lifecycle row names it, with the acting operator
      assert [audit] =
               Samen.Reveal.Grants.audit_for(sid, repo: @repo)
               |> Enum.filter(&(&1.event == "erased"))

      assert audit.detail =~ "acknowledged_lost_reference=true"
      assert audit.detail =~ "derived_summary_invalidation=unavailable"
    end

    test "the override is also recorded on the tamper-evident chain row; an ordinary erasure's chain row is not" do
      chain_detail = fn sid, org ->
        @repo.one(
          from(e in Samen.AuditChain.Entry,
            where: e.org_id == ^org and e.subject_id == ^sid and e.event_type == "erasure",
            select: e.detail
          )
        )
      end

      {sid, s, _run} = seed!()
      assert {:ok, _} = Kms.shred(sid)
      assert {:ok, _} = Erasure.shred(sid, repo: @repo, org_id: s.actor.org_id, acknowledge_lost_reference: true)
      assert chain_detail.(sid, s.actor.org_id) =~ "acknowledged_lost_reference=true"

      {sid2, s2, _} = seed!()
      assert {:ok, _} = Erasure.shred(sid2, repo: @repo, org_id: s2.actor.org_id)
      detail = chain_detail.(sid2, s2.actor.org_id)
      assert detail =~ "derived_summary_invalidation=performed"
      refute detail =~ "acknowledged_lost_reference"
    end

    test "an ordinary (non-overridden) erasure's audit row does not carry the acknowledgement" do
      {sid, s, _run} = seed!()
      assert {:ok, _} = Erasure.shred(sid, repo: @repo, org_id: s.actor.org_id)
      audits = Samen.Reveal.Grants.audit_for(sid, repo: @repo) |> Enum.filter(&(&1.event == "erased"))
      assert [%{detail: detail}] = audits
      refute detail =~ "acknowledged_lost_reference"
      assert detail =~ "derived_summary_invalidation=performed"
    end

    test "the operator report is written ONCE; a repeated refusal returns the same row" do
      {sid, s, _run} = seed!()
      assert {:ok, _} = Kms.shred(sid)
      assert {:error, {:shred_reference_lost, first}} = Erasure.shred(sid, repo: @repo, org_id: s.actor.org_id)
      assert {:error, {:shred_reference_lost, second}} = Erasure.shred(sid, repo: @repo, org_id: s.actor.org_id)
      assert first.id == second.id

      assert 1 ==
               @repo.aggregate(
                 from(p in Report, where: p.subject_id == ^sid and p.outcome == "operator_action_required"),
                 :count
               )
    end

    test "another subject's operator report is never returned as this subject's" do
      {sid, s, _run} = seed!()
      other = "erz-other-#{System.unique_integer([:positive])}"

      @repo.insert!(%Report{
        subject_id: other,
        outcome: "operator_action_required",
        tiers: %{},
        recorded_at: DateTime.utc_now()
      })

      assert {:ok, _} = Kms.shred(sid)
      assert {:error, {:shred_reference_lost, %Report{subject_id: ^sid}}} =
               Erasure.shred(sid, repo: @repo, org_id: s.actor.org_id)
    end

    test "another subject's marker is never taken as this subject's reference" do
      {sid, s, run} = seed!()
      other = "erz-other-#{System.unique_integer([:positive])}"
      put_marker!(other, "deadbeef")
      assert {:ok, _} = Kms.shred(sid)

      assert {:error, {:shred_reference_lost, _}} = Erasure.shred(sid, repo: @repo, org_id: s.actor.org_id)
      refute withdrawn?(run)
      assert [%{tiers: %{"pending" => %{"subject_ref" => "deadbeef"}}}] = pending_rows(other)
    end

    test "a malformed marker (no subject_ref) is not a reference" do
      {sid, s, _run} = seed!()
      @repo.insert!(%Report{subject_id: sid, outcome: "pending", tiers: %{"pending" => %{}}, recorded_at: DateTime.utc_now()})
      assert {:ok, _} = Kms.shred(sid)
      assert {:error, {:shred_reference_lost, _}} = Erasure.shred(sid, repo: @repo, org_id: s.actor.org_id)
    end
  end
end
