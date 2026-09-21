defmodule Samen.Automation.RunDefinitionPinTest do
  @moduledoc """
  T162 — **automation run-definition pinning** (ADR-039 §3.3/§8.1/§8.4).

  The defect: `RunWorker` re-read the Workflow row at `perform` time
  (`load_workflow/2` → `Compile.run(wf.actions, ctx)`), so a tenant edit landing
  between ENQUEUE and EXECUTION — or between Oban retries of one job — changed what
  an already-triggered run executed, and a historical `Automation.Run` row could not
  be interpreted against the definition that actually ran.

  The fix pins a SNAPSHOT: `DispatchWorker` stamps the definition + its content
  digest into the `RunWorker` job args at enqueue; `RunRecord` copies both onto the
  Run row from those same args; `RunWorker` executes the pinned definition.

  ## What these tests hold

    * **RED 1** — edit-after-enqueue executes **v1**. Enqueue, mutate the workflow to
      v2, then execute: the observable effect is v1's notification, never v2's.
      Pre-fix this test executes v2 — that is the red.
    * **RED 2 (CONTROL, must pass on BOTH sides)** — a workflow paused (tenant
      switch) or operator-killed AFTER enqueue still SKIPS. The two kill-switches and
      the owner stay LIVE-READ; only the definition is pinned. This passed before the
      fix and must still pass after — it is the proof the fix did not over-pin.
    * **RED 3** — the Run row is interpretable: `definition_digest` is v1's digest,
      not v2's, and `digest(run.definition) == run.definition_digest`, so the row
      resolves to exactly the definition that ran.
    * **Anti-tautology control for RED 1** — with NO edit between enqueue and
      execution the run still executes v1 AND the digest assertion is load-bearing:
      the digest of a MUTATED definition map differs, so an assertion that "passes
      for any map" would fail here.
    * **Retry** — a retry of the same job (same args) re-executes the SAME pin, even
      after the workflow has been edited.

  ## Sabotage

  `scripts/sabotages/364-t162-run-definition-pin-bypassed.patch` reverts the worker
  to the live `load_workflow(...).actions`/`.conditions`; RED 1, RED 3 and the retry
  test must fail. `365-t162-dispatch-pin-not-stamped.patch` removes the enqueue-time
  stamp; RED 1 and RED 3 must fail.
  """
  use ExUnit.Case, async: false

  require Ash.Query
  import Ash.Query

  alias Samen.Automation.Definition
  alias SamenCore.Support.AutomationFixture.{Run, Target, Workflow}
  alias SamenCore.Support.NotificationFixture.Notification
  alias SamenCore.TestRepo

  @target_key "SamenCore.Support.AutomationFixture.Target"

  @v1 [%{"kind" => "notify", "recipient" => "owner", "event_type" => "pin.v1"}]
  @v2 [%{"kind" => "notify", "recipient" => "owner", "event_type" => "pin.v2"}]

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(TestRepo)
    Ecto.Adapters.SQL.Sandbox.mode(TestRepo, {:shared, self()})

    prev = %{
      engine: Application.get_env(:samen_core, Samen.Notifications.Engine),
      auto: Application.get_env(:samen_core, Samen.Automation)
    }

    Application.put_env(:samen_core, Samen.Notifications.Engine,
      notification_module: Notification,
      preference_module: SamenCore.Support.NotificationFixture.NotificationPreference,
      repo: TestRepo
    )

    Application.put_env(:samen_core, Samen.Automation,
      workflow_module: Workflow,
      run_module: Run,
      repo: TestRepo
    )

    on_exit(fn ->
      restore(:samen_core, Samen.Notifications.Engine, prev.engine)
      restore(:samen_core, Samen.Automation, prev.auto)
    end)

    :ok
  end

  # ---------------------------------------------------------------------------
  # RED 1 — an edit landing between enqueue and execution must NOT change what the
  # already-triggered run executes.

  test "RED 1 — a workflow edited AFTER enqueue still executes the pinned v1 definition" do
    org = Ash.UUID.generate()
    owner = Ash.UUID.generate()

    wf = create_workflow!(org, owner, actions: @v1)

    # Trigger: EventCapture inserts the DispatchWorker job in the write txn.
    create_target!(org)

    # Drain WITHOUT recursion: DispatchWorker runs and enqueues the RunWorker job,
    # which is NOT executed in this pass. That gap is the edit window the bug lives in.
    drain_once()

    # The tenant edits the rule while the run sits queued.
    edit_actions!(wf, @v2)

    # Now the queued run executes.
    drain_once()

    # v1's effect exists; v2's never happened.
    assert event_types(org) == ["pin.v1"]

    [run] = runs_for(org, wf.id)
    assert run.state == :succeeded
    assert [%{"kind" => "notify", "status" => "succeeded"}] = jsonify(run.outcome)
  end

  test "RED 1b — a CONDITION edited after enqueue does not re-gate the queued run" do
    org = Ash.UUID.generate()
    owner = Ash.UUID.generate()

    # v1 gates on priority == :normal, which the subject satisfies.
    wf =
      create_workflow!(org, owner,
        actions: @v1,
        conditions: [%{"attribute" => "priority", "op" => "eq", "values" => ["normal"]}]
      )

    create_target!(org, priority: :normal)
    drain_once()

    # The tenant narrows the gate to :urgent after the run is already triggered.
    edit!(wf, %{conditions: [%{"attribute" => "priority", "op" => "eq", "values" => ["urgent"]}]})

    drain_once()

    [run] = runs_for(org, wf.id)
    assert run.state == :succeeded
    assert event_types(org) == ["pin.v1"]
  end

  # ---------------------------------------------------------------------------
  # RED 2 — the CONTROL. Passes BEFORE and AFTER the fix: the kill-switches stay
  # LIVE-READ, so pinning the definition must not pin the right to execute.

  test "RED 2 (control) — a workflow PAUSED after enqueue still skips, pin or no pin" do
    org = Ash.UUID.generate()
    owner = Ash.UUID.generate()

    wf = create_workflow!(org, owner, actions: @v1)

    create_target!(org)
    drain_once()

    edit!(wf, %{status: :paused})

    drain_once()

    [run] = runs_for(org, wf.id)
    assert run.state == :skipped
    assert run.error_kind == :killed
    assert event_types(org) == []
  end

  test "RED 2 (control) — a workflow OPERATOR-KILLED after enqueue still skips" do
    org = Ash.UUID.generate()
    owner = Ash.UUID.generate()

    wf = create_workflow!(org, owner, actions: @v1)

    create_target!(org)
    drain_once()

    {:ok, killed} =
      wf
      |> Ash.Changeset.for_update(:operator_kill, %{reason: :operator}, authorize?: false)
      |> Ash.update(authorize?: false)

    assert killed.disabled_by_operator_at

    drain_once()

    [run] = runs_for(org, wf.id)
    assert run.state == :skipped
    assert run.error_kind == :killed
    assert event_types(org) == []
  end

  test "RED 2 (control) — an owner removed after enqueue still skips :owner_unavailable" do
    org = Ash.UUID.generate()
    owner = Ash.UUID.generate()

    wf = create_workflow!(org, owner, actions: @v1)

    create_target!(org)
    drain_once()

    edit!(wf, %{owner_id: nil})

    drain_once()

    [run] = runs_for(org, wf.id)
    assert run.state == :skipped
    assert run.error_kind == :owner_unavailable
    assert event_types(org) == []
  end

  # ---------------------------------------------------------------------------
  # RED 3 — the Run row is interpretable against the definition that actually ran.

  test "RED 3 — the Run row carries the pinned definition + digest of v1, never v2" do
    org = Ash.UUID.generate()
    owner = Ash.UUID.generate()

    wf = create_workflow!(org, owner, actions: @v1)

    create_target!(org)
    drain_once()
    edit_actions!(wf, @v2)
    drain_once()

    [run] = runs_for(org, wf.id)

    v1_digest = Definition.digest(definition_of(@v1))
    v2_digest = Definition.digest(definition_of(@v2))

    # The two definitions are genuinely distinct identities (the assertion below
    # could not be satisfied by a constant).
    refute v1_digest == v2_digest

    assert run.definition_digest == v1_digest
    refute run.definition_digest == v2_digest

    # The row RESOLVES: the stored definition is the one the digest names, after a
    # full jsonb round trip.
    assert Definition.digest(run.definition) == run.definition_digest
    assert run.definition["actions"] == @v1
    assert run.definition["resource_key"] == @target_key
  end

  test "RED 3b — the enqueued job args carry the pin, stamped at dispatch with the rule in hand" do
    org = Ash.UUID.generate()
    owner = Ash.UUID.generate()

    wf = create_workflow!(org, owner, actions: @v1)

    create_target!(org)
    drain_once()

    args = run_worker_args(wf.id)

    assert args["definition"]["actions"] == @v1
    assert args["definition_digest"] == Definition.digest(definition_of(@v1))
  end

  # ---------------------------------------------------------------------------
  # Anti-tautology control for RED 1 — no edit at all: v1 still runs, and the
  # digest assertion is load-bearing (a mutated definition map digests differently,
  # so "assert the digest matches" cannot pass for an arbitrary map).

  test "control — with NO edit between enqueue and perform the run executes v1, for the right reason" do
    org = Ash.UUID.generate()
    owner = Ash.UUID.generate()

    wf = create_workflow!(org, owner, actions: @v1)

    create_target!(org)
    drain_once()
    drain_once()

    assert event_types(org) == ["pin.v1"]

    [run] = runs_for(org, wf.id)
    assert run.state == :succeeded
    assert run.definition_digest == Definition.digest(definition_of(@v1))

    # Load-bearing: mutate the pinned map at the assertion site and the SAME
    # assertion fails — the digest is computed from the definition, not a constant.
    mutated = put_in(definition_of(@v1), ["actions"], @v2)
    refute run.definition_digest == Definition.digest(mutated)

    mutated_key = put_in(definition_of(@v1), ["resource_key"], "Some.Other.Resource")
    refute run.definition_digest == Definition.digest(mutated_key)
  end

  # ---------------------------------------------------------------------------
  # Retries execute the SAME pin — the job args carry it, so attempt N sees exactly
  # what attempt 1 saw, even across an edit.

  test "a retry of the same job re-executes the pinned v1, not the edited v2" do
    org = Ash.UUID.generate()
    owner = Ash.UUID.generate()

    wf = create_workflow!(org, owner, actions: @v1)

    create_target!(org)
    drain_once()

    args = run_worker_args(wf.id)

    edit_actions!(wf, @v2)
    drain_once()

    assert event_types(org) == ["pin.v1"]

    # The retry: Oban hands the worker the SAME args it was enqueued with.
    assert :ok = Samen.Automation.RunWorker.perform(%Oban.Job{args: args})

    assert event_types(org) == ["pin.v1", "pin.v1"]
  end

  # ---------------------------------------------------------------------------
  # Helpers

  defp definition_of(actions, conditions \\ []) do
    %{"actions" => actions, "conditions" => conditions, "resource_key" => @target_key}
  end

  defp create_workflow!(org, owner, opts) do
    Workflow
    |> Ash.Changeset.for_create(:create, %{
      org_id: org,
      name: "wf-#{System.unique_integer([:positive])}",
      status: :active,
      trigger_kind: :resource_event,
      resource_key: @target_key,
      event: :created,
      conditions: Keyword.get(opts, :conditions, []),
      actions: Keyword.fetch!(opts, :actions),
      owner_id: owner
    })
    |> Ash.create!(authorize?: false)
  end

  defp edit_actions!(wf, actions), do: edit!(wf, %{actions: actions})

  defp edit!(wf, attrs) do
    # Re-read first: the caller's struct may be stale after an earlier edit.
    [current] =
      Workflow
      |> filter(id == ^wf.id)
      |> Ash.Query.ensure_selected([:org_id])
      |> Ash.read!(authorize?: false)

    current
    |> Ash.Changeset.for_update(:update, attrs, authorize?: false)
    |> Ash.update!(authorize?: false)
  end

  defp create_target!(org, opts \\ []) do
    Target
    |> Ash.Changeset.for_create(:create, %{
      org_id: org,
      title: "t-#{System.unique_integer([:positive])}",
      priority: Keyword.get(opts, :priority, :normal),
      owner_id: Keyword.get(opts, :owner_id),
      tags: [],
      email: "person@example.com"
    })
    |> Ash.create!(authorize?: false)
  end

  # ONE pass over the jobs available right now. Jobs enqueued DURING the pass (the
  # RunWorker job a DispatchWorker inserts) are left queued — that gap is the edit
  # window this suite exercises.
  defp drain_once, do: Oban.drain_queue(queue: :automation)

  defp runs_for(org, workflow_id) do
    Run
    |> filter(org_id == ^org)
    |> filter(workflow_id == ^workflow_id)
    |> Ash.Query.ensure_selected([:org_id])
    |> Ash.Query.sort(inserted_at: :asc)
    |> Ash.read!(authorize?: false)
  end

  defp event_types(org) do
    Notification
    |> filter(org_id == ^org)
    |> Ash.Query.ensure_selected([:org_id])
    |> Ash.Query.sort(inserted_at: :asc)
    |> Ash.read!(authorize?: false)
    |> Enum.map(& &1.event_type)
  end

  defp run_worker_args(workflow_id) do
    %{rows: [[args]]} =
      TestRepo.query!(
        "SELECT args FROM oban_jobs WHERE worker = $1 AND args->>'workflow_id' = $2",
        ["Samen.Automation.RunWorker", to_string(workflow_id)]
      )

    args
  end

  defp jsonify(term), do: term |> Jason.encode!() |> Jason.decode!()

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, val), do: Application.put_env(app, key, val)
end
