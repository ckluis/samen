defmodule Driftwood.AgentTranscriptMaskingTest do
  @moduledoc """
  ADR-047 A6 — the per-plane masking gate (CLAUDE.md "Per-plane masking tests", three
  proofs per surface) for the agent surfaces **on the vertical**, over rows a REAL
  driftwood run produced.

  The vault-routed field is `Samen.AI.Agent.Run.transcript` — the run's goal (tenant free
  text) plus its rendered assistant lines, inside the DEK envelope keyed on the run's own
  id. `samen_web`'s three proofs cover the framework surface over a scratch host; these
  cover the SAME surface as driftwood actually mounts it (`samen_ai_routes` → `/ai/agents`,
  `Driftwood.Repo`, driftwood's own vault), because a mount is exactly where a per-plane
  guarantee can silently stop holding.

    1. **GREEN** — the TENANT plane resolves the transcript CLEAR: the canary is in the
       DOM, no `vt_*` token is.
    2. **RED** — the OPERATOR-without-grant plane renders `••••` on the SAME run: canary
       absent, no `vt_*` token. Mask-by-omission.
    3. **SABOTAGE twin** — the scan is refutable (`assert_leak_detected!/2`), and the ONLY
       difference between 1 and 2 is the plane (`resolve_on_plane/4` over the identical row).

  Plus §7.3's stronger operator rule on driftwood's own rows: the operator agent-health
  projection does not CARRY the transcript at all — and the 🔒 person fields a read tool
  touched never reached the model in the clear either.

  Sabotage 261 flips the framework reds, and the in-suite twin below
  (`assert_leak_detected!/2` + the plane-flip control) keeps the vertical's scan refutable
  without a second patch for the same invariant.
  """
  use Driftwood.DataCase, async: false
  use Samen.MaskingCase
  use Samen.AgentCase

  require Ash.Query

  alias Driftwood.Support.TriageAgent
  alias Samen.AI.Agent.Run
  alias Samen.AI.Provider.Scripted
  alias Samen.Web.AI.AgentLive
  alias Samen.Web.AI.AgentReads

  @goal_canary "A6-DRIFTWOOD-CANARY: shipment 4471 is late, contact hilda@leak.example"
  @person_canary "a6-mask-canary@leak.example"

  setup do
    Scripted.reset()
    Samen.AI.Agent.Breaker.reset()
    on_exit(fn -> Scripted.reset() end)

    org_id = Ash.UUID.generate()

    person =
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

    script([
      {:tool_call, "fetch_record",
       %{"resource" => "Driftwood.Support.Agent", "id" => person.id}},
      {:final, "the dispatch agent is the owner"}
    ])

    scope = %Samen.Scope{
      actor: %{id: "u:#{org_id}", org_id: org_id, role: :member, plane: :tenant}
    }

    assert {:ok, %{run: run}} = run_scripted(TriageAgent, scope, @goal_canary)

    %{org_id: org_id, run: run}
  end

  defp render_detail(org_id, plane, run_id) do
    %Phoenix.LiveView.Socket{}
    |> Phoenix.Component.assign(:samen_mount, mount_for(org_id, plane))
    |> Phoenix.Component.assign(:samen_acting_as, plane == :operator)
    |> Phoenix.Component.assign(:samen_tenant_principal, nil)
    |> AgentLive.load(org_id, run_id: run_id)
    |> then(fn socket ->
      socket.assigns
      |> Map.put(:__changed__, %{})
      |> AgentLive.render()
      |> Phoenix.HTML.Safe.to_iodata()
      |> IO.iodata_to_binary()
    end)
  end

  defp mount_for(_org_id, :tenant), do: driftwood_mount(:ai)
  defp mount_for(org_id, :operator), do: driftwood_mount(:ai, plane: :operator, target_org_id: org_id)

  # ==========================================================================

  test "GREEN: the TENANT plane renders driftwood's agent transcript CLEAR (never a vault token)",
       %{org_id: org_id, run: run} do
    html = render_detail(org_id, :tenant, run.id)

    # Non-vacuity: this really is the run detail on driftwood's mounted surface.
    assert html =~ "agent-run-detail"
    assert html =~ "agent-transcript"
    assert html =~ "driftwood.support_triage"

    assert html =~ @goal_canary
    refute html =~ "vt_", "the raw vault token reached the tenant DOM — the resolver was bypassed"
  end

  test "RED: the OPERATOR-without-grant plane renders •••• on the SAME driftwood run",
       %{org_id: org_id, run: run} do
    html = render_detail(org_id, :operator, run.id)

    assert html =~ "agent-run-detail"
    assert html =~ "agent-transcript"

    assert_masked_dom!(html, [@goal_canary])
  end

  test "SABOTAGE twin: the scan DETECTS a modeled leak, and the plane is the only difference",
       %{org_id: org_id, run: run} do
    leaked = render_detail(org_id, :tenant, run.id)
    assert_leak_detected!(leaked, @goal_canary)

    [row] =
      Run
      |> Ash.Query.filter(id == ^run.id)
      |> Ash.Query.ensure_selected([:org_id, :transcript])
      |> Ash.read!(authorize?: false)

    tenant = resolve_on_plane(row, Run, :tenant, repo: Driftwood.Repo).transcript
    operator = resolve_on_plane(row, Run, :operator, repo: Driftwood.Repo).transcript

    assert tenant =~ @goal_canary
    assert_plane_masked!(operator)
    assert to_string(operator) == mask()

    # The surface passes the mask THROUGH rather than hand-writing one.
    {:ok, detail} = AgentReads.get(mount_for(org_id, :operator), org_id, run.id)
    assert match?(%Samen.Masked{}, detail.goal)
  end

  test "the 🔒 person fields the READ TOOL touched never reached the model in the clear",
       %{run: run} do
    # Non-vacuity: the read tool really ran and really rendered that record.
    assert Enum.any?(turn_rows(run), &(&1.tool_kind == "fetch_record"))
    assert Enum.any?(sent_texts(), &String.contains?(&1, "Driftwood.Support.Agent#"))

    refute Enum.any?(sent_texts(), &String.contains?(&1, @person_canary))
    refute Enum.any?(sent_texts(), &String.contains?(&1, "Ostrand"))
    refute Enum.any?(sent_texts(), &String.contains?(&1, "vt_"))

    assert Enum.any?(sent_texts(), &String.contains?(&1, "••••")),
           "the masked fields were omitted rather than masked — §9#7 wants masking LOAD-BEARING here"
  end

  test "§7.3 on driftwood's rows: the OPERATOR agent-health projection carries no transcript",
       %{org_id: org_id, run: run} do
    operator = Samen.OperatorPlane.Actor.new("driftwood-operator", :operator_admin)

    assert {:ok, [projected]} = Samen.AI.Agent.Health.runs(operator, org_id)
    assert projected.id == run.id
    assert projected.agent == "driftwood.support_triage"

    refute Map.has_key?(projected, :transcript)

    encoded = inspect(projected, limit: :infinity, printable_limit: :infinity)
    refute encoded =~ @goal_canary
    refute encoded =~ @person_canary
    refute encoded =~ "vt_"
  end
end
