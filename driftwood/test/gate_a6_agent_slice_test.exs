defmodule Driftwood.GateA6AgentSliceTest do
  @moduledoc """
  GATE PROBE — ADR-047 batch **A6**, the v1 vertical slice (§9#7 TAKEN: *driftwood support
  triage*), end to end on a REAL host: **agent run → masked read → write PROPOSAL → the
  tenant decision card → a human's approve click → the write EXECUTES as that human →
  the run resumes and completes**, all keyless under `Samen.AI.Provider.Scripted`.

  This is the proof A5 could not give. `samen_web`'s scratch host mounts no `apv_approval`
  resource, so the click-to-EXECUTE round trip and the decision card's id-discrimination
  arm were both unprovable there (the A5 verifier's R-A5-5). Driftwood has a real E3
  engine, a real Identity spine, and — as of A6 — real agent wiring, so both land here.

  ## What the slice ADOPTS versus what it AUTHORS (the ≈0-LOC leverage guard)

  Authored in this vertical: `Driftwood.Support.TriageAgent`'s definition and ONE
  `samen_ai_routes` router call. Everything the tests below drive — the loop, the four-way
  tool intersection, EG2 scrubbing, the propose-then-approve park, the approval engine, the
  approver-membership resolution, the run list / run detail / transcript / turn log /
  decision card, and the operator agent-health page — is framework code the vertical did
  not write. `test "LEVERAGE GUARD"` pins that with a line count that fails if it drifts.

  ## The reds, each with its positive control (anti-tautology)

    * an UNAUTHENTICATED session cannot decide (the card refuses before the engine);
    * the SYNTHETIC per-org `broker:<org_id>` principal — what A5's card actually acted as
      — is not a member and cannot decide (R-A5-3, shipped red);
    * a crafted `phx-value-id` naming ANOTHER run's real pending approval refuses
      (**the id-discrimination arm** R-A5-5 named as owed live), and that other run's
      target record stays unmutated;
    * a `:viewer`-role member's approve is refused by the TARGET's `RoleAtLeast :member`
      gate and the whole decision rolls back — proving the approver's REAL role rides the
      execution, not a synthesized `:member`;
    * a rejection terminates the run `:rejected` and executes nothing.

  Positive controls: the same click by a real `:admin` member executes exactly once, the
  record carries the proposed owner, the audit chain names that human, and the run reaches
  `:succeeded`.
  """
  use Driftwood.DataCase, async: false
  use Samen.AgentCase

  require Ash.Query

  alias Driftwood.Support.TriageAgent
  alias Samen.AI.Agent.Run
  alias Samen.AI.Agent.WriteProposal
  alias Samen.AI.Provider.Scripted
  alias Samen.Approvals
  alias Samen.Web.AI.AgentLive

  @task_key "Driftwood.Work.Task"
  @agent_key "Driftwood.Support.Agent"

  # A PII canary on the read target: `Driftwood.Support.Agent.full_name`/`email` are
  # vault-routed (🔒), so what reaches the model must be `••••`, never this.
  @person_canary "a6-triage-canary@leak.example"

  setup do
    Scripted.reset()
    Samen.AI.Agent.Breaker.reset()

    # The DURABLE worker re-resolves its provider from host config (it runs in an Oban
    # job, not in the caller's process), so the keyless scripted double is pointed at
    # from there for the resume leg — the same seam `samen_core`'s own worker tests use.
    # Driftwood's shipped config names no provider at all: this host is keyless, and a
    # keyless host is honest about it rather than fabricating an answer.
    previous = Application.get_env(:samen_core, Samen.AI.Agent, [])

    Application.put_env(
      :samen_core,
      Samen.AI.Agent,
      Keyword.merge(previous, provider: scripted_provider())
    )

    on_exit(fn ->
      Application.put_env(:samen_core, Samen.AI.Agent, previous)
      Scripted.reset()
    end)

    org_id = Ash.UUID.generate()
    %{org_id: org_id}
  end

  # ---------------------------------------------------------------------------
  # Fixtures — real driftwood rows, created through governed actions
  # ---------------------------------------------------------------------------

  defp task!(org_id, title \\ "Follow up: shipment 4471 is late") do
    Driftwood.Work.Task
    |> Ash.Changeset.for_create(:create, %{org_id: org_id, title: title}, authorize?: false)
    |> Ash.create!()
  end

  defp reload_task!(id) do
    Driftwood.Work.Task
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.ensure_selected([:owner_id])
    |> Ash.read!(authorize?: false)
    |> hd()
  end

  defp support_agent!(org_id) do
    Driftwood.Support.Agent
    |> Ash.Changeset.for_create(
      :create,
      %{
        org_id: org_id,
        handle: "dispatch-#{System.unique_integer([:positive])}",
        full_name: %{first: "Hilda", last: "Ostrand"},
        email: @person_canary
      },
      authorize?: false
    )
    |> Ash.create!()
  end

  # A real member of the org, through driftwood's REAL Identity spine — the same
  # `Driftwood.Operator.{User,Membership}` rows `approver_membership:` points the kernel at.
  defp member!(org_id, role) do
    user =
      Driftwood.Operator.User
      |> Ash.Changeset.for_create(:create, %{
        org_id: org_id,
        handle: "a6-#{role}-#{System.unique_integer([:positive])}"
      })
      |> Ash.create!(authorize?: false)

    Driftwood.Operator.Membership
    |> Ash.Changeset.for_create(:create, %{org_id: org_id, user_id: user.id, role: role})
    |> Ash.create!(authorize?: false)

    user.id
  end

  defp tenant_scope(org_id) do
    %Samen.Scope{actor: %{id: "u:#{org_id}", org_id: org_id, role: :member, plane: :tenant}}
  end

  # THE full triage run: a read tool over a 🔒 person record, then the write PROPOSAL.
  # Multi-turn by construction — the loop must come back for a second decision.
  defp propose!(org_id, task_id, new_owner_id) do
    person = support_agent!(org_id)

    script([
      {:tool_call, "fetch_record", %{"resource" => @agent_key, "id" => person.id}},
      {:tool_call, "assign_record_owner",
       %{"resource" => @task_key, "id" => task_id, "user_id" => new_owner_id}},
      {:final, "assigned (must never be reached before a human approves)"}
    ])

    result =
      run_scripted(TriageAgent, tenant_scope(org_id), "why is shipment 4471 late and who should own it?")

    assert {:awaiting_approval, run} = result
    {run, person}
  end

  defp only_pending!(org_id) do
    {:ok, [approval]} = Approvals.list_pending(org_id, WriteProposal.kind())
    approval
  end

  # The tenant agent surface, mounted EXACTLY as the router mounts it, with the
  # authenticated principal pinned the way `Samen.Web.TenantAuthz`'s on_mount pins it.
  defp agent_socket(org_id, run_id, principal) do
    %Phoenix.LiveView.Socket{}
    |> Phoenix.Component.assign(:samen_mount, driftwood_mount(:ai))
    |> Phoenix.Component.assign(:samen_acting_as, false)
    |> Phoenix.Component.assign(:samen_tenant_principal, principal)
    |> AgentLive.load(org_id, run_id: run_id)
  end

  defp click(socket, event, approval_id) do
    {:noreply, socket} = AgentLive.handle_event(event, %{"id" => approval_id}, socket)
    socket
  end

  defp audit_events(subject_ref) do
    %{rows: rows} =
      Ecto.Adapters.SQL.query!(
        Driftwood.Repo,
        "SELECT ach_event_type, ach_actor_id FROM aud_chain WHERE ach_subject_id = $1",
        [subject_ref]
      )

    rows
  end

  # ===========================================================================
  # 1 · ADOPTION — the routes, and the leverage guard
  # ===========================================================================

  describe "≈0-LOC adoption (ADR-047 §9#7: the AI kit had a mount seam with no adoption proof)" do
    test "the ONE samen_ai_routes call mounts all six tenant AI surfaces INCLUDING the agent pair" do
      routes = Map.new(DriftwoodWeb.Router.__routes__(), &{&1.path, &1})

      for path <- ["/ai", "/ai/search", "/ai/crm", "/ai/analytics", "/ai/support"] do
        assert Map.has_key?(routes, path), "expected #{path} from samen_ai_routes/3"
      end

      # THE A6 pair — inherited, not authored.
      assert elem(routes["/ai/agents"].metadata.phoenix_live_view, 0) == Samen.Web.AI.AgentLive
      assert elem(routes["/ai/agents/:id"].metadata.phoenix_live_view, 0) == Samen.Web.AI.AgentLive

      # And the operator half is inherited by the EXISTING samen_operator_routes call.
      assert elem(routes["/operator/agents/:org_id"].metadata.phoenix_live_view, 0) ==
               Samen.Web.Operator.AgentHealthLive
    end

    test "every /ai route rides the framework TENANT gate (the on_mount is inside the macro)" do
      ai_routes =
        Enum.filter(DriftwoodWeb.Router.__routes__(), &String.starts_with?(&1.path, "/ai"))

      # Non-vacuity: there ARE seven of them (five kit surfaces + the A6 agent pair).
      assert length(ai_routes) == 7

      for route <- ai_routes do
        {_view, _action, _opts, live_session} = route.metadata.phoenix_live_view

        assert Enum.any?(
                 live_session.extra.on_mount || [],
                 &match?(%{id: {Samen.Web.TenantAuthz, :require_tenant}}, &1)
               ),
               "#{route.path} is not behind {Samen.Web.TenantAuthz, :require_tenant}"

        # The mount really is driftwood's, threaded by the macro (not a framework default).
        assert live_session.extra.session["samen_mount"]["repo"] == "Elixir.Driftwood.Repo"
      end
    end

    test "LEVERAGE GUARD: the authored vertical agent code is a definition and a mount, nothing else" do
      authored =
        "lib/driftwood/support/triage_agent.ex"
        |> File.read!()
        |> code_lines()

      # The whole vertical agent artifact: `defmodule` + `use Samen.AI.Agent` with its
      # name/goal_prompt/tools + `end`. No loop, no provider, no masking, no approval, no UI.
      # 13 today: 5 lines of DEFINITION (defmodule / use / name: / tools: / end) + an
      # 8-line goal-prompt heredoc. §8/A6's guard is "authored vertical LOC ≤ ~10" of
      # substance; the ceiling here leaves room for the prompt to breathe and nothing else.
      assert authored <= 18,
             "authored agent LOC drifted to #{authored} — re-implementing framework " <>
               "behaviour in the vertical is exactly what this guard forbids"

      assert authored >= 8, "the guard went vacuous — it is not reading the module"

      source = File.read!("lib/driftwood/support/triage_agent.ex")
      assert source =~ "use Samen.AI.Agent"

      for forbidden <- ["defp ", "Ash.read", "Ash.update", "Approvals.", "Masked", "PiiResolution"] do
        refute source =~ forbidden,
               "the vertical agent module re-implements framework behaviour (#{forbidden})"
      end

      # The router mount is ONE macro call over the host's own namespace + repo.
      router = File.read!("lib/driftwood_web/router.ex")
      assert router =~ "samen_ai_routes(:ai, Driftwood.Crm,"
      assert length(Regex.scan(~r/samen_ai_routes\(/, router)) == 1
    end
  end

  # ===========================================================================
  # 2 · THE E2E — click to execute
  # ===========================================================================

  describe "click-to-execute, end to end on the vertical" do
    test "PROPOSE → decision card → APPROVE click → the write executes AS THE HUMAN → the run completes",
         %{org_id: org_id} do
      approver = member!(org_id, :admin)
      new_owner = member!(org_id, :member)
      task = task!(org_id)

      {run, person} = propose!(org_id, task.id, new_owner)

      # (a) NOTHING executed on the propose: the run parked, the record is untouched.
      assert run.state == :awaiting_approval
      assert is_nil(reload_task!(task.id).owner_id)

      # (b) the READ tool ran, and the 🔒 person fields reached the model MASKED.
      assert Enum.any?(turn_rows(run), &(&1.tool_kind == "fetch_record"))
      refute Enum.any?(sent_texts(), &String.contains?(&1, @person_canary))
      refute Enum.any?(sent_texts(), &String.contains?(&1, "Ostrand"))
      assert Enum.any?(sent_texts(), &String.contains?(&1, "••••")),
             "the masked person fields never reached the model at all — the read proof is vacuous"

      assert person.id

      # (c) the DECISION CARD renders on the tenant plane with TOKEN-ONLY provenance.
      approval = only_pending!(org_id)
      socket = agent_socket(org_id, run.id, approver)
      html = render_live(AgentLive, socket)

      assert html =~ "agent-decision-card"
      assert html =~ "Awaiting your decision"

      card = decision_card(html)
      assert card =~ "assign_record_owner"
      assert card =~ "id, resource, user_id"

      # INV-1: the card carries arg key NAMES + a digest, never arg VALUES. (The values
      # live only inside the run's vault-routed transcript, which the panel BELOW the card
      # renders on the caller's plane — that is a different, plane-resolved surface.)
      refute card =~ task.id
      refute card =~ new_owner
      refute card =~ @task_key

      # (d) THE CLICK. The approver is the AUTHENTICATED principal, not `broker:<org>`.
      socket = click(socket, "approve", approval.id)
      assert {:ok, msg} = socket.assigns.outcome
      assert msg =~ "executed as you"

      # (e) THE WRITE LANDED — once, with exactly the proposed value.
      assert reload_task!(task.id).owner_id == new_owner

      # (f) the RUN RESUMED. The decision transaction un-parks it (`:running`) and enqueues
      # the continuation in the SAME transaction (the EventCapture idiom), so the durable
      # worker — not the click — runs the next turn. Driving that worker here is the honest
      # equivalent of Oban picking the job up.
      assert %Run{state: :running} = Ash.get!(Run, run.id, authorize?: false)
      assert :ok = Samen.AI.Agent.TurnWorker.perform(%Oban.Job{args: %{"run_id" => run.id}})
      assert %Run{state: :succeeded} = Ash.get!(Run, run.id, authorize?: false)

      # (g) the AUDIT names the REAL HUMAN — never `broker:<org_id>`, never the AI principal.
      events = audit_events(approval.subject_ref)
      approvers = for [type, actor] <- events, type == "approval_approved", do: actor

      assert approvers == [approver],
             "the APPROVE audit must name the real logged-in human exactly once"

      # The AI principal IS the requester (it appears on `approval_requested` — the
      # non-vacuity control below) and can never be a DECIDER; the synthetic per-org
      # pseudo-principal appears nowhere at all.
      assert Enum.any?(events, fn [type, actor] ->
               type == "approval_requested" and actor == WriteProposal.requester_principal_id()
             end)

      refute WriteProposal.requester_principal_id() in approvers
      refute Enum.any?(events, fn [_type, actor] -> actor == "broker:#{org_id}" end)
    end

    test "REJECT click: the run terminates :rejected and NOTHING executes", %{org_id: org_id} do
      approver = member!(org_id, :admin)
      new_owner = member!(org_id, :member)
      task = task!(org_id)
      {run, _person} = propose!(org_id, task.id, new_owner)
      approval = only_pending!(org_id)

      socket =
        org_id
        |> agent_socket(run.id, approver)
        |> click("reject", approval.id)

      assert {:ok, msg} = socket.assigns.outcome
      assert msg =~ "nothing was executed"

      assert %Run{state: :rejected} = Ash.get!(Run, run.id, authorize?: false)
      assert is_nil(reload_task!(task.id).owner_id)
      assert {:ok, []} = Approvals.list_pending(org_id, WriteProposal.kind())
    end
  end

  # ===========================================================================
  # 3 · THE REFUSALS (each paired against the executing positive control above)
  # ===========================================================================

  describe "the decision card's refusals, proven on a host that HAS a real approvals engine" do
    test "R-A5-3 RED: the SYNTHETIC broker:<org_id> principal cannot approve — and a real member can",
         %{org_id: org_id} do
      new_owner = member!(org_id, :member)
      task = task!(org_id)
      {run, _} = propose!(org_id, task.id, new_owner)
      approval = only_pending!(org_id)

      # A5's card acted as this: the per-ORG pseudo-principal off `Mount.scope/2`.
      broker = "broker:#{org_id}"
      assert %Samen.Scope{actor: %{id: ^broker}} = Samen.Web.Mount.scope(driftwood_mount(:ai), org_id)

      socket =
        org_id
        |> agent_socket(run.id, broker)
        |> click("approve", approval.id)

      assert {:error, msg} = socket.assigns.outcome
      assert msg =~ "not a member of this org"
      assert is_nil(reload_task!(task.id).owner_id)
      assert %Run{state: :awaiting_approval} = Ash.get!(Run, run.id, authorize?: false)

      # POSITIVE CONTROL — the ONLY variable is the principal.
      approver = member!(org_id, :admin)

      socket =
        org_id
        |> agent_socket(run.id, approver)
        |> click("approve", approval.id)

      assert {:ok, _} = socket.assigns.outcome
      assert reload_task!(task.id).owner_id == new_owner
    end

    test "an UNAUTHENTICATED session decides nothing — refused before the engine", %{org_id: org_id} do
      new_owner = member!(org_id, :member)
      task = task!(org_id)
      {run, _} = propose!(org_id, task.id, new_owner)
      approval = only_pending!(org_id)

      socket =
        org_id
        |> agent_socket(run.id, nil)
        |> click("approve", approval.id)

      assert {:error, msg} = socket.assigns.outcome
      assert msg =~ "signed in"
      assert is_nil(reload_task!(task.id).owner_id)
      assert %Run{state: :awaiting_approval} = Ash.get!(Run, run.id, authorize?: false)
    end

    test "R-A5-5 ID-DISCRIMINATION: a crafted click carrying ANOTHER run's real approval id refuses",
         %{org_id: org_id} do
      approver = member!(org_id, :admin)
      owner_a = member!(org_id, :member)
      owner_b = member!(org_id, :member)

      task_a = task!(org_id, "A: shipment 4471")
      {run_a, _} = propose!(org_id, task_a.id, owner_a)
      approval_a = only_pending!(org_id)

      # A SECOND parked run in the SAME org — so the refusal cannot be "no such approval".
      Scripted.reset()
      task_b = task!(org_id, "B: shipment 9002")
      {run_b, _} = propose!(org_id, task_b.id, owner_b)

      {:ok, pending} = Approvals.list_pending(org_id, WriteProposal.kind())
      assert length(pending) == 2
      approval_b = Enum.find(pending, &(&1.id != approval_a.id))

      # Viewing run A, click carrying run B's REAL pending approval id.
      socket =
        org_id
        |> agent_socket(run_a.id, approver)
        |> click("approve", approval_b.id)

      assert {:error, msg} = socket.assigns.outcome
      assert msg =~ "no longer pending for this run"

      # NEITHER record moved, BOTH runs are still parked, BOTH approvals still pending.
      assert is_nil(reload_task!(task_a.id).owner_id)
      assert is_nil(reload_task!(task_b.id).owner_id)
      assert %Run{state: :awaiting_approval} = Ash.get!(Run, run_a.id, authorize?: false)
      assert %Run{state: :awaiting_approval} = Ash.get!(Run, run_b.id, authorize?: false)
      assert {:ok, [_, _]} = Approvals.list_pending(org_id, WriteProposal.kind())

      # POSITIVE CONTROL — the same id, clicked from ITS OWN run's page, executes.
      socket =
        org_id
        |> agent_socket(run_b.id, approver)
        |> click("approve", approval_b.id)

      assert {:ok, _} = socket.assigns.outcome
      assert reload_task!(task_b.id).owner_id == owner_b
      assert is_nil(reload_task!(task_a.id).owner_id)
    end

    test "the approver's REAL role rides the execution: a :viewer is refused by the TARGET's role gate",
         %{org_id: org_id} do
      viewer = member!(org_id, :viewer)
      new_owner = member!(org_id, :member)
      task = task!(org_id)
      {run, _} = propose!(org_id, task.id, new_owner)
      approval = only_pending!(org_id)

      socket =
        org_id
        |> agent_socket(run.id, viewer)
        |> click("approve", approval.id)

      # `Driftwood.Work.Task`'s write policy is `RoleAtLeast :member`; :viewer ranks below
      # it, so the handler errors and the WHOLE decision rolls back.
      assert {:error, _} = socket.assigns.outcome
      assert is_nil(reload_task!(task.id).owner_id)
      assert %Run{state: :awaiting_approval} = Ash.get!(Run, run.id, authorize?: false)
      assert {:ok, [_]} = Approvals.list_pending(org_id, WriteProposal.kind())

      # POSITIVE CONTROL: an :admin member of the SAME org, same proposal, executes.
      admin = member!(org_id, :admin)

      socket =
        org_id
        |> agent_socket(run.id, admin)
        |> click("approve", approval.id)

      assert {:ok, _} = socket.assigns.outcome
      assert reload_task!(task.id).owner_id == new_owner
    end
  end

  # ===========================================================================
  # 4 · FAIL-HONEST FLOOR + the OPERATOR plane, on this vertical
  # ===========================================================================

  describe "the vertical inherits the fail-honest floor and the operator oversight plane" do
    test "budget exhaustion on a hard case is terminal and never a partial answer", %{org_id: org_id} do
      script([{:continue, "still looking"}, {:continue, "still looking"}, {:continue, "still looking"}])

      result =
        run_scripted(TriageAgent, tenant_scope(org_id), "unanswerable: why is 4471 late?",
          budgets: [max_turns: 2]
        )

      run = assert_honest_exhaustion!(result)

      html =
        org_id
        |> agent_socket(run.id, nil)
        |> then(&render_live(AgentLive, &1))

      assert html =~ "Stopped at a budget"
      assert html =~ "not a partial answer"
      refute html =~ "still looking</pre>"
    end

    test "the OPERATOR agent-health API reads DRIFTWOOD's real agent tables (not an empty claim)",
         %{org_id: org_id} do
      new_owner = member!(org_id, :member)
      task = task!(org_id)
      {run, _} = propose!(org_id, task.id, new_owner)

      # The host IS wired — so the plane is available and the empty state would be a lie.
      assert Samen.AI.Agent.Health.availability() == :available

      operator = Samen.OperatorPlane.Actor.new("driftwood-operator", :operator_admin)
      assert {:ok, summary} = Samen.AI.Agent.Health.summary(operator, org_id)
      assert [%{agent: "driftwood.support_triage"} = row] = summary
      assert row.total_runs == 1
      assert row.awaiting_approval == 1
      assert row.kill_state == :active

      assert {:ok, [projected]} = Samen.AI.Agent.Health.runs(operator, org_id)
      assert projected.id == run.id

      # §7.3 on driftwood's own rows: the operator projection carries NO transcript.
      refute Map.has_key?(projected, :transcript)
      refute inspect(summary ++ [projected], limit: :infinity) =~ "vt_"
    end
  end

  # ---------------------------------------------------------------------------

  defp code_lines(source) do
    source
    |> String.split("\n")
    |> Enum.reject(&(String.trim(&1) == ""))
    |> Enum.reject(&String.starts_with?(String.trim(&1), "#"))
    |> drop_moduledoc()
    |> length()
  end

  # Drop the `@moduledoc """ … """` block — documentation is not authored behaviour.
  defp drop_moduledoc(lines) do
    case Enum.find_index(lines, &String.contains?(&1, "@moduledoc \"\"\"")) do
      nil ->
        lines

      start ->
        rest = Enum.drop(lines, start + 1)
        close = Enum.find_index(rest, &(String.trim(&1) == "\"\"\""))
        Enum.take(lines, start) ++ Enum.drop(rest, close + 1)
    end
  end

  # Just the decision card — the fragment whose INV-1 token-only claim is under test
  # (the transcript panel below it legitimately renders arg values on the tenant plane).
  defp decision_card(html) do
    [_, rest] = String.split(html, ~s(id="agent-decision-card"), parts: 2)
    [card, _] = String.split(rest, ~s(id="agent-transcript"), parts: 2)
    card
  end

  defp render_live(module, %Phoenix.LiveView.Socket{} = socket) do
    socket.assigns
    |> Map.put(:__changed__, %{})
    |> module.render()
    |> Phoenix.HTML.Safe.to_iodata()
    |> IO.iodata_to_binary()
  end
end
