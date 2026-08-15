defmodule Samen.Web.AI.AgentSurfaceTest do
  @moduledoc """
  ADR-047 A5 — the tenant + operator agent SURFACES.

  Tenant plane (`Samen.Web.AI.AgentLive`):

    * the run list + per-run detail render with JS off (ADR-042 Class B);
    * **org scope** — a run in another org does not exist for this surface (RP-AG-10:
      no row, no existence oracle);
    * **honesty copy driven by the persisted state**, never by a promoted last turn:
      `:budget_exhausted` says *this is not a partial answer*; `:expired` says the
      proposal lapsed and nothing executed; `:rejected` / `:failed` / `:cancelled` each
      render their own honest terminal (ADR-014 / ADR-047 §6);
    * the SIMULATED badge is driven by the turn row's persisted `simulated` flag
      (stamped at the chokepoint from `%Completion{}.simulated`), never parsed from text;
    * **cancel** goes through the kernel's org-scoped `Samen.AI.Agent.cancel/2` and says
      "stopping after the current step", never "stopped";
    * the **decision card** renders TOKEN-ONLY provenance (tool kind, turn index, arg key
      NAMES, args digest) and never an argument value, and the decide handler REFUSES an
      approval id that is not this run's pending proposal — re-read from the server on
      every click rather than trusted from the last render.

  Operator plane (`Samen.Web.Operator.AgentHealthLive` / `Samen.AI.Agent.Health`):

    * per-definition aggregates + the bounded run/turn log;
    * the **durable per-{org, definition} kill** is role-gated (readonly may view, never
      manage), narrowed to one tenant (the A2/A3 cross-tenant blast radius is closed),
      and only an explicit re-arm clears it.

  ## What is deliberately proven in samen_core instead

  The full click-to-EXECUTE path (a real `apv_approval` row, requester ≠ approver at the
  DB CHECK, the args-digest binding, approver-membership resolution, execution inside the
  decision transaction) is proven against the REAL engine in
  `samen_core/test/ai/agent_write_test.exs`; samen_web's scratch host mounts no approvals
  resource. This surface adds no second decision path — `AgentReads.decide/3` is a
  pass-through — so what is proven here is the surface's own contract: what it renders,
  and what it refuses to send to the engine.
  """
  use Samen.WebTest.DataCase, async: false

  alias Samen.AI.Agent.Breaker
  alias Samen.AI.Agent.Health
  alias Samen.AI.Agent.Run
  alias Samen.OperatorPlane.Actor
  alias Samen.Web.AI.AgentLive
  alias Samen.Web.AI.AgentReads
  alias Samen.Web.Mount
  alias Samen.WebTest.AgentFixture

  setup do
    org_id = Ash.UUID.generate()
    on_exit(fn -> Breaker.reset() end)
    %{org_id: org_id}
  end

  defp tenant_mount,
    do: Mount.new(:ai, Samen.WebTest.Crm, Samen.WebTest.Repo, plane: Samen.Web.Plane.tenant())

  defp socket(mount) do
    %Phoenix.LiveView.Socket{}
    |> Phoenix.Component.assign(:samen_mount, mount)
    |> Phoenix.Component.assign(:samen_acting_as, false)
  end

  defp render_list(org_id) do
    mount = tenant_mount()
    socket(mount) |> AgentLive.load(org_id) |> then(&render_html(AgentLive, &1.assigns))
  end

  defp render_detail(org_id, run_id) do
    mount = tenant_mount()

    socket(mount)
    |> AgentLive.load(org_id, run_id: run_id)
    |> then(&render_html(AgentLive, &1.assigns))
  end

  # ==========================================================================
  # The tenant surface
  # ==========================================================================

  test "the run LIST renders this org's runs with JS off", %{org_id: org_id} do
    run = AgentFixture.run!(org_id, agent: "support_triage", state: :running)

    html = render_list(org_id)
    assert html =~ "AI · Agent runs"
    assert html =~ "agent-run-#{run.id}"
    assert html =~ "support_triage"
  end

  test "ORG SCOPE: another org's run is not listed and its detail does not exist",
       %{org_id: org_id} do
    other_org = Ash.UUID.generate()
    foreign = AgentFixture.run!(other_org, agent: "foreign_agent", state: :running)
    mine = AgentFixture.run!(org_id, agent: "support_triage", state: :running)

    html = render_list(org_id)
    assert html =~ "agent-run-#{mine.id}"
    refute html =~ "agent-run-#{foreign.id}"
    refute html =~ "foreign_agent"

    # The detail read is the same conjunct: a foreign run does not exist (no oracle) —
    # the page falls back to the list rather than reporting "forbidden".
    assert {:error, :not_found} = AgentReads.get(tenant_mount(), org_id, foreign.id)
    detail_html = render_detail(org_id, foreign.id)
    refute detail_html =~ "agent-run-detail"

    # POSITIVE CONTROL: the same call for the OWN run resolves (the refusal is the scope).
    assert {:ok, _} = AgentReads.get(tenant_mount(), org_id, mine.id)
  end

  test "the DETAIL renders the bounded turn log and the SIMULATED badge from the persisted flag",
       %{org_id: org_id} do
    run = AgentFixture.run!(org_id, state: :running, current_turn: 1)
    _ = AgentFixture.turn!(run, %{simulated: true})

    html = render_detail(org_id, run.id)
    assert html =~ "agent-run-detail"
    assert html =~ "agent-turn-log"
    assert html =~ "fetch_record"
    assert html =~ "id, resource", "arg key NAMES are rendered"
    assert html =~ "SIMULATED — not a real model"

    # ...and a genuine (non-simulated) turn carries NO badge — the flag drives it.
    other = AgentFixture.run!(org_id, state: :running, current_turn: 1)
    _ = AgentFixture.turn!(other, %{simulated: false})
    refute render_detail(org_id, other.id) =~ "SIMULATED — not a real model"
  end

  test "BUDGET EXHAUSTION renders the honest copy — never a partial answer", %{org_id: org_id} do
    run =
      AgentFixture.run!(org_id,
        state: :budget_exhausted,
        error_kind: "max_turns",
        lines: ["I think the answer might be that the carrier was late"]
      )

    html = render_detail(org_id, run.id)
    assert html =~ ~s(data-state="budget_exhausted")
    assert html =~ "this is not a partial answer"
    assert html =~ "max_turns"
  end

  test "EXPIRED renders the honest lapsed-proposal copy (A5's F3 fold, surfaced)",
       %{org_id: org_id} do
    run = AgentFixture.run!(org_id, state: :expired, pending: %{"kind" => "assign_record_owner"})

    html = render_detail(org_id, run.id)
    assert html =~ ~s(data-state="expired")
    assert html =~ "deadline passed with no decision"
    assert html =~ "nothing was executed"
  end

  test "REJECTED / FAILED / CANCELLED each render their own honest terminal",
       %{org_id: org_id} do
    rejected = AgentFixture.run!(org_id, state: :rejected)
    failed = AgentFixture.run!(org_id, state: :failed, error_kind: "provider_error")
    cancelled = AgentFixture.run!(org_id, state: :cancelled)

    assert render_detail(org_id, rejected.id) =~ "A reviewer refused the proposed write"
    assert render_detail(org_id, failed.id) =~ "provider_error"
    assert render_detail(org_id, cancelled.id) =~ "Stopped at a turn boundary"
  end

  test "CANCEL goes through the kernel's org-scoped cancel/2 and is honest about WHEN it stops",
       %{org_id: org_id} do
    run = AgentFixture.run!(org_id, state: :running)
    mount = tenant_mount()

    loaded = socket(mount) |> AgentLive.load(org_id, run_id: run.id)
    {:noreply, socket} = AgentLive.handle_event("cancel", %{"id" => run.id}, loaded)

    assert {:ok, "Stopping after the current step."} = socket.assigns.outcome

    reloaded = Ash.get!(Run, run.id, authorize?: false)
    assert reloaded.cancel_requested_at != nil, "the DURABLE flag is what a cancel sets"

    # RED: a foreign org's run cannot be cancelled from this org's surface.
    foreign = AgentFixture.run!(Ash.UUID.generate(), state: :running)

    {:noreply, refused} = AgentLive.handle_event("cancel", %{"id" => foreign.id}, loaded)

    assert {:error, _} = refused.assigns.outcome
    assert Ash.get!(Run, foreign.id, authorize?: false).cancel_requested_at == nil
  end

  # ==========================================================================
  # The decision card
  # ==========================================================================

  test "the DECISION CARD renders token-only provenance — never an argument value" do
    provenance = %{
      run_id: Ash.UUID.generate(),
      turn_index: 2,
      tool_kind: "assign_record_owner",
      arg_keys: ["id", "resource", "user_id"],
      args_digest: String.duplicate("ab", 32)
    }

    approval = %{id: Ash.UUID.generate(), deadline_at: ~U[2026-08-16 00:00:00Z]}

    run = %{
      id: provenance.run_id,
      state: :awaiting_approval,
      agent: "support_triage",
      current_turn: 2,
      max_turns: 8,
      tool_calls_used: 0,
      max_tool_calls: 12,
      input_tokens_used: 10,
      output_tokens_used: 4,
      error_kind: nil
    }

    assigns = %{
      samen_mount: tenant_mount(),
      samen_acting_as: false,
      org_id: Ash.UUID.generate(),
      runs: [],
      run_id: run.id,
      outcome: nil,
      detail: %{
        run: run,
        goal: "who should own 4471?",
        lines: [],
        turns: [],
        approval: approval,
        provenance: provenance
      }
    }

    html = render_html(AgentLive, assigns)

    assert html =~ "agent-decision-card"
    assert html =~ "Awaiting your decision"
    assert html =~ "assign_record_owner"
    assert html =~ "id, resource, user_id", "arg key NAMES"
    assert html =~ provenance.args_digest
    assert html =~ "agent-approve"
    assert html =~ "agent-reject"

    # The honest framing: the write has NOT run, and cannot without a distinct human.
    assert html =~ "It has not run"
    assert html =~ "never argument values"

    # Nothing on the card is an argument VALUE — the approval row stores none (INV-1).
    refute html =~ "hilda@"
  end

  test "a decision click for an approval that is NOT this run's pending proposal is REFUSED before the engine",
       %{org_id: org_id} do
    # A parked run with no matching pending approval (samen_web mounts no approvals
    # engine, so `pending_approval/2` is nil) — a crafted phx-value must not be decided.
    run = AgentFixture.run!(org_id, state: :awaiting_approval)
    mount = tenant_mount()

    for action <- ["approve", "reject"] do
      loaded = socket(mount) |> AgentLive.load(org_id, run_id: run.id)
      {:noreply, socket} = AgentLive.handle_event(action, %{"id" => Ash.UUID.generate()}, loaded)

      assert {:error, msg} = socket.assigns.outcome
      assert msg =~ "no longer pending for this run"
    end

    # ...and the run is untouched: still parked, nothing decided, nothing executed.
    assert Ash.get!(Run, run.id, authorize?: false).state == :awaiting_approval
  end

  # ==========================================================================
  # The operator surface
  # ==========================================================================

  test "the operator SUMMARY aggregates per definition and reports the durable kill state",
       %{org_id: org_id} do
    _ = AgentFixture.run!(org_id, agent: "support_triage", state: :succeeded)
    _ = AgentFixture.run!(org_id, agent: "support_triage", state: :failed, error_kind: "provider_error")
    _ = AgentFixture.run!(org_id, agent: "billing_triage", state: :awaiting_approval)

    operator = Actor.new("op-1", :operator_admin)
    {:ok, summary} = Health.summary(operator, org_id)

    assert [billing, support] = Enum.sort_by(summary, & &1.agent)
    assert support.agent == "support_triage"
    assert support.total_runs == 2
    assert support.run_counts["succeeded"] == 1
    assert support.error_kind_counts["provider_error"] == 1
    refute support.killed

    assert billing.awaiting_approval == 1

    # The durable kill lands on ONE {org, definition} and shows up as state.
    assert :ok = Health.kill(operator, org_id, "support_triage")
    {:ok, summary} = Health.summary(operator, org_id)
    assert Enum.find(summary, &(&1.agent == "support_triage")).killed
    assert Enum.find(summary, &(&1.agent == "support_triage")).kill_reason == "operator"
    refute Enum.find(summary, &(&1.agent == "billing_triage")).killed

    # ...and only an explicit re-arm clears it (trips never self-heal).
    assert Breaker.definition_killed?(org_id, "support_triage")
    assert :ok = Health.rearm(operator, org_id, "support_triage")
    refute Breaker.definition_killed?(org_id, "support_triage")
  end

  test "RED: a READONLY operator may VIEW but never kill or re-arm", %{org_id: org_id} do
    _ = AgentFixture.run!(org_id, agent: "support_triage", state: :running)
    readonly = Actor.new("op-2", :operator_readonly)

    assert {:ok, _} = Health.summary(readonly, org_id)
    assert {:ok, _} = Health.runs(readonly, org_id)
    assert {:error, :not_authorized} = Health.kill(readonly, org_id, "support_triage")
    assert {:error, :not_authorized} = Health.rearm(readonly, org_id, "support_triage")
    refute Breaker.definition_killed?(org_id, "support_triage")

    # ...and a non-operator actor cannot even view.
    assert {:error, :not_authorized} = Health.summary(%{id: "nobody"}, org_id)

    # POSITIVE CONTROL: an operator_admin can (the refusal is the role, not breakage).
    assert :ok = Health.kill(Actor.new("op-1", :operator_admin), org_id, "support_triage")
  end

  test "the operator health page renders per-definition rows + the kill affordance",
       %{org_id: org_id} do
    _ = AgentFixture.run!(org_id, agent: "support_triage", state: :running)
    operator = Actor.new("op-1", :operator_admin)
    {:ok, summary} = Health.summary(operator, org_id)
    {:ok, runs} = Health.runs(operator, org_id)

    assigns = %{
      samen_mount: build_operator_mount(Ash.UUID.generate()),
      no_org: false,
      impersonation: :active,
      target_org_id: org_id,
      operator: operator,
      summary: summary,
      runs: runs,
      turns: [],
      selected_run: nil,
      action_error: nil,
      session_info: nil,
      open_error: nil
    }

    html = render_html(Samen.Web.Operator.AgentHealthLive, assigns)
    assert html =~ "Agent health"
    assert html =~ "agent-support_triage"
    assert html =~ "kill-support_triage"
    assert html =~ "no transcript"
  end
  # ==========================================================================
  # A5 FOLD F1 — the approver-membership seam, on a REAL Identity mount
  # ==========================================================================

  describe "Samen.AI.Agent.Approver over a real materialized Membership resource" do
    alias Samen.AI.Agent.Approver
    alias Samen.WebTest.Operator.Membership
    alias Samen.WebTest.Operator.User

    test "resolves a REAL member with their REAL role, and refuses everyone else",
         %{org_id: org_id} do
      # The host seam here is the genuine `use Samen.Scopes.Identity` Membership resource
      # (config :samen_core, Samen.AI.Agent, approver_membership: …), so this exercises
      # the Ash-RESOURCE path of the fold rather than a fixture.
      assert Approver.seam() == Membership

      {owner, _} = seed_member!(org_id, :owner)
      {member, _} = seed_member!(org_id, :member)

      assert {:ok, owner_scope} = Approver.resolve(owner.id, org_id)
      assert owner_scope.actor.id == owner.id
      assert owner_scope.actor.org_id == org_id

      assert owner_scope.actor.role == :owner,
             "the approver's REAL role must ride the scope — A4 hardcoded :member here"

      assert {:ok, member_scope} = Approver.resolve(member.id, org_id)
      assert member_scope.actor.role == :member
      assert member_scope.actor.membership_id != nil

      # RED: a wholly foreign actor id is refused — no membership row, no authority.
      assert {:error, :not_authorized} = Approver.resolve(Ash.UUID.generate(), org_id)

      # RED: a real member of ANOTHER org is not a member here.
      other_org = Ash.UUID.generate()
      {elsewhere, _} = seed_member!(other_org, :owner)
      assert {:error, :not_authorized} = Approver.resolve(elsewhere.id, org_id)
      # ...positive control: they DO resolve in their own org.
      assert {:ok, _} = Approver.resolve(elsewhere.id, other_org)
    end

    test "an UNWIRED host is fail-closed — never a synthesized member", %{org_id: org_id} do
      {member, _} = seed_member!(org_id, :member)
      prior = Application.get_env(:samen_core, Samen.AI.Agent, [])
      Application.put_env(:samen_core, Samen.AI.Agent, Keyword.delete(prior, :approver_membership))

      try do
        assert Approver.seam() == nil
        assert {:error, :approver_unresolvable} = Approver.resolve(member.id, org_id)
      after
        Application.put_env(:samen_core, Samen.AI.Agent, prior)
      end

      assert {:ok, _} = Approver.resolve(member.id, org_id)
    end

    defp seed_member!(org_id, role) do
      user =
        User
        |> Ash.Changeset.for_create(:create, %{org_id: org_id, handle: "u-#{System.unique_integer([:positive])}"})
        |> Ash.create!(authorize?: false)

      membership =
        Membership
        |> Ash.Changeset.for_create(:create, %{org_id: org_id, user_id: user.id, role: role})
        |> Ash.create!(authorize?: false)

      {user, membership}
    end
  end
end
