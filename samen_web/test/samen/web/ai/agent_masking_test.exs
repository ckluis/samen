defmodule Samen.Web.AI.AgentMaskingTest do
  @moduledoc """
  ADR-047 A5 — THE PER-PLANE MASKING GATE for the agent surfaces (§7.3; the CLAUDE.md
  masking watch-list discipline, three proofs per surface).

  The vault-routed field is `Samen.AI.Agent.Run.transcript` — the run's goal plus its
  rendered assistant lines, inside the DEK envelope keyed on the run's own id. It is the
  ONE text artifact an agent run persists, and the tenant surface renders it.

  Three proofs, per CLAUDE.md:

    1. **GREEN** — the TENANT plane resolves the transcript CLEAR: the seeded canary is
       in the DOM, and no `vt_*` vault token is (the resolver ran, not the raw column).
    2. **RED** — the OPERATOR-without-grant plane renders `••••` on the SAME row: the
       canary is ABSENT from the DOM and no `vt_*` token appears. Mask-by-omission.
    3. **SABOTAGE twin (anti-tautology)** — the same scan IS refutable: a deliberately
       leaked render is caught by it (`assert_leak_detected!/2`), and the ONLY difference
       between proofs 1 and 2 is the plane (`assert_two_plane!/3` over
       `resolve_on_plane/4`), so neither a mask-everything nor a clear-everything
       regression can pass.

  Plus the OPERATOR OVERSIGHT surface's stronger rule (§7.3): `AgentHealthLive` renders
  **no transcript at all** — not even a masked one. That is enforced below the template by
  `Samen.AI.Agent.Health`'s explicit token-only run projection, so the assertion is that
  the operator projection does not CARRY the field, not merely that the HTML omits it.

  Sabotage 261 flips the named reds here.
  """
  use Samen.WebTest.DataCase, async: false
  use Samen.MaskingCase

  require Ash.Query

  alias Samen.AI.Agent.Run
  alias Samen.Web.AI.AgentLive
  alias Samen.Web.AI.AgentReads
  alias Samen.Web.Mount
  alias Samen.WebTest.AgentFixture

  @canary "A5-TRANSCRIPT-CANARY shipment 4471 contact hilda@leak.example"
  @line_canary "A5-LINE-CANARY the owner is Hilda Ostrand"

  setup do
    org_id = Ash.UUID.generate()

    run =
      AgentFixture.run!(org_id,
        goal: @canary,
        lines: [@line_canary],
        state: :running,
        current_turn: 1
      )

    _ = AgentFixture.turn!(run)
    %{org_id: org_id, run: run}
  end

  defp agent_mount(_org_id, :tenant),
    do: Mount.new(:ai, Samen.WebTest.Crm, Samen.WebTest.Repo, plane: Samen.Web.Plane.tenant())

  defp agent_mount(org_id, :operator) do
    Mount.new(:ai, Samen.WebTest.Crm, Samen.WebTest.Repo,
      plane: Samen.Web.Plane.operator("op-1", org_id, "test-session")
    )
  end

  defp render_detail(org_id, plane, run_id) do
    mount = agent_mount(org_id, plane)

    %Phoenix.LiveView.Socket{}
    |> Phoenix.Component.assign(:samen_mount, mount)
    |> Phoenix.Component.assign(:samen_acting_as, plane == :operator)
    |> AgentLive.load(org_id, run_id: run_id)
    |> then(&render_html(AgentLive, &1.assigns))
  end

  # ==========================================================================
  # PROOF 1 — GREEN: the tenant plane resolves CLEAR
  # ==========================================================================

  test "GREEN: the TENANT plane renders the transcript CLEAR (and never a vault token)",
       %{org_id: org_id, run: run} do
    html = render_detail(org_id, :tenant, run.id)

    # Non-vacuity first: the surface really rendered THIS run's detail.
    assert html =~ "agent-run-detail"
    assert html =~ "agent-transcript"

    assert html =~ @canary
    assert html =~ @line_canary
    refute html =~ "vt_", "the raw vault token reached the tenant DOM — the resolver was bypassed"
  end

  # ==========================================================================
  # PROOF 2 — RED: operator-without-grant renders •••• (mask-by-omission)
  # ==========================================================================

  test "RED: the OPERATOR-without-grant plane renders •••• on the SAME run — canary absent, no vt_ token",
       %{org_id: org_id, run: run} do
    html = render_detail(org_id, :operator, run.id)

    # Non-vacuity: it is the same run, same surface, same panel — only the plane differs.
    assert html =~ "agent-run-detail"
    assert html =~ "agent-transcript"

    assert_masked_dom!(html, [@canary, @line_canary])
  end

  # ==========================================================================
  # PROOF 3 — the SABOTAGE twin: the scan is refutable, and the plane is the gate
  # ==========================================================================

  test "SABOTAGE twin: the same DOM scan DETECTS a modeled leak, and the plane flip is the only difference",
       %{org_id: org_id, run: run} do
    # (a) the leak scan is not a tautology: a render that DOES carry the plaintext is caught.
    leaked = render_detail(org_id, :tenant, run.id)
    assert_leak_detected!(leaked, @canary)

    # (b) the resolver — not the template — is the gate: the SAME record, resolved twice,
    # differs only by plane.
    [row] =
      Run
      |> Ash.Query.filter(id == ^run.id)
      |> Ash.Query.ensure_selected([:org_id, :transcript])
      |> Ash.read!(authorize?: false)

    tenant = resolve_on_plane(row, Run, :tenant, repo: Samen.WebTest.Repo).transcript
    operator = resolve_on_plane(row, Run, :operator, repo: Samen.WebTest.Repo).transcript

    assert tenant =~ @canary
    assert_plane_masked!(operator)
    assert to_string(operator) == mask()

    # (c) and the surface's own decode passes the mask THROUGH rather than inventing one:
    # the masked plane yields a `%Samen.Masked{}` goal, never a hand-written "••••" string.
    mount = agent_mount(org_id, :operator)
    {:ok, detail} = AgentReads.get(mount, org_id, run.id)
    assert match?(%Samen.Masked{}, detail.goal)
    assert Enum.all?(detail.lines, &match?(%Samen.Masked{}, &1))
  end

  # ==========================================================================
  # The OPERATOR OVERSIGHT surface: no transcript AT ALL (§7.3)
  # ==========================================================================

  test "the OPERATOR agent-health projection does not carry the transcript at all — mask by OMISSION, not by styling",
       %{org_id: org_id, run: run} do
    operator = Samen.OperatorPlane.Actor.new("op-1", :operator_admin)

    {:ok, runs} = Samen.AI.Agent.Health.runs(operator, org_id)
    assert [projected] = Enum.filter(runs, &(&1.id == run.id))

    # Non-vacuity: the projection DID reach this run and carries its bounded columns.
    assert projected.agent == "support_triage"
    assert projected.state == :running

    refute Map.has_key?(projected, :transcript),
           "the operator run projection carries the vault-routed transcript — §7.3 requires it be absent, not masked"

    # Nothing in the projection carries the canary or a vault token, at any depth.
    encoded = inspect(runs, limit: :infinity, printable_limit: :infinity)
    refute encoded =~ @canary
    refute encoded =~ @line_canary
    refute encoded =~ "vt_"

    # ...and the same for the turn log the operator drills into.
    {:ok, turns} = Samen.AI.Agent.Health.turns(operator, org_id, run.id)
    assert length(turns) == 1
    turn_encoded = inspect(turns, limit: :infinity, printable_limit: :infinity)
    refute turn_encoded =~ @canary
    refute turn_encoded =~ "vt_"
  end
end
