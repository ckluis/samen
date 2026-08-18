defmodule PawChart.AgentPlaneUnwiredTest do
  @moduledoc """
  ADR-047 A6 fold F2 (the A5 verifier's **R-A5-4**) — the fail-HONEST proof for a host
  that inherits the operator agent-health route but wired NO agent plane.

  PawChart mounts `samen_operator_routes/2`, so it inherits `/operator/agents/:org_id` at
  0 authored LOC — but it configures none of `:samen_ai_agent_{run,turn,kill}_repo`. Until
  A6 every read on that page rescued to `[]`, so the surface rendered the positive claim
  *"No agent runs for this org"* from a plane it is structurally incapable of reading.
  That is the ADR-014/024/026 fail-honest contract inverted: an adapter that did no work
  must never report success, and on a DISPLAY an empty list IS a success claim.

  This is the unwired half of the pair. The WIRED half — a host where the same calls
  answer, and an org with no runs is honestly empty — is proven in
  `samen_web/test/samen/web/ai/agent_surface_test.exs` and, over real data, in
  `driftwood/test/gate_a6_agent_slice_test.exs`. Neither an always-unavailable nor an
  always-available regression can pass both.

  **PawChart stays unwired on purpose.** A6 does not give this vertical agent tables; it
  makes the page it already inherited tell the truth about not having them.
  """
  use ExUnit.Case, async: false

  alias Samen.AI.Agent.Breaker
  alias Samen.AI.Agent.Health
  alias Samen.OperatorPlane.Actor

  @org_id "0f000000-0000-4000-8000-0000000000c9"

  test "pawchart INHERITS the operator agent-health route (this is why the fold matters here)" do
    paths = Enum.map(PawChartWeb.Router.__routes__(), & &1.path)

    assert "/operator/agents/:org_id" in paths,
           "the fold's premise is that this route is inherited at 0 LOC — it is not mounted"
  end

  test "the agent-plane repo seams are DELIBERATELY unwired on this host" do
    for key <- [:samen_ai_agent_run_repo, :samen_ai_agent_turn_repo, :samen_ai_agent_kill_repo] do
      refute Application.get_env(:samen_core, key) == PawChart.Repo,
             "#{key} is wired — pawchart is the deliberately-unwired host in this pair"
    end
  end

  test "availability/0 answers :unavailable — and every read REFUSES rather than claiming empty" do
    operator = Actor.new("op-paw", :operator_admin)

    assert Health.availability() == :unavailable
    refute Health.available?()

    assert {:error, :unavailable} = Health.summary(operator, @org_id)
    assert {:error, :unavailable} = Health.runs(operator, @org_id)
    assert {:error, :unavailable} = Health.turns(operator, @org_id, Ash.UUID.generate())

    # The three of these previously answered `{:ok, []}` — an empty SUCCESS from a plane
    # that cannot be read at all.
    refute match?({:ok, []}, Health.summary(operator, @org_id))
    refute match?({:ok, []}, Health.runs(operator, @org_id))

    # AUTHZ still refuses first: an unauthorized caller learns nothing about host wiring.
    assert {:error, :not_authorized} = Health.summary(%{id: "nobody"}, @org_id)
  end

  test "the durable kill read is honest too: :unavailable, never a readable-empty list" do
    assert {:error, :unavailable} = Breaker.kills_status(@org_id)
    assert {:error, :unavailable} = Health.kills(Actor.new("op-paw", :operator_admin), @org_id)

    # The GATE is untouched and still fails CLOSED — the fold is about what the surface
    # CLAIMS, never about what the breaker permits.
    assert Breaker.definition_killed?(@org_id, "anything")
    assert Breaker.killed?(@org_id, "anything")
  end

  test "the page renders the explicit NOT-WIRED state, never the empty-success card" do
    assigns = %{
      samen_mount:
        Samen.Web.Mount.new(:operator, PawChart.Operator, PawChart.Repo,
          plane: Samen.Web.Plane.tenant(),
          labels: %{operator_org_id: @org_id, operator_workspace: "PawChart Ops"}
        ),
      no_org: false,
      impersonation: :active,
      target_org_id: @org_id,
      operator: Actor.new("op-paw", :operator_admin),
      agent_plane: Health.availability(),
      summary: [],
      runs: [],
      turns: [],
      selected_run: nil,
      action_error: nil,
      session_info: nil,
      open_error: nil
    }

    html =
      assigns
      |> Map.put(:__changed__, %{})
      |> Samen.Web.Operator.AgentHealthLive.render()
      |> Phoenix.HTML.Safe.to_iodata()
      |> IO.iodata_to_binary()

    assert html =~ "agent-plane-unavailable"
    assert html =~ "Agent plane not wired on this host"

    refute html =~ "No agent runs for this org.",
           "the unwired host still claims it read nothing — R-A5-4 regression"
  end
end
