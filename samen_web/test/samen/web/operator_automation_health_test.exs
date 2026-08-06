defmodule Samen.Web.OperatorAutomationHealthTest do
  @moduledoc """
  T42 — `Samen.Web.Operator.AutomationHealthLive` at
  `/operator/automation/:org_id` (ADR-039 §8.3/§8.4): the run log + per-workflow
  health aggregates + the operator kill-switch, over the samen_web test host's
  `Samen.WebTest.Automation.{Workflow,Run}` fixture (`test/support/automation.ex`).

    * **Render + JS-off (ADR-042 Class B)** — the disconnected `render_live`
      helper never wires a socket; workflow health + the run log both render
      real content from it (read affordances survive without JS).
    * **The kill-switch round-trip** — `handle_event("kill", ...)` writes
      through `Samen.Automation.Health.kill/3` (the SAME columns/action T39's
      dispatch/RunWorker honor — asserted via a direct resource read, not just
      UI state) and is idempotent + audited; `"rearm"` clears it.
    * **INV-1 no-leak DOM scan** — a run whose outcome carries a subject value/
      secret (modeled) never renders in the page; a sabotage twin proves the
      scan is refutable (a modeled leak IS detected), mirroring
      `Samen.Web.Operator.WebhookDlqLive`'s token-blind proof shape.
  """
  use Samen.WebTest.DataCase, async: false

  require Ash.Query

  alias Samen.Automation.RunRecord
  alias Samen.Web.Operator.AutomationHealthLive
  alias Samen.WebTest.Automation.{Run, Workflow}
  alias Samen.WebTest.Repo

  setup do
    prev = Application.get_env(:samen_core, Samen.Automation)

    Application.put_env(:samen_core, Samen.Automation,
      workflow_module: Workflow,
      run_module: Run,
      repo: Repo
    )

    on_exit(fn ->
      if prev, do: Application.put_env(:samen_core, Samen.Automation, prev), else: Application.delete_env(:samen_core, Samen.Automation)
    end)

    :ok
  end

  # ---------------------------------------------------------------------------

  test "renders workflow health + the run log with NO connected socket (ADR-042 Class B)" do
    org = Ash.UUID.generate()
    owner = Ash.UUID.generate()

    wf = create_workflow!(org, owner)
    run = open_and_finalize!(org, wf, :succeeded, nil)

    html = render_gated(org)

    assert html =~ wf.name
    assert html =~ "succeeded"
    assert html =~ run.subject_ref
    # No phx-click was fired; this is a purely disconnected render — the
    # content is already present (Class B: reads work JS-off).
    assert html =~ ~s(phx-click="kill")
  end

  test "the kill-switch round-trips through Health.kill/3 — a direct resource read confirms the write" do
    org = Ash.UUID.generate()
    owner = Ash.UUID.generate()
    wf = create_workflow!(org, owner)

    socket = mount_socket(org)
    refute html(socket) =~ "killed ("

    socket = event(socket, "kill", %{"id" => to_string(wf.id)})
    assert html(socket) =~ "killed ("

    # Direct read — the SAME kill columns T39's dispatch/RunWorker honor.
    reloaded = reload_workflow!(wf.id)
    assert reloaded.disabled_by_operator_at
    assert reloaded.disabled_reason == :operator

    # Idempotent: killing again does not error and does not re-stamp.
    stamp = reloaded.disabled_by_operator_at
    socket = event(socket, "kill", %{"id" => to_string(wf.id)})
    assert html(socket) =~ "killed ("
    assert DateTime.compare(reload_workflow!(wf.id).disabled_by_operator_at, stamp) == :eq

    # Re-arm clears it.
    socket = event(socket, "rearm", %{"id" => to_string(wf.id)})
    refute html(socket) =~ "killed ("
    assert is_nil(reload_workflow!(wf.id).disabled_by_operator_at)
  end

  test "the kill-switch write is audited (attributed + org-partitioned)" do
    org = Ash.UUID.generate()
    owner = Ash.UUID.generate()
    wf = create_workflow!(org, owner)

    socket = mount_socket(org)
    _socket = event(socket, "kill", %{"id" => to_string(wf.id)})

    events = Samen.AuditEvent.for_subject(Repo, to_string(wf.id))
    assert Enum.any?(events, &String.contains?(&1.detail, "operator_kill"))
    assert Enum.any?(events, &(&1.correlation_id == org))
  end

  test "T154 — a kill/rearm WRITE is DENIED without an active session (deny-on-write, crafted phx-click)" do
    org = Ash.UUID.generate()
    owner = Ash.UUID.generate()
    wf = create_workflow!(org, owner)

    # A socket with an operator identity but NO impersonation session for this org — the state an
    # attacker crafting a `phx-click` on the denied page has (the kill button is not even rendered).
    socket =
      %Phoenix.LiveView.Socket{}
      |> Phoenix.Component.assign(:samen_mount, operator_mount(org))
      |> Phoenix.Component.assign(:samen_acting_as, false)
      |> with_operator_identity(org)
      |> AutomationHealthLive.load(org)

    assert socket.assigns.impersonation == :denied

    # Fire the crafted kill anyway — the write handler must re-consult the gate and REFUSE.
    socket = event(socket, "kill", %{"id" => to_string(wf.id)})

    assert socket.assigns.impersonation == :denied
    refute reload_workflow!(wf.id).disabled_by_operator_at

    # Positive control: once a session is opened, the SAME kill writes (round-trip covered above).
    open_impersonation!(org, org)
    socket = AutomationHealthLive.load(socket, org)
    _socket = event(socket, "kill", %{"id" => to_string(wf.id)})
    assert reload_workflow!(wf.id).disabled_by_operator_at
  end

  test "no PII / vault token / webhook secret ever renders in the health page (INV-1 red-path proof)" do
    org = Ash.UUID.generate()
    owner = Ash.UUID.generate()
    wf = create_workflow!(org, owner)
    assert wf.webhook_secret

    # A run whose outcome carries ONLY bounded keys — realistic shape
    # (`Samen.Automation.RunRecord.bounded_outcomes/1`'s allowlist).
    _run = open_and_finalize!(org, wf, :failed, :suppressed)

    html = render_gated(org)

    refute html =~ wf.webhook_secret
    refute html =~ ~r/\bvt_/
    refute html =~ "victim@example.com"
  end

  test "sabotage twin — the no-leak scan is refutable: a modeled leaked outcome value IS caught" do
    org = Ash.UUID.generate()
    owner = Ash.UUID.generate()
    wf = create_workflow!(org, owner)

    # Model a leak DIRECTLY against the resource (bypassing RunRecord's
    # allowlist entirely) — proves the DOM scan above is non-vacuous: if the
    # bounded-outcome guarantee were ever broken, this page WOULD render it.
    key = RunRecord.dispatch_key(to_string(wf.id), Ash.UUID.generate())

    {:ok, _leaked} =
      Run
      |> Ash.Changeset.for_create(
        :record,
        %{
          org_id: org,
          workflow_id: wf.id,
          dispatch_key: key,
          trigger_kind: :manual,
          subject_ref: "samen:workflow:#{wf.id}:leak-canary-secret-token"
        },
        authorize?: false
      )
      |> Ash.create(authorize?: false)

    html = render_gated(org)

    assert html =~ "leak-canary-secret-token",
           "the scan must be able to detect a leak in subject_ref, else the red-path assertion is vacuous"
  end

  # ---------------------------------------------------------------------------
  # Harness

  defp operator_mount(operator_org_id) do
    build_operator_mount(operator_org_id)
  end

  # T150: the per-tenant automation drill-in now requires a REAL impersonation session for the
  # target org (deny-on-read). Open one (operator seat id == the mount's operator_org_id ==
  # `target_org_id` in this harness), assign the operator identity the gate resolves, then load.
  defp mount_socket(target_org_id) do
    open_impersonation!(target_org_id, target_org_id)

    %Phoenix.LiveView.Socket{}
    |> Phoenix.Component.assign(:samen_mount, operator_mount(target_org_id))
    |> Phoenix.Component.assign(:samen_acting_as, false)
    |> with_operator_identity(target_org_id)
    |> AutomationHealthLive.load(target_org_id)
  end

  # Disconnected render THROUGH an active session (the Class B / no-leak reads).
  defp render_gated(org), do: html(mount_socket(org))

  defp html(socket), do: render_html(AutomationHealthLive, socket.assigns)

  defp event(socket, name, params) do
    {:noreply, socket} = AutomationHealthLive.handle_event(name, params, socket)
    socket
  end

  defp create_workflow!(org, owner) do
    Workflow
    |> Ash.Changeset.for_create(:create, %{
      org_id: org,
      name: "wf-#{System.unique_integer([:positive])}",
      status: :active,
      trigger_kind: :manual,
      owner_id: owner,
      conditions: [],
      actions: [%{"kind" => "notify", "recipient" => "owner", "event_type" => "workflow.fired"}]
    })
    |> Ash.create!(authorize?: false)
  end

  defp reload_workflow!(id) do
    Workflow
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.ensure_selected([:org_id])
    |> Ash.read!(authorize?: false)
    |> List.first()
  end

  defp open_and_finalize!(org, wf, to, error_kind) do
    args = %{
      "org_id" => org,
      "event_id" => Ash.UUID.generate(),
      "trigger_kind" => "manual",
      "subject_ref" => "samen:workflow:#{wf.id}:test"
    }

    run = RunRecord.open!(wf, args)
    run = RunRecord.mark_running!(run)

    case to do
      :succeeded -> RunRecord.succeed!(run, [%{index: 0, kind: "notify", status: "succeeded"}])
      :failed -> RunRecord.fail!(run, [%{index: 0, kind: "send_email", status: "failed", error_kind: error_kind}], error_kind)
    end

    Run
    |> Ash.Query.filter(id == ^run.id)
    |> Ash.read!(authorize?: false)
    |> List.first()
  end
end
