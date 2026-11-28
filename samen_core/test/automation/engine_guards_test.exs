defmodule Samen.Automation.EngineGuardsTest do
  @moduledoc """
  Engine guards of the E1 automation engine (ADR-039 §4.1, §4.5, §4.7, §7.3),
  each proven against a REAL Postgres DB through the `SamenCore.Support.AutomationFixture`
  mount. Every guarantee carries a positive control beside its refusal.

    * **Schedule scan (§4.1)** — two scans of one due workflow produce one run and advance
      `next_fire_at` once.
    * **Escalation advance (§7.3)** — two advances of the same step notify and advance once.
    * **Loop / depth guards (§4.7)** — a write made by a run carries `{depth, chain}`, so the
      event it captures inherits `depth + 1` and `chain ++ [workflow_id]`.
  """
  use ExUnit.Case, async: false

  require Ash.Query
  require Ecto.Query
  import Ash.Query

  alias SamenCore.TestRepo
  alias SamenCore.Support.AgentMembershipFixture
  alias Samen.Automation.Escalate
  alias SamenCore.Support.AutomationFixture.{Escalation, Run, Target, Workflow}
  alias SamenCore.Support.NotificationFixture.Notification

  @target_key "SamenCore.Support.AutomationFixture.Target"

  setup do
    Samen.TestSandbox.shared!(TestRepo)

    prev_auto = Application.get_env(:samen_core, Samen.Automation)
    Application.put_env(:samen_core, Samen.Automation, workflow_module: Workflow, run_module: Run, repo: TestRepo)

    prev_engine = Application.get_env(:samen_core, Samen.Notifications.Engine)

    Application.put_env(:samen_core, Samen.Notifications.Engine,
      notification_module: SamenCore.Support.NotificationFixture.Notification,
      preference_module: SamenCore.Support.NotificationFixture.NotificationPreference,
      repo: TestRepo
    )

    prev_escalate = Application.get_env(:samen_core, Samen.Automation.Escalate)
    Application.put_env(:samen_core, Samen.Automation.Escalate, escalation_module: Escalation, repo: TestRepo)

    # The owner's real membership is resolved through the host seam (ADR-039 §4.5).
    prev_agent = AgentMembershipFixture.install!()
    AgentMembershipFixture.reset()

    on_exit(fn ->
      if prev_escalate,
        do: Application.put_env(:samen_core, Samen.Automation.Escalate, prev_escalate),
        else: Application.delete_env(:samen_core, Samen.Automation.Escalate)

      if prev_engine,
        do: Application.put_env(:samen_core, Samen.Notifications.Engine, prev_engine),
        else: Application.delete_env(:samen_core, Samen.Notifications.Engine)

      AgentMembershipFixture.restore!(prev_agent)
      AgentMembershipFixture.reset()

      if prev_auto,
        do: Application.put_env(:samen_core, Samen.Automation, prev_auto),
        else: Application.delete_env(:samen_core, Samen.Automation)
    end)

    :ok
  end

  describe "loop and depth guards (ADR-039 §4.7)" do
    test "a workflow whose action writes a record that re-triggers it is refused as :loop" do
      org = Ash.UUID.generate()
      wf = create_workflow!(org, member!(org), actions: [create_target_action()])

      create_target!(org, "seed", :normal)
      drain_rounds(6)

      # The seed fires one run, which writes ONE record; that record's own :created event
      # names this workflow again, so the dispatcher refuses it instead of cascading.
      assert Enum.count(targets(org)) == 2
      assert [%{state: :skipped, error_kind: :loop}] = Enum.filter(runs_for(org, wf.id), &(&1.state == :skipped))
      assert Enum.count(runs_for(org, wf.id), &(&1.state == :succeeded)) == 1
    end

    test "a chain of distinct workflows stops at the depth cap, not before it" do
      org = Ash.UUID.generate()
      prev = Application.get_env(:samen_core, :automation_max_depth)
      Application.put_env(:samen_core, :automation_max_depth, 1)

      on_exit(fn ->
        if prev,
          do: Application.put_env(:samen_core, :automation_max_depth, prev),
          else: Application.delete_env(:samen_core, :automation_max_depth)
      end)

      # Each workflow reacts to one priority and writes the next: low -> normal -> high -> urgent.
      # Event depths: the seed 0, the normal record 1, the high record 2 (> cap 1 => refused).
      w1 = create_workflow!(org, member!(org), when: "low", actions: [create_target_action("normal")])
      w2 = create_workflow!(org, member!(org), when: "normal", actions: [create_target_action("high")])
      w3 = create_workflow!(org, member!(org), when: "high", actions: [create_target_action("urgent")])

      create_target!(org, "seed", :low)
      drain_rounds(8)

      assert org |> targets() |> Enum.map(& &1.priority) |> Enum.sort() == [:high, :low, :normal]
      assert Enum.count(runs_for(org, w1.id), &(&1.state == :succeeded)) == 1
      assert Enum.count(runs_for(org, w2.id), &(&1.state == :succeeded)) == 1
      assert [%{depth: 2}] = Enum.filter(runs_for(org, w3.id), &(&1.error_kind == :depth_exceeded))
    end

    test "a write nested inside a run's write inherits the run's depth and chain" do
      org = Ash.UUID.generate()
      parent = Ash.UUID.generate()

      # A workflow on the NESTED resource (Subject), so the second write is captured and run.
      nested_wf =
        Workflow
        |> Ash.Changeset.for_create(:create, %{
          org_id: org,
          name: "nested-#{System.unique_integer([:positive])}",
          status: :active,
          trigger_kind: :resource_event,
          resource_key: "SamenCore.Support.AutomationFixture.Subject",
          event: :created,
          conditions: [],
          actions: [%{"kind" => "notify", "recipient" => "owner", "event_type" => "workflow.fired"}],
          owner_id: member!(org)
        })
        |> Ash.create!(authorize?: false)

      ctx = %Samen.Automation.Context{org_id: org, workflow_id: parent, subject_ref: "samen:target:x", depth: 2, chain: ["w0"]}

      Target
      |> Ash.Changeset.for_create(:create_nested, %{org_id: org, title: "outer", priority: :normal}, context: Samen.Automation.Actions.Support.write_context(ctx))
      |> Ash.create!(authorize?: false)

      drain_rounds(3)

      # Depth 3 = the run's depth 2 + 1, and the chain names every workflow up to and including the writer.
      assert [%{depth: 3}] = runs_for(org, nested_wf.id)
      jobs = TestRepo.all(Ecto.Query.from(j in Oban.Job, where: j.worker == "Samen.Automation.DispatchWorker"))
      assert [job] = Enum.filter(jobs, &(&1.args["resource_key"] =~ "Subject"))
      assert job.args["chain"] == ["w0", parent]
    end
  end

  describe "schedule scan idempotency (ADR-039 §4.1)" do
    test "two scans of the same due workflow produce one run and advance next_fire_at once" do
      org = Ash.UUID.generate()
      fire_at = DateTime.utc_now() |> DateTime.add(-120, :second) |> DateTime.truncate(:second)
      wf = create_schedule_workflow!(org, member!(org), fire_at)

      # Both scans read the workflow while it is due: each holds the same stale copy.
      [scan_a, scan_b] = [due_copy!(wf), due_copy!(wf)]

      assert {:ok, advanced} = dispatch_due(scan_a)
      assert {:error, error} = dispatch_due(scan_b)
      assert Enum.any?(List.wrap(error.errors), &match?(%Ash.Error.Changes.StaleRecord{}, &1))
      drain_rounds(3)

      assert DateTime.compare(advanced.next_fire_at, fire_at) == :gt
      assert DateTime.compare(Ash.get!(Workflow, wf.id, authorize?: false).next_fire_at, advanced.next_fire_at) == :eq
      assert [%{trigger_kind: :schedule}] = runs_for(org, wf.id)
    end

    test "a duplicate dispatch of one fire time is the same event, the next fire time is a new one" do
      fire_at = DateTime.utc_now() |> DateTime.truncate(:second)
      later = DateTime.add(fire_at, 60, :second)
      wid = Ash.UUID.generate()

      assert Samen.Automation.ScheduleAdvance.event_id(wid, fire_at) ==
               Samen.Automation.ScheduleAdvance.event_id(wid, fire_at)

      refute Samen.Automation.ScheduleAdvance.event_id(wid, fire_at) ==
               Samen.Automation.ScheduleAdvance.event_id(wid, later)

      refute Samen.Automation.ScheduleAdvance.event_id(wid, fire_at) ==
               Samen.Automation.ScheduleAdvance.event_id(Ash.UUID.generate(), fire_at)
    end

    test "the same workflow due again at its next fire time runs again" do
      org = Ash.UUID.generate()
      fire_at = DateTime.utc_now() |> DateTime.add(-120, :second) |> DateTime.truncate(:second)
      wf = create_schedule_workflow!(org, member!(org), fire_at)

      assert {:ok, _} = dispatch_due(due_copy!(wf))

      # Time passes: the advanced fire time is due in its turn.
      wf
      |> Ash.Changeset.for_update(:update, %{next_fire_at: DateTime.add(fire_at, 30, :second)})
      |> Ash.update!(authorize?: false)

      assert {:ok, _} = dispatch_due(due_copy!(wf))
      drain_rounds(3)

      assert [_, _] = runs_for(org, wf.id)
    end
  end

  describe "escalation advance (ADR-039 §7.3)" do
    test "two advances of the same step apply once: the second matches no row" do
      org = Ash.UUID.generate()
      escalation = open_escalation!(org, "advance-twice")

      # Two timer jobs hold the same copy of the escalation, both at step 0.
      stale_a = Ash.get!(Escalation, escalation.id, authorize?: false)
      stale_b = Ash.get!(Escalation, escalation.id, authorize?: false)

      assert {:ok, %{current_step: 1}} = advance_step(stale_a)
      assert {:error, error} = advance_step(stale_b)
      assert Enum.any?(List.wrap(error.errors), &match?(%Ash.Error.Changes.StaleRecord{}, &1))

      assert Ash.get!(Escalation, escalation.id, authorize?: false).current_step == 1
      assert step_notifications(org) == 1
    end

    test "the next step still advances from a current copy (the control)" do
      org = Ash.UUID.generate()
      escalation = open_escalation!(org, "advance-in-order")

      assert {:ok, %{current_step: 1}} = advance_step(escalation)
      assert {:ok, %{current_step: 2}} = advance_step(Ash.get!(Escalation, escalation.id, authorize?: false))
      assert step_notifications(org) == 2
    end
  end

  describe "owner actor (ADR-039 §4.5)" do
    test "a run acts with the owner's real role: a member owner writes, a viewer owner cannot" do
      org = Ash.UUID.generate()
      member_owner = member!(org, :member)
      viewer_owner = member!(org, :viewer)

      member_wf = create_workflow!(org, member_owner, when: "low", actions: [raise_priority_action()])
      viewer_wf = create_workflow!(org, viewer_owner, when: "normal", actions: [raise_priority_action()])

      low = create_target!(org, "low", :low)
      normal = create_target!(org, "normal", :normal)
      drain_rounds(3)

      # The positive control: the same write by a member owner lands.
      assert reload!(low).priority == :urgent
      assert [%{state: :succeeded}] = Enum.filter(runs_for(org, member_wf.id), &(&1.state != :skipped))

      assert reload!(normal).priority == :normal
      assert [%{state: :failed, error_kind: :unauthorized}] = Enum.filter(runs_for(org, viewer_wf.id), &(&1.state != :skipped))
    end

    test "an owner with no membership in the org stops the run as :owner_unavailable" do
      org = Ash.UUID.generate()
      removed = Ash.UUID.generate()
      other_org_member = member!(Ash.UUID.generate(), :admin)

      removed_wf = create_workflow!(org, removed, when: "low", actions: [raise_priority_action()])
      foreign_wf = create_workflow!(org, other_org_member, when: "normal", actions: [raise_priority_action()])

      low = create_target!(org, "low", :low)
      normal = create_target!(org, "normal", :normal)
      drain_rounds(3)

      assert reload!(low).priority == :low
      assert reload!(normal).priority == :normal

      for wf <- [removed_wf, foreign_wf] do
        # The owner is resolved before the conditions are judged, so every event's run stops here.
        runs = runs_for(org, wf.id)
        assert runs != []
        assert Enum.all?(runs, &(&1.state == :skipped and &1.error_kind == :owner_unavailable))
      end
    end

    test "an unwired or failing membership seam retries the run, and its last attempt skips it :internal_error" do
      org = Ash.UUID.generate()
      owner = member!(org, :member)
      prior = Application.get_env(:samen_core, Samen.AI.Agent, [])

      # The positive control: with the seam wired the same job runs and writes.
      wired_wf = create_workflow!(org, owner, when: "low", actions: [raise_priority_action()])
      wired = create_target!(org, "wired", :low)
      assert :ok = perform_run(org, wired_wf, wired, 1)
      assert reload!(wired).priority == :urgent

      for seam <- [nil, {__MODULE__, :failing_seam}] do
        wf = create_workflow!(org, owner, when: "low", actions: [raise_priority_action()])
        target = create_target!(org, "seam #{inspect(seam)}", :low)

        try do
          Application.put_env(:samen_core, Samen.AI.Agent, Keyword.put(prior, :approver_membership, seam))

          # An early attempt errors the job for a retry; nothing is written and the run stays queued.
          {early, _log} = ExUnit.CaptureLog.with_log(fn -> perform_run(org, wf, target, 1) end)
          assert early == {:error, :unavailable}
          assert reload!(target).priority == :low
          assert [%{state: :queued}] = runs_for(org, wf.id)

          # The last attempt finalizes the run skipped :internal_error; still nothing is written.
          {last, _log} = ExUnit.CaptureLog.with_log(fn -> perform_run(org, wf, target, 3) end)
          assert last == :ok
          assert reload!(target).priority == :low
          assert [%{state: :skipped, error_kind: :internal_error}] = runs_for(org, wf.id)
        after
          Application.put_env(:samen_core, Samen.AI.Agent, prior)
        end
      end
    end
  end

  # ---------------------------------------------------------------------------

  defp create_schedule_workflow!(org, owner, fire_at) do
    Workflow
    |> Ash.Changeset.for_create(:create, %{
      org_id: org,
      name: "wf-#{System.unique_integer([:positive])}",
      status: :active,
      trigger_kind: :schedule,
      resource_key: @target_key,
      schedule_cron: "* * * * *",
      next_fire_at: fire_at,
      conditions: [],
      actions: [%{"kind" => "notify", "recipient" => "owner", "event_type" => "workflow.fired"}],
      owner_id: owner
    })
    |> Ash.create!(authorize?: false)
  end

  # The copy of a due workflow a scan holds: read through the scan's own read action.
  defp due_copy!(wf) do
    Workflow
    |> Ash.Query.for_read(:scan_due)
    |> filter(id == ^wf.id)
    |> Ash.read!(authorize?: false)
    |> hd()
  end

  defp dispatch_due(copy) do
    copy |> Ash.Changeset.for_update(:dispatch_due, %{}) |> Ash.update(authorize?: false)
  end

  defp open_escalation!(org, key) do
    past = DateTime.utc_now() |> DateTime.add(-120, :second) |> DateTime.truncate(:second)

    chain =
      for minutes <- [0, 1, 2],
          do: %{"after_minutes" => minutes, "recipient" => "org", "channel" => "in_app"}

    {:ok, escalation} =
      Escalate.open(%{
        org_id: org,
        kind: "test.guard",
        dedupe_key: key,
        subject_ref: "samen:crm.opportunity:#{key}",
        deadline_at: past,
        chain: chain
      })

    escalation
  end

  defp advance_step(copy), do: copy |> Ash.Changeset.for_update(:advance_step, %{}) |> Ash.update(authorize?: false)

  defp step_notifications(org) do
    Notification
    |> filter(org_id == ^org)
    |> filter(event_type == "escalation_step")
    |> Ash.read!(authorize?: false)
    |> length()
  end

  @doc false
  def failing_seam(_user, _org), do: raise("membership store down")

  defp perform_run(org, wf, target, attempt) do
    Samen.Automation.RunWorker.perform(%Oban.Job{
      args: %{
        "workflow_id" => wf.id,
        "org_id" => org,
        "event_id" => target.id,
        "record_id" => target.id,
        "resource_key" => @target_key,
        "event" => "created",
        "trigger_kind" => "resource_event"
      },
      attempt: attempt,
      max_attempts: 3
    })
  end

  defp member!(org, role \\ :member) do
    user = Ash.UUID.generate()
    AgentMembershipFixture.register(user, org, role)
    user
  end

  defp raise_priority_action do
    %{"kind" => "mutate_record", "mode" => "update", "attrs" => %{"priority" => "urgent"}}
  end

  defp reload!(target), do: Ash.get!(Target, target.id, authorize?: false)

  defp create_target_action(priority \\ "normal") do
    %{
      "kind" => "mutate_record",
      "mode" => "create",
      "resource_key" => @target_key,
      "attrs" => %{"title" => "made-by-run", "priority" => priority}
    }
  end

  defp create_workflow!(org, owner, opts) do
    conditions =
      case Keyword.get(opts, :when) do
        nil -> []
        priority -> [%{"attribute" => "priority", "op" => "eq", "values" => [priority]}]
      end

    attrs = %{
      org_id: org,
      name: "wf-#{System.unique_integer([:positive])}",
      status: :active,
      trigger_kind: :resource_event,
      resource_key: @target_key,
      event: :created,
      conditions: conditions,
      actions: Keyword.fetch!(opts, :actions),
      owner_id: owner
    }

    Workflow |> Ash.Changeset.for_create(:create, attrs) |> Ash.create!(authorize?: false)
  end

  defp create_target!(org, title, priority) do
    Target
    |> Ash.Changeset.for_create(:create, %{org_id: org, title: title, priority: priority, email: "p@example.com"})
    |> Ash.create!(authorize?: false)
  end

  defp targets(org), do: Target |> filter(org_id == ^org) |> Ash.read!(authorize?: false)

  defp runs_for(org, workflow_id) do
    Run
    |> filter(org_id == ^org)
    |> filter(workflow_id == ^workflow_id)
    |> Ash.Query.ensure_selected([:org_id])
    |> Ash.Query.sort(inserted_at: :asc)
    |> Ash.read!(authorize?: false)
  end

  # A bounded drain: a cascade that the guards fail to stop must end the test, not hang it.
  defp drain_rounds(n), do: Enum.each(1..n, fn _ -> Oban.drain_queue(queue: :automation) end)
end
