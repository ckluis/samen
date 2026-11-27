defmodule Samen.Automation.SystemActionsAuthzTest do
  @moduledoc """
  authz-6 review 2: the Automation scope's system actions were `bypass … authorize_if(always())` for ANY actor, and
  each `due_scan` is a read with no org filter. Who legitimately runs them:

    * the AshOban triggers (no actor): Workflow `:scan_due` / `:dispatch_due`, Reminder `:due_scan` / `:fire`,
      Escalation `:due_scan` / `:advance_step` → authorized only for `AshOban.Checks.AshObanInteraction`;
    * the operator kill-switch: Workflow `:operator_kill` / `:operator_rearm`, run by `Samen.Automation.Health` (which
      gates on the operator role in application code) and `Samen.Automation.Breaker`, both as `authorize?: false`;
    * the kernel pipeline: Run `:record` / `:start` / `:finalize` via `Samen.Automation.RunRecord`, `authorize?: false`.

  No tenant actor, an owner included, may run any of them. The scheduler (the positive control) is exercised by the
  existing `workflow_test` / `reminder_test` / `escalation_test` triggers; the operator flow by
  `observability_test` and `samen_web`'s `operator_automation_health_test`; the new tests below add one control each.
  """
  use ExUnit.Case, async: false

  alias SamenCore.Support.AutomationFixture.{Escalation, Reminder, Run, Workflow}
  alias SamenCore.TestRepo

  @roles [:viewer, :member, :admin, :owner]

  setup do
    Samen.TestSandbox.shared!(TestRepo)
    :ok
  end

  defp scope(org, role), do: %Samen.Scope{actor: %{id: "u:#{role}:#{org}", org_id: org, role: role, kind: :tenant, plane: :tenant}}

  defp past, do: DateTime.utc_now() |> DateTime.add(-120, :second) |> DateTime.truncate(:second)

  @doc false
  def workflow!(org) do
    Workflow
    |> Ash.Changeset.for_create(
      :create,
      %{
        org_id: org,
        name: "wf-#{System.unique_integer([:positive])}",
        status: :active,
        trigger_kind: :schedule,
        schedule_cron: "* * * * *",
        next_fire_at: past(),
        conditions: [],
        actions: [%{"kind" => "notify", "recipient" => "owner", "event_type" => "workflow.fired"}],
        owner_id: Ash.UUID.generate()
      },
      authorize?: false
    )
    |> Ash.create!()
  end

  @doc false
  def reminder!(org) do
    Reminder
    |> Ash.Changeset.for_create(
      :schedule,
      %{org_id: org, recipient_id: Ash.UUID.generate(), subject_ref: "samen:crm.opportunity:x", remind_at: past(), note: "n", source: :user},
      authorize?: false
    )
    |> Ash.create!()
  end

  @doc false
  def escalation!(org) do
    Escalation
    |> Ash.Changeset.for_create(
      :open,
      %{
        org_id: org,
        kind: "test.ladder",
        dedupe_key: "k-#{System.unique_integer([:positive])}",
        subject_ref: "samen:crm.opportunity:x",
        deadline_at: past(),
        chain: [%{"after_minutes" => 0, "recipient" => "org", "channel" => "in_app"}]
      },
      authorize?: false
    )
    |> Ash.create!()
  end

  defp reload(resource, id), do: Ash.get!(resource, id, authorize?: false)

  describe "the cross-org scans are the scheduler's" do
    for {resource, scan, make} <- [{Workflow, :scan_due, :workflow!}, {Reminder, :due_scan, :reminder!}, {Escalation, :due_scan, :escalation!}] do
      test "#{inspect(resource)}.#{scan}: a tenant actor of any role is refused; the ordinary read stays org-scoped" do
        resource = unquote(resource)
        scan = unquote(scan)
        [org_a, org_b] = [Ash.UUID.generate(), Ash.UUID.generate()]
        row_a = apply(__MODULE__, unquote(make), [org_a])
        _row_b = apply(__MODULE__, unquote(make), [org_b])

        for role <- @roles do
          assert {:error, %Ash.Error.Forbidden{}} = Ash.read(resource, action: scan, scope: scope(org_a, role)), "#{role} ran #{scan}"
        end

        # control: the plain read is org-scoped and open, so the refusal is the action's
        assert [%{id: id}] = Ash.read!(resource, scope: scope(org_a, :viewer))
        assert id == row_a.id
      end
    end
  end

  describe "the trigger update actions are the scheduler's" do
    test "Workflow.dispatch_due, Reminder.fire and Escalation.advance_step refuse every tenant role and change nothing" do
      org = Ash.UUID.generate()
      wf = workflow!(org)
      rem = reminder!(org)
      esc = escalation!(org)

      for role <- @roles, {row, action} <- [{wf, :dispatch_due}, {rem, :fire}, {esc, :advance_step}] do
        assert {:error, %Ash.Error.Forbidden{}} =
                 row |> Ash.Changeset.for_update(action, %{}, scope: scope(org, role)) |> Ash.update(),
               "#{role} ran #{action}"
      end

      assert reload(Workflow, wf.id).next_fire_at == wf.next_fire_at
      assert reload(Reminder, rem.id).state == :scheduled
      assert reload(Escalation, esc.id).state == esc.state
    end
  end

  describe "the operator kill-switch is not a tenant action" do
    test "a tenant actor of ANY role cannot kill or re-arm a workflow; the operator path (authorize?: false) can" do
      org = Ash.UUID.generate()
      wf = workflow!(org)

      for role <- @roles do
        assert {:error, %Ash.Error.Forbidden{}} =
                 wf |> Ash.Changeset.for_update(:operator_kill, %{reason: :operator}, scope: scope(org, role)) |> Ash.update(),
               "#{role} killed"
      end

      assert is_nil(reload(Workflow, wf.id).disabled_by_operator_at)

      # positive control: Health / Breaker run it as `authorize?: false`
      assert {:ok, killed} = wf |> Ash.Changeset.for_update(:operator_kill, %{reason: :operator}, authorize?: false) |> Ash.update()
      assert killed.disabled_by_operator_at

      for role <- @roles do
        assert {:error, %Ash.Error.Forbidden{}} =
                 killed |> Ash.Changeset.for_update(:operator_rearm, %{}, scope: scope(org, role)) |> Ash.update(),
               "#{role} re-armed"
      end

      assert reload(Workflow, wf.id).disabled_by_operator_at
      assert {:ok, rearmed} = killed |> Ash.Changeset.for_update(:operator_rearm, %{}, authorize?: false) |> Ash.update()
      assert is_nil(rearmed.disabled_by_operator_at)
    end
  end

  describe "the run log is written by the kernel pipeline only" do
    test "a tenant actor of ANY role cannot create or update a Run; the pipeline (authorize?: false) can" do
      org = Ash.UUID.generate()
      wf = workflow!(org)
      attrs = fn key -> %{org_id: org, workflow_id: wf.id, dispatch_key: key, trigger_kind: :schedule, subject_ref: "samen:x:y", depth: 0} end

      for role <- @roles do
        assert {:error, %Ash.Error.Forbidden{}} =
                 Run |> Ash.Changeset.for_create(:record, attrs.("forged-#{role}"), scope: scope(org, role)) |> Ash.create(),
               "#{role} recorded a run"
      end

      assert [] = Ash.read!(Run, authorize?: false) |> Enum.filter(&(&1.org_id == org))

      # positive control: the pipeline's own write
      assert {:ok, run} = Run |> Ash.Changeset.for_create(:record, attrs.("real"), authorize?: false) |> Ash.create()

      for role <- @roles do
        assert {:error, %Ash.Error.Forbidden{}} =
                 run |> Ash.Changeset.for_update(:start, %{}, scope: scope(org, role)) |> Ash.update(),
               "#{role} started a run"
      end
    end
  end

  describe "the escalation writes are the engine's, not an actor's" do
    test "a tenant actor of ANY role, in this org or another, cannot open, refresh, resolve or cancel an escalation; the engine (authorize?: false) can" do
      org = Ash.UUID.generate()
      other_org = Ash.UUID.generate()
      esc = escalation!(org)

      for org_id <- [org, other_org], role <- @roles do
        as = scope(org_id, role)

        assert {:error, %Ash.Error.Forbidden{}} =
                 Escalation
                 |> Ash.Changeset.for_create(
                   :open,
                   %{org_id: org_id, kind: "forged", dedupe_key: "forged-#{role}", subject_ref: "samen:x:y", deadline_at: past(), chain: []},
                   scope: as
                 )
                 |> Ash.create(),
               "#{role}@#{org_id} opened an escalation"

        for {action, args} <- [refresh: %{deadline_at: past()}, resolve: %{}, cancel: %{}] do
          assert {:error, %Ash.Error.Forbidden{}} =
                   esc |> Ash.Changeset.for_update(action, args, scope: as) |> Ash.update(),
                 "#{role}@#{org_id} ran #{action}"
        end
      end

      assert reload(Escalation, esc.id).state == :open
      assert [] = Ash.read!(Escalation, authorize?: false) |> Enum.filter(&(&1.kind == "forged"))

      # positive control: the engine's own write (Samen.Automation.Escalate runs them `authorize?: false`)
      assert {:ok, resolved} = esc |> Ash.Changeset.for_update(:resolve, %{}, authorize?: false) |> Ash.update()
      assert resolved.state == :resolved
    end
  end
end
