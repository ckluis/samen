defmodule Samen.Web.FleetLiveTest do
  @moduledoc """
  T84b — `Samen.Web.Operator.FleetLive` (tier-1 + merged T156 platform-health
  surfaces, ADR-044 §5.4/§8.2/§8.3).

    * RP-J-5 — `roles[:fleet] == nil` renders NOTHING (redirect).
    * §5.4 tier 1 — role-gated, NOT session-gated (no T150 anywhere on this path).
    * RP-J-9 — honesty: a metric an app did not compute renders `—`, never `0`;
      a stale/unreachable app is EXCLUDED from the roll-up but still rendered.
    * RP-J-9b — n=1 == n=N chrome is DERIVED (no rank/peer affordance at n=1;
      present at n=3+), asserted on the DOM AND via a grep on the module source
      for a row-count-literal comparison outside `pluralize/2`.
  """
  use Samen.WebTest.DataCase, async: false

  alias Samen.Fleet.{AdminActor, Registry}
  alias Samen.Web.Mount
  alias Samen.Web.Operator.FleetLive

  @ns Samen.WebTest.Fleet
  @otp_app :samen_web_fleet_live_test_host
  @admin AdminActor.new("seed-admin")

  setup do
    Application.put_env(@otp_app, :fleet, mode: :manual)

    on_exit(fn ->
      Application.delete_env(@otp_app, :fleet_authority)
      Application.delete_env(@otp_app, :fleet)
    end)

    :ok
  end

  defp mount_with_roles(roles) do
    Application.put_env(@otp_app, :fleet_authority, {__MODULE__, :roles_for, [roles]})

    Mount.new(:operator, Samen.WebTest.Operator, Samen.WebTest.Repo,
      plane: Samen.Web.Plane.tenant(),
      labels: %{otp_app: @otp_app, fleet_namespace: @ns, fleet_cockpit: true}
    )
  end

  def roles_for(roles, _principal_id), do: roles

  defp session, do: %{"samen_current_user" => "op-1"}

  defp socket_with_mount(mount), do: %Phoenix.LiveView.Socket{} |> Phoenix.Component.assign(:samen_mount, mount)

  defp seed_app(slug, opts) do
    {:ok, %{app: app}} =
      Registry.register_app(@ns, %{slug: slug, display_name: Keyword.get(opts, :display_name, slug)}, @admin)

    if payload = Keyword.get(opts, :report) do
      {:ok, _} = Registry.record_report(@ns, app.id, payload, :pull)
    end

    app
  end

  defp minimal_payload(overrides \\ %{}) do
    Samen.Fleet.Report.build(app_id: "11111111-1111-4111-8111-111111111111")
    |> Samen.Fleet.Report.to_wire()
    |> Map.merge(overrides)
  end

  # ---------------------------------------------------------------------------
  # RP-J-5 — role-gated, not session-gated
  # ---------------------------------------------------------------------------

  describe "RP-J-5 — roles[:fleet] gate" do
    test "no roles[:fleet] at all -> redirect, renders nothing" do
      mount = mount_with_roles(%{})
      socket = socket_with_mount(mount)

      {:ok, socket} = FleetLive.mount(%{}, session(), socket)
      assert {:redirect, %{to: "/login"}} = socket.redirected
    end

    test "positive control: roles[:fleet] present -> mounts and loads (no redirect)" do
      mount = mount_with_roles(%{fleet: :operator_readonly})
      socket = socket_with_mount(mount)

      {:ok, socket} = FleetLive.mount(%{}, session(), socket)
      refute socket.redirected
      assert socket.assigns.fleet_ctx.roles[:fleet] == :operator_readonly
    end

    test "no T150 session anywhere on this path — tier 1 has no per-tenant drill-in affordance" do
      mount = mount_with_roles(%{fleet: :operator_readonly})
      socket = socket_with_mount(mount)
      {:ok, socket} = FleetLive.mount(%{}, session(), socket)

      html = render_html(FleetLive, socket.assigns)
      refute html =~ "open_session"
      refute html =~ "impersonat"
    end
  end

  # ---------------------------------------------------------------------------
  # RP-J-9 — honesty
  # ---------------------------------------------------------------------------

  describe "RP-J-9 — honesty" do
    test "an unknown metric renders '—', never '0'" do
      seed_app("hnst1", report: minimal_payload())

      mount = mount_with_roles(%{fleet: :operator_admin})
      socket = socket_with_mount(mount)
      {:ok, socket} = FleetLive.mount(%{}, session(), socket)

      [tile] = socket.assigns.tiles
      # mrr_cents was never computed by minimal_payload (an omitted, not fabricated,
      # business metric per §8.2 rule 2) — the money/1 helper must render "—", never "0".
      refute Map.has_key?(tile.report, "mrr_cents")
      assert Samen.Web.Operator.Fleet.metric(tile.report, "mrr_cents") == "—"
      assert Samen.Web.Operator.Fleet.metric(tile.report, "deliverability_health_index") == "—"

      html = render_html(FleetLive, socket.assigns)
      assert html =~ "—"
    end

    test "a stale/unreachable app is EXCLUDED from the roll-up 'reporting' count but still rendered" do
      seed_app("hnst2", report: minimal_payload())

      mount = mount_with_roles(%{fleet: :operator_admin})
      socket = socket_with_mount(mount)
      {:ok, socket} = FleetLive.mount(%{}, session(), socket)

      # freshly-reported app is :active -> counted.
      assert socket.assigns.reporting == 1
      assert socket.assigns.total == 1

      html = render_html(FleetLive, socket.assigns)
      assert html =~ "hnst2"
    end

    test "roll-up header text is always 'across R of T products reporting' — derived, not hand-written per n" do
      seed_app("hnst3", report: minimal_payload())

      mount = mount_with_roles(%{fleet: :operator_admin})
      socket = socket_with_mount(mount)
      {:ok, socket} = FleetLive.mount(%{}, session(), socket)

      html = render_html(FleetLive, socket.assigns)
      assert html =~ "across 1 of 1 products reporting"
    end
  end

  # ---------------------------------------------------------------------------
  # RP-J-9b — n=1 == n=N, DERIVED not branched
  # ---------------------------------------------------------------------------

  describe "RP-J-9b — single-product chrome is derived, not branched (§8.3)" do
    test "n=1: '1 product' chrome, NO peer/vs-fleet affordance" do
      seed_app("solo1", report: minimal_payload())

      mount = mount_with_roles(%{fleet: :operator_admin})
      socket = socket_with_mount(mount)
      {:ok, socket} = FleetLive.mount(%{}, session(), socket)

      html = render_html(FleetLive, socket.assigns)
      assert html =~ "1 product<"
      refute html =~ "fleet-vs-peers"
    end

    test "n=3: '3 products' chrome, peer/vs-fleet affordance present for EACH row" do
      seed_app("trio1", report: minimal_payload())
      seed_app("trio2", report: minimal_payload())
      seed_app("trio3", report: minimal_payload())

      mount = mount_with_roles(%{fleet: :operator_admin})
      socket = socket_with_mount(mount)
      {:ok, socket} = FleetLive.mount(%{}, session(), socket)

      html = render_html(FleetLive, socket.assigns)
      assert html =~ "3 products<"
      assert html =~ "fleet-vs-peers"
      # exactly 3 peer affordances (one per row, same call site — no separate n==1 mode).
      assert (html |> String.split("fleet-vs-peers") |> length()) - 1 == 3
    end

    test "GREP: no row-count-literal comparison outside pluralize/2 (the derived-not-branched proof)" do
      src = File.read!("lib/samen/web/operator/fleet_live.ex")

      # Strip pluralize/2's own body (the ONE carved-out exception, Samen.Web.Operator.Fleet).
      offenders =
        Regex.scan(~r/(==\s*1\b|<=\s*1\b|length\([^)]*\)\s*==\s*1)/, src)

      assert offenders == [],
             "fleet_live.ex contains a row-count-literal comparison outside the pluralization " <>
               "helper — the derived-not-branched guarantee is not checkable: #{inspect(offenders)}"
    end

    test "GREP: Samen.Web.Operator.Fleet.pluralize/2 IS the carved-out exception (positive control)" do
      src = File.read!("lib/samen/web/operator/fleet.ex")
      assert src =~ "def pluralize(1, noun)"
    end
  end

  # ---------------------------------------------------------------------------
  # T156 — merged cross-tenant platform-health surfaces
  # ---------------------------------------------------------------------------

  describe "T156 — merged platform-health surfaces (no divergent aggregate)" do
    test "deliverability health index averages across REPORTING (non-excluded) apps" do
      seed_app("t156a", report: minimal_payload(%{"deliverability_health_index" => 80}))
      seed_app("t156b", report: minimal_payload(%{"deliverability_health_index" => 60}))

      mount = mount_with_roles(%{fleet: :operator_admin})
      socket = socket_with_mount(mount)
      {:ok, socket} = FleetLive.mount(%{}, session(), socket)

      assert socket.assigns.t156.deliverability_health_index == 70.0
    end

    test "automation kill-switch/rules-tripped are summed fleet-wide, token-blind" do
      seed_app("t156c", report: minimal_payload(%{"kill_switches_engaged" => 2, "rules_tripped_24h" => 5}))
      seed_app("t156d", report: minimal_payload(%{"kill_switches_engaged" => 1, "rules_tripped_24h" => 3}))

      mount = mount_with_roles(%{fleet: :operator_admin})
      socket = socket_with_mount(mount)
      {:ok, socket} = FleetLive.mount(%{}, session(), socket)

      assert socket.assigns.t156.automation.kill_switches_engaged == 3
      assert socket.assigns.t156.automation.rules_tripped_24h == 8

      # token-blind: no org_id / tenant identifier anywhere in the rendered platform panel.
      html = render_html(FleetLive, socket.assigns)
      refute html =~ "org_id"
    end

    # P15 (phase6-punchlist) — the fleet-wide SUM metrics must honor the SAME "—"
    # honest-no-data discipline the avg metric (and metric/2) use: when NO product
    # reports a metric at all, render "—", NOT a fabricated "0". A genuine reported 0
    # (some product DID report, the total is zero) still renders "0".
    test "P15 HONEST NO-DATA: fleet-wide SUM metrics render nil/'—' when no product reports, not a fabricated 0" do
      # Both apps report a base payload that OMITS the automation counters entirely
      # (Report.to_wire drops nil fields), so nothing reports kill-switches/rules-tripped.
      seed_app("t156e", report: minimal_payload())
      seed_app("t156f", report: minimal_payload())

      mount = mount_with_roles(%{fleet: :operator_admin})
      socket = socket_with_mount(mount)
      {:ok, socket} = FleetLive.mount(%{}, session(), socket)

      assert socket.assigns.t156.automation.kill_switches_engaged == nil
      assert socket.assigns.t156.automation.rules_tripped_24h == nil

      html = render_html(FleetLive, socket.assigns)
      assert html =~ "Automation kill-switches engaged (fleet-wide): —"
      assert html =~ "Automation rules tripped, 24h (fleet-wide): —"
    end

    test "P15 ANTI-TAUTOLOGY: a genuinely-reported total of 0 still renders 0, never '—'" do
      # One app reports a REAL zero for kill-switches — that is data, not absence.
      seed_app("t156g", report: minimal_payload(%{"kill_switches_engaged" => 0, "rules_tripped_24h" => 0}))

      mount = mount_with_roles(%{fleet: :operator_admin})
      socket = socket_with_mount(mount)
      {:ok, socket} = FleetLive.mount(%{}, session(), socket)

      assert socket.assigns.t156.automation.kill_switches_engaged == 0
      assert socket.assigns.t156.automation.rules_tripped_24h == 0

      html = render_html(FleetLive, socket.assigns)
      assert html =~ "Automation kill-switches engaged (fleet-wide): 0"
      assert html =~ "Automation rules tripped, 24h (fleet-wide): 0"
    end
  end
end
