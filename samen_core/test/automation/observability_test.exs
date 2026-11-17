defmodule Samen.Automation.ObservabilityTest.SuppressAll do
  @moduledoc "The `Samen.Delivery.Chokepoint` `suppression_module` contract — always suppressed (reused from T40's actions_test.exs to produce a REAL fired-but-failed run for the table test)."
  def suppressed?(_org_id, _subscriber_id), do: true
end

defmodule Samen.Automation.ObservabilityTest do
  @moduledoc """
  T42 — E8 automation observability (ADR-039 §8; the run log, the operator
  health view, the operator kill-switch). Exercised end-to-end against a REAL
  Postgres DB via the `awf`/`sar`/`asj`/`sat` `SamenCore.Support.AutomationFixture`
  mount (the SAME domain T39-T41 already live in — framework-first).

  ## Done-criterion 1 — table test: every pipeline outcome produces a Run row

  `fired -> succeeded` (row 1), `fired -> failed` (row 2, a REAL suppressed
  send_email — T40's exact suppression fixture), `skipped :conditions_unmet`
  (row 3), `skipped :invalid_conditions` (row 4) — each asserts workflow_id,
  state, and started_at <= finished_at with a non-negative duration_ms.

  ## Done-criterion 2 — kill-switch red + control, switch state audited

  A killed workflow's ALREADY-QUEUED run finalizes `:skipped/:killed` (red) —
  the RunWorker re-check, the load-bearing half (T39's F5 finding: dispatch's
  own filter would never even enqueue it; this proves the SECOND check
  independently, by enqueueing directly). An untouched sibling workflow fires
  normally in the SAME drain (control — the kill is per-workflow, not
  global). `Samen.Automation.Health.kill/4` additionally proves the switch
  FLIP is audited (`Samen.AuditEvent.for_subject/2`) and idempotent (calling
  kill twice never double-stamps `disabled_by_operator_at`).

  ## Done-criterion 3 — INV-1/INV-2: no PII, no leak, token-blind

  A direct `information_schema` sweep on `sar_run` (the `no_pii_columns`
  physical-column check, applied directly since `Run` is deliberately NOT
  `Samen.Aggregate.Resource` — see `define_run/5`'s moduledoc). The red-path
  proof: the send_email-suppressed run's `webhook_secret`-carrying `Context` is
  live-confirmed (this suite's own log output) to reach Reactor's raw error
  term — `Run.outcome` for that SAME row is asserted to carry NEITHER the
  webhook secret NOR any subject value, ONLY the bounded
  `index/kind/status/error_kind/duration_ms` keys (the allowlist boundary in
  `Samen.Automation.RunRecord.bounded_outcomes/1`). Sabotage-refutable: swap in
  a version of `extract_failure/1` that `inspect/1`s the raw reason (or drop
  the RunFinalize/RunRecord allowlist) and this exact assertion goes red — see
  `scripts/sabotages/37-t42-run-outcome-leak.patch`.

  ## Done-criterion 4 — dispatch_key uniqueness under concurrent duplicate dispatch

  Two `RunRecord.open!/2` calls for the SAME (workflow_id, event_id) — the
  at-least-once/retry shape — upsert onto ONE row, never two.

  ## Sabotage target — the RunWorker kill re-check

  `scripts/sabotages/38-t42-runworker-kill-recheck-bypass.patch` neutralizes
  `RunWorker.kill_switch/1` to always `:ok`; the NAMED red test above
  ("an already-queued run of a killed workflow finalizes :skipped/:killed")
  must fail.
  """
  use ExUnit.Case, async: false

  require Ash.Query
  import Ash.Query

  alias Samen.Automation.{Health, RunRecord}
  alias Samen.Automation.ObservabilityTest.SuppressAll
  alias Samen.OperatorPlane.Actor
  alias SamenCore.Support.AutomationFixture.{Run, Target, Workflow}
  alias SamenCore.Support.NotificationFixture.Notification
  alias SamenCore.TestRepo

  @target_key "SamenCore.Support.AutomationFixture.Target"

  setup do
    Samen.TestSandbox.shared!(TestRepo)

    prev = %{
      engine: Application.get_env(:samen_core, Samen.Notifications.Engine),
      auto: Application.get_env(:samen_core, Samen.Automation),
      chokepoint: Application.get_env(:samen_core, Samen.Delivery.Chokepoint),
      send_email: Application.get_env(:samen_core, Samen.Automation.Actions.SendEmail)
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
      restore(:samen_core, Samen.Delivery.Chokepoint, prev.chokepoint)
      restore(:samen_core, Samen.Automation.Actions.SendEmail, prev.send_email)
    end)

    :ok
  end

  # ---------------------------------------------------------------------------
  # Done-criterion 1 — table test (fired/skipped/failed, rule id + timing).

  test "row 1 — fired notify -> Run row :succeeded, workflow id + monotonic timing" do
    org = Ash.UUID.generate()
    owner = Ash.UUID.generate()

    wf =
      create_workflow!(org, owner,
        conditions: [],
        actions: [%{"kind" => "notify", "recipient" => "owner", "event_type" => "workflow.fired"}]
      )

    create_target!(org)
    drain()

    [run] = runs_for(org, wf.id)

    assert run.workflow_id == wf.id
    assert run.org_id == org
    assert run.state == :succeeded
    assert run.trigger_kind == :resource_event
    assert is_nil(run.error_kind)
    assert %DateTime{} = run.started_at
    assert %DateTime{} = run.finished_at
    assert DateTime.compare(run.finished_at, run.started_at) in [:gt, :eq]
    assert run.duration_ms >= 0
    assert [%{"kind" => "notify", "status" => "succeeded"}] = jsonify(run.outcome)
  end

  test "row 2 — fired send_email (suppressed) -> Run row :failed, error_kind carried through" do
    org = Ash.UUID.generate()
    owner = Ash.UUID.generate()

    Application.put_env(:samen_core, Samen.Delivery.Chokepoint, suppression_module: SuppressAll)

    wf =
      create_workflow!(org, owner,
        conditions: [],
        actions: [%{"kind" => "send_email", "to" => "owner", "template_key" => "welcome"}]
      )

    create_target!(org)
    drain()

    [run] = runs_for(org, wf.id)

    assert run.state == :failed
    assert run.error_kind == :suppressed
    assert %DateTime{} = run.started_at
    assert %DateTime{} = run.finished_at
    assert run.duration_ms >= 0
    assert [%{"kind" => "send_email", "status" => "failed", "error_kind" => "suppressed"}] =
             jsonify(run.outcome)
  end

  test "row 3 — a non-matching condition -> Run row :skipped/:conditions_unmet, never :running" do
    org = Ash.UUID.generate()
    owner = Ash.UUID.generate()

    wf =
      create_workflow!(org, owner,
        conditions: [%{"attribute" => "priority", "op" => "eq", "values" => ["urgent"]}],
        actions: [%{"kind" => "notify", "recipient" => "owner", "event_type" => "workflow.fired"}]
      )

    create_target!(org, priority: :low)
    drain()

    [run] = runs_for(org, wf.id)

    assert run.state == :skipped
    assert run.error_kind == :conditions_unmet
    # A conditions-gate skip is decided BEFORE any action fires — started_at
    # was never stamped (the run never transitioned :queued -> :running).
    assert is_nil(run.started_at)
    assert %DateTime{} = run.finished_at
  end

  test "row 4 — a condition that fails to parse -> Run row :skipped/:invalid_conditions" do
    org = Ash.UUID.generate()
    owner = Ash.UUID.generate()

    wf =
      create_workflow!(org, owner,
        conditions: [%{"attribute" => "priority", "op" => "not_a_real_op", "values" => ["x"]}],
        actions: [%{"kind" => "notify", "recipient" => "owner", "event_type" => "workflow.fired"}]
      )

    create_target!(org)
    drain()

    [run] = runs_for(org, wf.id)

    assert run.state == :skipped
    assert run.error_kind == :invalid_conditions
  end

  # ---------------------------------------------------------------------------
  # Done-criterion 2 — kill-switch red + control; switch state audited.

  test "an already-queued run of a killed workflow finalizes :skipped/:killed (red) " <>
         "while a sibling workflow in the SAME drain fires normally (control)" do
    org = Ash.UUID.generate()
    owner = Ash.UUID.generate()

    killed =
      create_workflow!(org, owner,
        conditions: [],
        actions: [%{"kind" => "notify", "recipient" => "owner", "event_type" => "workflow.fired"}]
      )

    alive =
      create_workflow!(org, owner,
        conditions: [],
        actions: [%{"kind" => "notify", "recipient" => "owner", "event_type" => "workflow.fired"}]
      )

    # Kill AFTER creation but BEFORE the trigger — DispatchWorker's own filter
    # (status active AND disabled_by_operator_at IS NULL) would never even
    # enqueue a run for `killed` normally; enqueue the RunWorker job DIRECTLY
    # (bypassing DispatchWorker) to prove the SECOND, already-queued-half
    # check independently — exactly T39's F5 methodology.
    {:ok, killed} =
      killed
      |> Ash.Changeset.for_update(:operator_kill, %{reason: :operator}, authorize?: false)
      |> Ash.update(authorize?: false)

    assert killed.disabled_by_operator_at

    event_id = Ash.UUID.generate()

    {:ok, _job} =
      Oban.insert(
        Samen.Automation.RunWorker.new(%{
          "org_id" => org,
          "workflow_id" => to_string(killed.id),
          "trigger_kind" => "manual",
          "event" => "manual",
          "event_id" => event_id,
          "subject_ref" => "samen:workflow:#{killed.id}:#{event_id}",
          "changed" => [],
          "depth" => 0,
          "chain" => []
        })
      )

    create_target!(org)
    drain()

    [killed_run] = runs_for(org, killed.id)
    assert killed_run.state == :skipped
    assert killed_run.error_kind == :killed

    [alive_run] = runs_for(org, alive.id)
    assert alive_run.state == :succeeded
  end

  test "Health.kill/4 audits the switch flip and is idempotent (double-kill never re-stamps)" do
    org = Ash.UUID.generate()
    owner = Ash.UUID.generate()

    wf =
      create_workflow!(org, owner,
        conditions: [],
        actions: [%{"kind" => "notify", "recipient" => "owner", "event_type" => "workflow.fired"}]
      )

    operator = Actor.new(Ash.UUID.generate(), :operator_admin)

    assert {:ok, killed_once} = Health.kill(operator, org, to_string(wf.id))
    stamp = killed_once.disabled_by_operator_at
    assert killed_once.disabled_reason == :operator

    # Idempotent: a second kill call is a no-op that preserves the ORIGINAL
    # stamp (fail-safe — "killing is idempotent").
    assert {:ok, killed_twice} = Health.kill(operator, org, to_string(wf.id))
    assert DateTime.compare(killed_twice.disabled_by_operator_at, stamp) == :eq

    events = Samen.AuditEvent.for_subject(TestRepo, to_string(wf.id))
    assert length(events) >= 2
    assert Enum.all?(events, &(&1.actor_id == operator.id))
    assert Enum.all?(events, &(&1.correlation_id == org))
    assert Enum.any?(events, &String.contains?(&1.detail, "operator_kill"))

    # Re-arm clears both columns, also audited.
    assert {:ok, rearmed} = Health.rearm(operator, org, to_string(wf.id))
    assert is_nil(rearmed.disabled_by_operator_at)
    assert is_nil(rearmed.disabled_reason)
  end

  test "Health.kill/rearm refuse a workflow that belongs to another org (cross-tenant, crafted id)" do
    org_a = Ash.UUID.generate()
    org_b = Ash.UUID.generate()
    owner = Ash.UUID.generate()

    wf_b =
      create_workflow!(org_b, owner,
        conditions: [],
        actions: [%{"kind" => "notify", "recipient" => "owner", "event_type" => "workflow.fired"}]
      )

    admin = Actor.new(Ash.UUID.generate(), :operator_admin)

    # Red: an operator vouched for org A cannot kill/rearm org B's workflow by id.
    assert {:error, :not_found} = Health.kill(admin, org_a, to_string(wf_b.id))
    assert {:error, :not_found} = Health.rearm(admin, org_a, to_string(wf_b.id))
    assert is_nil(Ash.get!(wf_b.__struct__, wf_b.id, authorize?: false).disabled_by_operator_at)

    # Positive control: the owning org's id works.
    assert {:ok, killed} = Health.kill(admin, org_b, to_string(wf_b.id))
    assert killed.disabled_reason == :operator
  end

  test "an operator_readonly actor may VIEW but may NOT kill (RBAC gate, red + control)" do
    org = Ash.UUID.generate()
    owner = Ash.UUID.generate()

    wf =
      create_workflow!(org, owner,
        conditions: [],
        actions: [%{"kind" => "notify", "recipient" => "owner", "event_type" => "workflow.fired"}]
      )

    readonly = Actor.new(Ash.UUID.generate(), :operator_readonly)
    admin = Actor.new(Ash.UUID.generate(), :operator_admin)

    # Red: readonly may not kill.
    assert {:error, :not_authorized} = Health.kill(readonly, org, to_string(wf.id))
    # Readonly control: it MAY view.
    assert {:ok, _summary} = Health.summary(readonly, org)
    # A non-operator actor (e.g. a bare tenant scope) may not view either.
    assert {:error, :not_authorized} = Health.summary(%Samen.Scope{actor: %{id: "x", org_id: org, role: :member}}, org)

    # Control: an admin CAN kill.
    assert {:ok, _} = Health.kill(admin, org, to_string(wf.id))
  end

  # ---------------------------------------------------------------------------
  # Done-criterion 3 — INV-1/INV-2: no PII column, no leak in outcome rows.

  test "sar_run carries no pii_ column, physically (the no_pii_columns bar, INV-2)" do
    %{rows: rows} =
      TestRepo.query!(
        "SELECT column_name FROM information_schema.columns WHERE table_name = $1 AND column_name LIKE $2",
        ["sar_run", "pii_%"]
      )

    assert rows == []
  end

  test "no payload plaintext / no webhook secret ever lands in Run.outcome (INV-1 red-path proof)" do
    org = Ash.UUID.generate()
    owner = Ash.UUID.generate()

    Application.put_env(:samen_core, Samen.Delivery.Chokepoint, suppression_module: SuppressAll)

    # This workflow's Context (built by RunWorker.fire/5) carries `webhook_secret`
    # (every Workflow gets one at create, ADR-039 §5.3) AND the subject's real
    # attribute values — exactly the material Reactor's raw error term embeds
    # (this suite's own log output shows the full Context inside
    # `%Reactor.Error.Invalid.RunStepError{step: %Reactor.Step{arguments: [...]}}`).
    # The suppressed send_email failure below is the vehicle that reaches that
    # error path.
    wf =
      create_workflow!(org, owner,
        conditions: [],
        actions: [%{"kind" => "send_email", "to" => "owner", "template_key" => "welcome"}]
      )

    assert wf.webhook_secret

    create_target!(org, email: "victim@example.com")
    drain()

    [run] = runs_for(org, wf.id)
    assert run.state == :failed

    # Positive assertion: the outcome carries ONLY bounded allowlist keys —
    # never `ctx`/`step`/`ssn`/`email`/`secret`/anything not in
    # `RunRecord`'s `index/kind/status/error_kind/meta/duration_ms` allowlist.
    [outcome] = jsonify(run.outcome)
    assert Map.keys(outcome) -- ["index", "kind", "status", "error_kind", "meta", "duration_ms"] == []

    # Red-path: the whole row — outcome jsonb AND every other column — never
    # carries the secret, a vt_* token, or the subject's plaintext email. T162's
    # `definition` jsonb is included deliberately: it is the second freeform column
    # on this table, and `webhook_secret` is EXCLUDED from the pinned definition
    # precisely so a snapshot can never copy credential material onto a Run row
    # (`Samen.Automation.Definition`).
    encoded =
      run
      |> Map.take([:outcome, :subject_ref, :error_kind, :state, :definition, :definition_digest])
      |> Jason.encode!()
    refute encoded =~ wf.webhook_secret
    refute encoded =~ "victim@example.com"
    refute encoded =~ "vt_"
  end

  # ---------------------------------------------------------------------------
  # Done-criterion 4 — dispatch_key uniqueness under concurrent duplicate dispatch.

  test "RunRecord.open!/2 upserts on dispatch_key — a concurrent duplicate lands on ONE row" do
    org = Ash.UUID.generate()
    owner = Ash.UUID.generate()

    wf =
      create_workflow!(org, owner,
        conditions: [],
        actions: [%{"kind" => "notify", "recipient" => "owner", "event_type" => "workflow.fired"}]
      )

    event_id = Ash.UUID.generate()
    args = %{"org_id" => org, "event_id" => event_id, "trigger_kind" => "manual", "subject_ref" => "ref"}

    run1 = RunRecord.open!(wf, args)
    run2 = RunRecord.open!(wf, args)

    assert run1.id == run2.id
    assert length(runs_for(org, wf.id)) == 1
  end

  # ---------------------------------------------------------------------------
  # Helpers

  # ---------------------------------------------------------------------------
  # Honest reads — a read that FAILED is an outage or a skipped run, never "no data".

  test "RED: Health.summary/runs answer {:error, :unavailable} when the read fails (they answered an empty fleet); healthy control" do
    org = Ash.UUID.generate()
    owner = Ash.UUID.generate()
    operator = Actor.new(Ash.UUID.generate(), :operator_admin)

    create_workflow!(org, owner,
      actions: [%{"kind" => "notify", "recipient" => "owner", "event_type" => "workflow.fired"}]
    )

    # POSITIVE CONTROL: the same calls on the real modules answer the fleet
    assert {:ok, [%{total_runs: 0}]} = Health.summary(operator, org)
    assert {:ok, []} = Health.runs(operator, org)

    ExUnit.CaptureLog.capture_log(fn ->
      assert {:error, :unavailable} = Health.summary(operator, org, workflow_module: String)
      assert {:error, :unavailable} = Health.summary(operator, org, run_module: String)
      assert {:error, :unavailable} = Health.runs(operator, org, run_module: String)
    end)
  end

  test "RED: a malformed record id skips the run instead of reading as an empty subject " <>
         "(which every neq / not_in / is_nil gate passes); the readable subject fires (control)" do
    org = Ash.UUID.generate()
    owner = Ash.UUID.generate()

    wf =
      create_workflow!(org, owner,
        conditions: [%{"attribute" => "priority", "op" => "neq", "values" => ["urgent"]}],
        actions: [%{"kind" => "notify", "recipient" => "owner", "event_type" => "workflow.fired"}]
      )

    target = create_target!(org)

    args = fn record_id ->
      %{
        "workflow_id" => to_string(wf.id),
        "org_id" => org,
        "resource_key" => @target_key,
        "record_id" => record_id,
        "event" => "created",
        "event_id" => Ash.UUID.generate(),
        "trigger_kind" => "resource_event",
        "depth" => 0,
        "chain" => []
      }
    end

    ExUnit.CaptureLog.capture_log(fn ->
      assert :ok = Samen.Automation.RunWorker.perform(run_job(args.("not-a-uuid")))
    end)

    assert notified(org, owner) == 0
    assert [%{state: :skipped, error_kind: :internal_error}] = runs_for(org, wf.id)

    # POSITIVE CONTROL: the same workflow against the readable record fires
    assert :ok = Samen.Automation.RunWorker.perform(run_job(args.(to_string(target.id))))
    assert notified(org, owner) == 1
  end

  test "RED: a subject whose resource cannot be classified skips the run (an EMPTY subject passes every neq gate and fires it); a classifiable one fires (control)" do
    org = Ash.UUID.generate()
    owner = Ash.UUID.generate()

    wf =
      create_workflow!(org, owner,
        conditions: [%{"attribute" => "priority", "op" => "neq", "values" => ["urgent"]}],
        actions: [%{"kind" => "notify", "recipient" => "owner", "event_type" => "workflow.fired"}]
      )

    target = create_target!(org)

    args = fn resource_key ->
      %{
        "workflow_id" => to_string(wf.id),
        "org_id" => org,
        "resource_key" => resource_key,
        "record_id" => to_string(target.id),
        "event" => "created",
        "event_id" => Ash.UUID.generate(),
        "trigger_kind" => "resource_event",
        "depth" => 0,
        "chain" => []
      }
    end

    # `String` resolves to a loaded module but is not a Spark resource: its columns cannot be classified.
    # `Nope.Missing` does not resolve at all.
    for key <- ["String", "Nope.Missing"] do
      ExUnit.CaptureLog.capture_log(fn ->
        assert :ok = Samen.Automation.RunWorker.perform(run_job(args.(key)))
      end)
    end

    assert notified(org, owner) == 0
    assert [%{state: :skipped, error_kind: :internal_error}, %{state: :skipped, error_kind: :internal_error}] = runs_for(org, wf.id)

    # POSITIVE CONTROL: the same workflow and record under the real resource key fires
    assert :ok = Samen.Automation.RunWorker.perform(run_job(args.(@target_key)))
    assert notified(org, owner) == 1
  end

  defp subject_args(wf, org, record_id, event) do
    %{
      "workflow_id" => to_string(wf.id),
      "org_id" => org,
      "resource_key" => @target_key,
      "record_id" => record_id,
      "event" => event,
      "event_id" => Ash.UUID.generate(),
      "trigger_kind" => "resource_event",
      "depth" => 0,
      "chain" => []
    }
  end

  @notify [%{"kind" => "notify", "recipient" => "owner", "event_type" => "workflow.fired"}]

  test "RED: a created/updated run whose subject was DELETED before the run skips :no_subject_record (it ran its gates against %{}); the live subject fires (control)" do
    org = Ash.UUID.generate()
    owner = Ash.UUID.generate()

    wf =
      create_workflow!(org, owner,
        conditions: [%{"attribute" => "priority", "op" => "neq", "values" => ["urgent"]}],
        actions: @notify
      )

    target = create_target!(org)

    # POSITIVE CONTROL: the record is there -> the neq gate passes on its real value and the run fires
    assert :ok = Samen.Automation.RunWorker.perform(run_job(subject_args(wf, org, to_string(target.id), "created")))
    assert notified(org, owner) == 1

    # RED: the record id names nothing (deleted between the event and the run), for both record events
    for event <- ["created", "updated"] do
      assert :ok = Samen.Automation.RunWorker.perform(run_job(subject_args(wf, org, Ash.UUID.generate(), event)))
    end

    assert notified(org, owner) == 1
    # `inserted_at` has second resolution, so the order of runs created in the same second is not defined: compare as a set
    assert [{:skipped, :no_subject_record}, {:skipped, :no_subject_record}, {:succeeded, nil}] =
             org |> runs_for(wf.id) |> Enum.map(&{&1.state, &1.error_kind}) |> Enum.sort()
  end

  test "a destroyed run's subject is expected to be gone: a workflow without conditions fires, one with conditions skips :no_subject_record (no snapshot to judge them on)" do
    org = Ash.UUID.generate()
    owner = Ash.UUID.generate()
    plain = create_workflow!(org, owner, event: :destroyed, conditions: [], actions: @notify)

    gated =
      create_workflow!(org, owner,
        event: :destroyed,
        conditions: [%{"attribute" => "priority", "op" => "neq", "values" => ["urgent"]}],
        actions: @notify
      )

    assert :ok = Samen.Automation.RunWorker.perform(run_job(subject_args(plain, org, Ash.UUID.generate(), "destroyed")))
    assert notified(org, owner) == 1
    assert [%{state: :succeeded}] = runs_for(org, plain.id)

    assert :ok = Samen.Automation.RunWorker.perform(run_job(subject_args(gated, org, Ash.UUID.generate(), "destroyed")))
    assert notified(org, owner) == 1
    assert [%{state: :skipped, error_kind: :no_subject_record}] = runs_for(org, gated.id)
  end

  test "a destroyed run whose conditions read only event metadata (`changed`) is judged on them and fires; one needing an attribute value (alone or mixed in) is skipped :no_subject_record" do
    org = Ash.UUID.generate()
    owner = Ash.UUID.generate()
    changed_cond = %{"attribute" => "priority", "op" => "changed", "values" => []}
    attr_cond = %{"attribute" => "priority", "op" => "neq", "values" => ["urgent"]}

    meta_only = create_workflow!(org, owner, event: :destroyed, conditions: [changed_cond], actions: @notify)
    attr_only = create_workflow!(org, owner, event: :destroyed, conditions: [attr_cond], actions: @notify)
    mixed = create_workflow!(org, owner, event: :destroyed, conditions: [changed_cond, attr_cond], actions: @notify)

    run = fn wf, changed ->
      args = wf |> subject_args(org, Ash.UUID.generate(), "destroyed") |> Map.put("changed", changed)
      assert :ok = Samen.Automation.RunWorker.perform(run_job(args))
    end

    # RED on the previous round: a soft destroy (archive) names the stamped attribute in `changed`; the condition is satisfied
    run.(meta_only, ["priority"])
    assert notified(org, owner) == 1
    assert [%{state: :succeeded}] = runs_for(org, meta_only.id)

    # POSITIVE CONTROL: the metadata condition is really evaluated (not waved through): unmet when the attribute is not in `changed`
    run.(meta_only, ["tags"])
    assert notified(org, owner) == 1
    assert [{:skipped, :conditions_unmet}, {:succeeded, nil}] =
             org |> runs_for(meta_only.id) |> Enum.map(&{&1.state, &1.error_kind}) |> Enum.sort()

    run.(attr_only, ["priority"])
    run.(mixed, ["priority"])
    assert notified(org, owner) == 1
    assert [%{state: :skipped, error_kind: :no_subject_record}] = runs_for(org, attr_only.id)
    assert [%{state: :skipped, error_kind: :no_subject_record}] = runs_for(org, mixed.id)
  end

  test "Condition.needs_subject_values?/1 fails closed: only `changed` is metadata-only, every other operator (and an unknown one) needs the record" do
    refute Samen.Automation.Condition.needs_subject_values?(%{attribute: "a", op: :changed, values: []})

    for op <- ~w(eq neq in not_in gt gte lt lte is_nil not_nil)a ++ [:some_future_op] do
      assert Samen.Automation.Condition.needs_subject_values?(%{attribute: "a", op: op, values: []}), "#{op}"
    end
  end

  test "RED: a subject read that FAILS is retried (Oban error, run left queued) instead of skipping the run for good; the last attempt finalizes it; a healed read fires (control)" do
    org = Ash.UUID.generate()
    owner = Ash.UUID.generate()
    wf = create_workflow!(org, owner, conditions: [], actions: @notify)
    target = create_target!(org)
    args = subject_args(wf, org, to_string(target.id), "created")
    table = AshPostgres.DataLayer.Info.table(Target)

    job = fn attempt -> %Oban.Job{args: args, attempt: attempt, max_attempts: 3} end

    TestRepo.query!("ALTER TABLE #{table} RENAME TO #{table}_unreadable")

    ExUnit.CaptureLog.capture_log(fn ->
      # not the last attempt: retryable, nothing finalized, nothing fired
      assert {:error, :unavailable} = Samen.Automation.RunWorker.perform(job.(1))
      assert [%{state: :queued}] = runs_for(org, wf.id)
      assert notified(org, owner) == 0

      # the last attempt: terminal, visible on the run
      assert :ok = Samen.Automation.RunWorker.perform(job.(3))
      assert [%{state: :skipped, error_kind: :internal_error}] = runs_for(org, wf.id)
    end)

    TestRepo.query!("ALTER TABLE #{table}_unreadable RENAME TO #{table}")

    # POSITIVE CONTROL: a retry against a healed read fires (a fresh workflow run: the first is already terminal)
    wf2 = create_workflow!(org, owner, conditions: [], actions: @notify)
    assert :ok = Samen.Automation.RunWorker.perform(%Oban.Job{args: subject_args(wf2, org, to_string(target.id), "created"), attempt: 2, max_attempts: 3})
    assert notified(org, owner) == 1
    assert [%{state: :succeeded}] = runs_for(org, wf2.id)
  end

  defmodule CompensatedOk do
    @moduledoc false
    @behaviour Samen.Automation.Action
    def kind, do: :zz_comp_ok
    def validate(config, _key), do: {:ok, config}
    def run(_config, _ctx), do: {:ok, %{}}
    def undo(_config, _meta, _ctx), do: :ok
  end

  defmodule CompensatedBad do
    @moduledoc false
    @behaviour Samen.Automation.Action
    def kind, do: :zz_comp_bad
    def validate(config, _key), do: {:ok, config}
    def run(_config, _ctx), do: {:ok, %{}}
    def undo(_config, _meta, _ctx), do: {:error, :undo_failed}
  end

  defmodule CompensatedRaises do
    @moduledoc false
    @behaviour Samen.Automation.Action
    def kind, do: :zz_comp_raises
    def validate(config, _key), do: {:ok, config}
    def run(_config, _ctx), do: {:ok, %{}}
    def undo(_config, _meta, _ctx), do: raise("boom")
  end

  defmodule AlwaysFails do
    @moduledoc false
    @behaviour Samen.Automation.Action
    def kind, do: :zz_fail
    def validate(config, _key), do: {:ok, config}
    def run(_config, _ctx), do: {:error, :write_failed}
  end

  test "RED: a compensation that FAILS is stamped on the failed run's outcome (the engine discarded it, Reactor saw :ok); a clean compensation leaves none (control)" do
    prev = Application.get_env(:samen_core, Samen.Automation.Action)

    Application.put_env(:samen_core, Samen.Automation.Action,
      extra: %{
        "zz_comp_ok" => CompensatedOk,
        "zz_comp_bad" => CompensatedBad,
        "zz_comp_raises" => CompensatedRaises,
        "zz_fail" => AlwaysFails
      }
    )

    on_exit(fn -> restore(:samen_core, Samen.Automation.Action, prev) end)

    org = Ash.UUID.generate()
    owner = Ash.UUID.generate()
    target = create_target!(org)

    fire = fn first_kind ->
      wf = create_workflow!(org, owner, conditions: [], actions: [%{"kind" => first_kind}, %{"kind" => "zz_fail"}])

      args = %{
        "workflow_id" => to_string(wf.id),
        "org_id" => org,
        "resource_key" => @target_key,
        "record_id" => to_string(target.id),
        "event" => "created",
        "event_id" => Ash.UUID.generate(),
        "trigger_kind" => "resource_event",
        "depth" => 0,
        "chain" => []
      }

      ExUnit.CaptureLog.capture_log(fn -> assert :ok = Samen.Automation.RunWorker.perform(run_job(args)) end)
      [run] = runs_for(org, wf.id)
      run
    end

    compensation_failed? = fn run ->
      Enum.any?(run.outcome || [], fn o -> (o["status"] || o[:status]) |> to_string() == "compensation_failed" end)
    end

    # POSITIVE CONTROL: the failed run whose compensation succeeded carries no compensation failure
    clean = fire.("zz_comp_ok")
    assert clean.state == :failed
    refute compensation_failed?.(clean)

    for kind <- ["zz_comp_bad", "zz_comp_raises"] do
      run = fire.(kind)
      assert run.state == :failed
      assert compensation_failed?.(run), "#{kind}: the failed compensation is not on the run"
      # the run's own failure stays the action that failed
      assert run.error_kind == :write_failed
    end
  end

  test "RED: an UndoStepError that is not the bounded compensation map keeps the failing action's error_kind (it overrode it with :action_failed); an ordinary failure is unchanged (control)" do
    run_error = Reactor.Error.Invalid.RunStepError.exception(error: %{error_kind: :write_failed, index: 1, kind: "zz_fail"})
    undo_error = Reactor.Error.Invalid.UndoStepError.exception(error: :reactor_internal)
    wrapped = fn errors -> Reactor.Error.Invalid.exception(errors: errors) end

    # POSITIVE CONTROL
    assert {[_], :write_failed} = Samen.Automation.RunWorker.failure_summary(wrapped.([run_error]))

    # undo errors come FIRST in Reactor's error list
    assert {_outs, :write_failed} = Samen.Automation.RunWorker.failure_summary(wrapped.([undo_error, run_error]))
  end

  # Fails AFTER the compensable action ran, having first put the world into the state under test.
  defmodule BreakThenFail do
    @moduledoc false
    @behaviour Samen.Automation.Action
    def kind, do: :zz_break
    def validate(config, _key), do: {:ok, config}

    def run(config, _ctx) do
      table = config["table"]

      case config["mode"] do
        # the table cannot be READ any more (rolled back with the sandbox transaction)
        "unreadable" -> SamenCore.TestRepo.query!("ALTER TABLE #{table} RENAME TO #{table}_unreadable")
        # the row it created is gone
        "gone" -> SamenCore.TestRepo.query!("DELETE FROM #{table}")
        # the row it created is already cancelled / resolved
        "resolve_escalation" ->
          [esc] = SamenCore.Support.AutomationFixture.Escalation |> Ash.read!(authorize?: false)
          {:ok, _} = Samen.Automation.Escalate.resolve(esc.id, :resolved)

        "cancel_reminder" ->
          [rem] = SamenCore.Support.AutomationFixture.Reminder |> Ash.read!(authorize?: false)
          actor = Samen.Scope.new(%{id: rem.recipient_id, org_id: rem.org_id, role: :member})
          {:ok, _} = Samen.Automation.Remind.cancel(rem.id, actor)

        "none" -> :ok
      end

      {:error, :write_failed}
    end
  end

  describe "a compensating undo that FAILS is on the run (enqueue_reminder, escalate)" do
    alias SamenCore.Support.AutomationFixture.{Escalation, Reminder}

    setup do
      prev = %{
        action: Application.get_env(:samen_core, Samen.Automation.Action),
        remind: Application.get_env(:samen_core, Samen.Automation.Remind),
        escalate: Application.get_env(:samen_core, Samen.Automation.Escalate)
      }

      Application.put_env(:samen_core, Samen.Automation.Action, extra: %{"zz_break" => BreakThenFail})
      Application.put_env(:samen_core, Samen.Automation.Remind, reminder_module: Reminder, repo: TestRepo)

      Application.put_env(:samen_core, Samen.Automation.Escalate,
        escalation_module: Escalation,
        repo: TestRepo
      )

      on_exit(fn ->
        restore(:samen_core, Samen.Automation.Action, prev.action)
        restore(:samen_core, Samen.Automation.Remind, prev.remind)
        restore(:samen_core, Samen.Automation.Escalate, prev.escalate)
      end)

      :ok
    end

    @cases [
      {"enqueue_reminder", %{"kind" => "enqueue_reminder", "recipient" => "owner", "offset_minutes" => 60}, "arm_reminder",
       "write=reminder_undo"},
      {"escalate", %{"kind" => "escalate", "deadline_minutes" => 30}, "aes_escalation", "write=escalation_undo"}
    ]

    defp fire_failing(compensable, breaker) do
      org = Ash.UUID.generate()
      owner = Ash.UUID.generate()
      target = create_target!(org)
      wf = create_workflow!(org, owner, conditions: [], actions: [compensable, Map.put(breaker, "kind", "zz_break")])

      args = %{
        "workflow_id" => to_string(wf.id),
        "org_id" => org,
        "resource_key" => @target_key,
        "record_id" => to_string(target.id),
        "event" => "created",
        "event_id" => Ash.UUID.generate(),
        "trigger_kind" => "resource_event",
        "depth" => 0,
        "chain" => []
      }

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert :ok = Samen.Automation.RunWorker.perform(run_job(args))
        end)

      [run] = runs_for(org, wf.id)
      {org, run, log}
    end

    defp compensation_failed_on?(run) do
      Enum.any?(run.outcome || [], fn o -> (o["status"] || o[:status]) |> to_string() == "compensation_failed" end)
    end

    for {name, compensable, table, write_tag} <- @cases do
      test "RED: #{name} - an undo whose row cannot be READ is compensation_failed on the run and reported; the run's own error_kind stays" do
        {_org, run, log} = fire_failing(unquote(Macro.escape(compensable)), %{"mode" => "unreadable", "table" => unquote(table)})

        assert run.state == :failed
        assert compensation_failed_on?(run), "#{unquote(name)}: the failed compensation is not on the run"
        assert run.error_kind == :write_failed
        assert log =~ unquote(write_tag)
      end

      test "positive controls: #{name} - a successful undo is clean; a row that is already gone is :ok with no report" do
        {_org, clean, clean_log} = fire_failing(unquote(Macro.escape(compensable)), %{"mode" => "none"})
        assert clean.state == :failed
        refute compensation_failed_on?(clean)
        refute clean_log =~ unquote(write_tag)

        {_org, gone, gone_log} =
          fire_failing(unquote(Macro.escape(compensable)), %{"mode" => "gone", "table" => unquote(table)})

        assert gone.state == :failed
        refute compensation_failed_on?(gone)
        refute gone_log =~ unquote(write_tag)
      end
    end

    test "positive control: an escalation already resolved is :ok - nothing to cancel, no report" do
      {_org, run, log} =
        fire_failing(%{"kind" => "escalate", "deadline_minutes" => 30}, %{"mode" => "resolve_escalation"})

      assert run.state == :failed
      refute compensation_failed_on?(run)
      refute log =~ "write=escalation_undo"
    end

    test "positive control: a reminder already cancelled is :ok - no report" do
      {_org, run, log} =
        fire_failing(
          %{"kind" => "enqueue_reminder", "recipient" => "owner", "offset_minutes" => 60},
          %{"mode" => "cancel_reminder"}
        )

      assert run.state == :failed
      refute compensation_failed_on?(run)
      refute log =~ "write=reminder_undo"
    end

    test "Remind.cancel/3 and Escalate.resolve/3 tell a failed read from a missing row" do
      actor = Samen.Scope.new(%{id: Ash.UUID.generate(), org_id: Ash.UUID.generate(), role: :member})
      assert {:error, :not_found} = Samen.Automation.Remind.cancel(Ash.UUID.generate(), actor)
      assert {:error, :not_found} = Samen.Automation.Escalate.resolve(Ash.UUID.generate(), :cancelled)

      TestRepo.query!("ALTER TABLE arm_reminder RENAME TO arm_reminder_unreadable")
      TestRepo.query!("ALTER TABLE aes_escalation RENAME TO aes_escalation_unreadable")

      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, reason} = Samen.Automation.Remind.cancel(Ash.UUID.generate(), actor)
        refute reason == :not_found
        assert {:error, reason} = Samen.Automation.Escalate.resolve(Ash.UUID.generate(), :cancelled)
        refute reason == :not_found
      end)
    end
  end

  test "RED: a schedule advance whose org cannot be resolved enqueues NO dispatch (it enqueued one with org_id \"\"); a resolvable org enqueues one (control)" do
    org = Ash.UUID.generate()
    owner = Ash.UUID.generate()
    wf = create_workflow!(org, owner, conditions: [], actions: [%{"kind" => "notify", "recipient" => "owner", "event_type" => "workflow.fired"}])

    advance = fn changeset, result ->
      # `for_update/3` already ran the action's changes (ScheduleAdvance registered its after_action hook)
      for entry <- changeset.after_action do
        callback = if is_function(entry), do: entry, else: elem(entry, 0)
        callback.(changeset, result)
      end
    end

    # the schedule dispatches enqueued so far (any org: the blank-org one is the lie under test)
    dispatches = fn ->
      require Ecto.Query

      Oban.Job
      |> Ecto.Query.where([j], j.worker == "Samen.Automation.DispatchWorker")
      |> TestRepo.all()
      |> Enum.filter(&(&1.args["trigger_kind"] == "schedule"))
    end

    assert dispatches.() == []

    # POSITIVE CONTROL: the org is on the row -> one dispatch under that org
    changeset = Ash.Changeset.for_update(wf, :dispatch_due, %{})
    advance.(changeset, wf)
    assert [%{args: %{"org_id" => ^org}}] = dispatches.()

    # RED: org_id not loaded on the changeset OR the result and the row cannot be reloaded (a stale id)
    ghost = %{wf | id: Ash.UUID.generate(), org_id: %Ash.NotLoaded{field: :org_id}}
    changeset = Ash.Changeset.for_update(%{wf | org_id: %Ash.NotLoaded{field: :org_id}}, :dispatch_due, %{})

    log = ExUnit.CaptureLog.capture_log(fn -> advance.(changeset, ghost) end)
    assert [%{args: %{"org_id" => ^org}}] = dispatches.()
    assert log =~ "write=schedule_advance_enqueue_skipped"
  end

  test "RED: via the real AshOban scan, an unresolvable org leaves next_fire_at unchanged and enqueues nothing; a resolvable org advances and enqueues one (control)" do
    require Ecto.Query

    org = Ash.UUID.generate()
    owner = Ash.UUID.generate()
    past = DateTime.utc_now() |> DateTime.add(-120, :second) |> DateTime.truncate(:second)

    wf =
      Workflow
      |> Ash.Changeset.for_create(:create, %{
        org_id: org,
        name: "wf-#{System.unique_integer([:positive])}",
        status: :active,
        trigger_kind: :schedule,
        resource_key: @target_key,
        schedule_cron: "* * * * *",
        next_fire_at: past,
        conditions: [],
        actions: @notify,
        owner_id: owner
      })
      |> Ash.create!(authorize?: false)

    table = AshPostgres.DataLayer.Info.table(Workflow)
    wf_id = Ecto.UUID.dump!(wf.id)
    [id_col] = for %{name: :id} = attr <- Ash.Resource.Info.attributes(Workflow), do: to_string(attr.source || attr.name)
    [fire_col] = for %{name: :next_fire_at} = attr <- Ash.Resource.Info.attributes(Workflow), do: to_string(attr.source || attr.name)

    persisted_fire_at = fn ->
      %{rows: [[at]]} = TestRepo.query!("SELECT #{fire_col} FROM #{table} WHERE #{id_col} = $1", [wf_id])
      at
    end

    dispatches = fn ->
      Oban.Job
      |> Ecto.Query.where([j], j.worker == "Samen.Automation.DispatchWorker")
      |> TestRepo.all()
      |> Enum.filter(&(&1.args["trigger_kind"] == "schedule" and &1.args["workflow_id"] == to_string(wf.id)))
    end

    before = persisted_fire_at.()
    assert dispatches.() == []

    # the org cannot be resolved inside the real update: the scan read does not select org_id, so the hook reloads the
    # row by id, and an AFTER UPDATE trigger makes the row vanish from that reload (the "deleted between the scan and the
    # update" shape: the reload answers no row, so no org)
    TestRepo.query!("""
    CREATE FUNCTION zz_vanish_after_update() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      DELETE FROM #{table} WHERE #{id_col} = NEW.#{id_col};
      RETURN NULL;
    END $$
    """)

    TestRepo.query!("CREATE TRIGGER zz_vanish AFTER UPDATE ON #{table} FOR EACH ROW EXECUTE FUNCTION zz_vanish_after_update()")

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        AshOban.Test.schedule_and_run_triggers(Workflow, drain_queues?: true)
      end)

    TestRepo.query!("DROP TRIGGER zz_vanish ON #{table}")

    # the real :dispatch_due hook ran and refused (so this is not a scan that never reached the update) ...
    assert log =~ "write=schedule_advance_enqueue_skipped"
    # ... and the real action path rolled the update back (the trigger's delete with it): the fire is neither advanced
    # nor lost, and nothing was enqueued
    assert persisted_fire_at.() == before
    assert dispatches.() == []

    # POSITIVE CONTROL: the org resolves again -> the SAME due fire advances and enqueues exactly one dispatch
    AshOban.Test.schedule_and_run_triggers(Workflow, drain_queues?: true)

    assert DateTime.compare(DateTime.from_naive!(persisted_fire_at.(), "Etc/UTC"), DateTime.from_naive!(before, "Etc/UTC")) == :gt
    assert [%{args: %{"org_id" => ^org}}] = dispatches.()
  end

  test "RED: a schedule advance whose org cannot be resolved FAILS the step (so the update rolls back and the fire retries) instead of returning ok; a resolvable org returns ok (control)" do
    org = Ash.UUID.generate()
    owner = Ash.UUID.generate()
    wf = create_workflow!(org, owner, conditions: [], actions: @notify)

    advance = fn changeset, result ->
      for entry <- changeset.after_action do
        callback = if is_function(entry), do: entry, else: elem(entry, 0)
        callback.(changeset, result)
      end
    end

    # POSITIVE CONTROL: the org is on the row -> the hook answers ok
    changeset = Ash.Changeset.for_update(wf, :dispatch_due, %{})
    assert [{:ok, _}] = advance.(changeset, wf)

    # RED: org not loaded and the row cannot be reloaded
    ghost = %{wf | id: Ash.UUID.generate(), org_id: %Ash.NotLoaded{field: :org_id}}
    changeset = Ash.Changeset.for_update(%{wf | org_id: %Ash.NotLoaded{field: :org_id}}, :dispatch_due, %{})

    ExUnit.CaptureLog.capture_log(fn ->
      assert [{:error, :org_unresolved}] = advance.(changeset, ghost)
    end)
  end

  test "RED: an unknown event string no longer dispatches the :created workflows; 'created' does (control)" do
    org = Ash.UUID.generate()
    owner = Ash.UUID.generate()

    create_workflow!(org, owner,
      actions: [%{"kind" => "notify", "recipient" => "owner", "event_type" => "workflow.fired"}]
    )

    envelope = fn event ->
      %{"org_id" => org, "resource_key" => @target_key, "event" => event, "trigger_kind" => "resource_event"}
    end

    ExUnit.CaptureLog.capture_log(fn ->
      assert {:error, %ArgumentError{}} =
               Samen.Automation.DispatchWorker.perform(%Oban.Job{args: envelope.("no_such_event_zzz")})
    end)

    assert Oban.drain_queue(queue: :automation) |> Map.get(:success) == 0

    assert :ok = Samen.Automation.DispatchWorker.perform(%Oban.Job{args: envelope.("created")})
  end

  defp notified(org, owner) do
    Notification
    |> filter(org_id == ^org)
    |> filter(recipient_id == ^owner)
    |> Ash.read!(authorize?: false)
    |> length()
  end

  defp create_workflow!(org, owner, opts) do
    attrs = %{
      org_id: org,
      name: "wf-#{System.unique_integer([:positive])}",
      status: :active,
      trigger_kind: :resource_event,
      resource_key: Keyword.get(opts, :resource_key, @target_key),
      event: Keyword.get(opts, :event, :created),
      conditions: Keyword.get(opts, :conditions, []),
      actions: Keyword.fetch!(opts, :actions),
      owner_id: owner
    }

    Workflow
    |> Ash.Changeset.for_create(:create, attrs)
    |> Ash.create!(authorize?: false)
  end

  defp create_target!(org, opts \\ []) do
    Target
    |> Ash.Changeset.for_create(:create, %{
      org_id: org,
      title: "t-#{System.unique_integer([:positive])}",
      priority: Keyword.get(opts, :priority, :normal),
      owner_id: Keyword.get(opts, :owner_id),
      tags: [],
      email: Keyword.get(opts, :email, "person@example.com")
    })
    |> Ash.create!(authorize?: false)
  end

  defp drain, do: Oban.drain_queue(queue: :automation, with_recursion: true)

  # A bare `%Oban.Job{}` defaults to `attempt: 0, max_attempts: 20`, so a subject read that RAISES would be retried
  # forever and never reach the last-attempt finalize. Production numbering starts at 1 with the worker's `max_attempts: 3`.
  defp run_job(args), do: %Oban.Job{args: args, attempt: 1, max_attempts: 3}

  defp runs_for(org, workflow_id) do
    Run
    |> filter(org_id == ^org)
    |> filter(workflow_id == ^workflow_id)
    |> Ash.Query.ensure_selected([:org_id])
    |> Ash.Query.sort(inserted_at: :asc)
    |> Ash.read!(authorize?: false)
  end

  # Round-trip through JSON so map keys/atoms compare the same way the
  # operator health view will see them (jsonb round-trips atoms -> strings).
  defp jsonify(term), do: term |> Jason.encode!() |> Jason.decode!()

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, val), do: Application.put_env(app, key, val)
end
