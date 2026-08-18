defmodule Samen.Web.FleetResolveLiveTest do
  @moduledoc """
  Phase-6 EDGE-LOW L2 — `Samen.Web.Operator.FleetResolveLive` (the ADR-044 §5.3
  tier-2 deep-link RESOLVE step, T84b). Documents (with tests) the
  defense-in-depth design the module's own moduledoc already claims:
  resolution grants NOTHING — it is a bare `handle -> org_id` lookup that
  redirects to the canonical `:org_id` route, where the FULL T146+scope+T150
  gate (`Samen.Web.Operator.Impersonation.gate/3`, already proven by
  `deliverability_masking_test.exs` et al. to deny `:out_of_scope` viewers) runs
  fresh, unaffected by resolution having happened.

  No scope-check is added HERE by design (§5.3, RP-J-11): the disposition for
  L2 was "defense-in-depth note or scope-check", and adding a scope-check at
  the resolve step would duplicate — and risk drifting from — the canonical
  drill-in's own gate. Instead this module locks:

    1. an UNKNOWN handle never reaches a drill-in (fail-honest dead end,
       flashed, redirected to `/operator/accounts`);
    2. a KNOWN handle redirects to the canonical `:org_id` route (org_id
       appears in the URL, exactly as designed — §5.3 says resolution alone
       grants nothing, so this is not itself a leak);
    3. `Samen.Fleet.Resolution.resolve_org_id/2` (the underlying seam call) is
       itself fail-CLOSED on every degenerate input, never fabricating an
       org_id.
  """
  use ExUnit.Case, async: false

  alias Samen.Fleet.Handle
  alias Samen.Web.Mount
  alias Samen.Web.Operator.FleetResolveLive

  @otp_app :samen_web_fleet_resolve_test_host
  @app_id "33333333-3333-4333-8333-333333333333"

  setup do
    on_exit(fn -> Application.delete_env(@otp_app, :fleet_handle_resolver) end)
    :ok
  end

  defp socket_for(live_action) do
    mount =
      Mount.new(:operator, Samen.WebTest.Operator, Samen.WebTest.Repo,
        plane: Samen.Web.Plane.tenant(),
        labels: %{otp_app: @otp_app}
      )

    socket =
      %Phoenix.LiveView.Socket{}
      |> Phoenix.Component.assign(:samen_mount, mount)
      |> Phoenix.Component.assign(:live_action, live_action)

    # `:flash` is a LiveView-reserved assign that `Phoenix.Component.assign/3`
    # refuses to set directly outside the mount lifecycle -- a raw synthetic
    # socket (never mounted) has no `:flash` key at all, but `put_flash/3`
    # (the :unknown-handle path) requires one to already exist. Set it via
    # the plain map underneath, exactly as LiveView's own mount bootstrap does.
    %{socket | assigns: Map.put(socket.assigns, :flash, %{})}
  end

  describe "handle_params/3 — an UNKNOWN handle never reaches a drill-in" do
    test "no :fleet_handle_resolver seam wired -> redirects to /operator/accounts with a flash, never to a drill-in" do
      socket = socket_for(:deliverability)

      {:noreply, socket} =
        FleetResolveLive.handle_params(%{"fleet_handle" => String.duplicate("a", 32)}, "/", socket)

      assert socket.redirected == {:redirect, %{to: "/operator/accounts", status: 302}}
      assert socket.assigns.flash["error"] =~ "Unknown fleet handle"
    end

    test "a malformed (not-well-formed) handle -> same honest dead end, never a crash" do
      Application.put_env(@otp_app, :fleet_handle_resolver, {__MODULE__, :always_match, []})
      socket = socket_for(:activity)

      {:noreply, socket} = FleetResolveLive.handle_params(%{"fleet_handle" => "not-32-hex"}, "/", socket)

      assert socket.redirected == {:redirect, %{to: "/operator/accounts", status: 302}}
    end

    test "a resolver that errors on this handle -> same honest dead end, never a fabricated org_id" do
      Application.put_env(@otp_app, :fleet_handle_resolver, {__MODULE__, :never_match, []})
      socket = socket_for(:automation)

      {:noreply, socket} =
        FleetResolveLive.handle_params(%{"fleet_handle" => String.duplicate("b", 32)}, "/", socket)

      assert socket.redirected == {:redirect, %{to: "/operator/accounts", status: 302}}
    end
  end

  describe "handle_params/3 — a KNOWN handle redirects to the canonical drill-in (grants nothing itself)" do
    test "resolves to the correct family path with the org_id from the seam" do
      org_id = "org-resolved-123"
      Application.put_env(@otp_app, :fleet_handle_resolver, {__MODULE__, :always_match, [org_id]})

      {:ok, handle} = Handle.compute(@app_id, org_id, version: 1)
      socket = socket_for(:deliverability)

      {:noreply, socket} = FleetResolveLive.handle_params(%{"fleet_handle" => handle}, "/", socket)

      assert socket.redirected == {:redirect, %{to: "/operator/deliverability/#{org_id}", status: 302}}
    end

    test "the SAME resolve maps each live_action to its own family path (automation / activity)" do
      org_id = "org-resolved-456"
      Application.put_env(@otp_app, :fleet_handle_resolver, {__MODULE__, :always_match, [org_id]})
      {:ok, handle} = Handle.compute(@app_id, org_id, version: 1)

      {:noreply, s1} = FleetResolveLive.handle_params(%{"fleet_handle" => handle}, "/", socket_for(:automation))
      {:noreply, s2} = FleetResolveLive.handle_params(%{"fleet_handle" => handle}, "/", socket_for(:activity))

      assert s1.redirected == {:redirect, %{to: "/operator/automation/#{org_id}", status: 302}}
      assert s2.redirected == {:redirect, %{to: "/operator/activity/#{org_id}", status: 302}}
    end

    # Defense-in-depth (L2 disposition): resolution places a real org_id in the
    # URL, but resolution ALONE grants nothing — the canonical target this
    # redirect lands on re-runs the FULL T146+scope+T150 gate
    # (`Samen.Web.Operator.Impersonation.gate/3`) fresh, and an out-of-scope
    # viewer is denied THERE regardless of how they arrived at the URL. That
    # re-gate is already proven live by `deliverability_masking_test.exs` /
    # `operator_automation_health_test.exs` / `activity_masking_test.exs`
    # (their RED + `:out_of_scope` cases) — this test only pins that THIS
    # module never shortcuts around it: it redirects, it does not itself open
    # a session or set any impersonation/reveal state.
    test "resolving a handle sets NO impersonation/session state — it is a redirect only" do
      org_id = "org-resolved-789"
      Application.put_env(@otp_app, :fleet_handle_resolver, {__MODULE__, :always_match, [org_id]})
      {:ok, handle} = Handle.compute(@app_id, org_id, version: 1)

      {:noreply, socket} =
        FleetResolveLive.handle_params(%{"fleet_handle" => handle}, "/", socket_for(:deliverability))

      refute Map.has_key?(socket.assigns, :impersonation)
      refute Map.has_key?(socket.assigns, :samen_operator_id)
      assert socket.redirected == {:redirect, %{to: "/operator/deliverability/#{org_id}", status: 302}}
    end
  end

  describe "Samen.Fleet.Resolution.resolve_org_id/2 — fail-closed at the seam itself" do
    test "no seam configured -> :error, never a fabricated org_id" do
      assert Samen.Fleet.Resolution.resolve_org_id(@otp_app, String.duplicate("c", 32)) == :error
    end

    test "an erroring seam -> :error, never a crash" do
      Application.put_env(@otp_app, :fleet_handle_resolver, {__MODULE__, :never_match, []})
      assert Samen.Fleet.Resolution.resolve_org_id(@otp_app, String.duplicate("d", 32)) == :error
    end

    test "a non-string return from the seam -> :error, never admitted" do
      Application.put_env(@otp_app, :fleet_handle_resolver, {__MODULE__, :bad_return, []})
      assert Samen.Fleet.Resolution.resolve_org_id(@otp_app, String.duplicate("e", 32)) == :error
    end
  end

  # -- fixture handle resolvers -------------------------------------------------

  def always_match(org_id, _handle), do: {:ok, org_id}
  def never_match(_handle), do: :error
  def bad_return(_handle), do: {:ok, %{not: "a string"}}
end
