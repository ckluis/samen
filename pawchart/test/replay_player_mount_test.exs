defmodule PawChart.ReplayPlayerMountTest do
  @moduledoc """
  ADR-052 P3 — the session-replay PLAYER is inherited at 0 authored lines: the operator list +
  player ride the host's ONE `samen_operator_routes/2` call (behind the T146
  `:require_operator` on_mount; each open gated on an impersonation session by
  `Samen.Web.Replay.Access`), and the tenant list + player ride its ONE
  `samen_settings_routes/3` call (behind `Samen.Web.TenantAuthz`; org admins only).
  No PawChart module implements any of it.
  """
  use ExUnit.Case, async: true

  @routes [
    {"/operator/replays/:org_id", Samen.Web.Replay.IndexLive, {Samen.Web.Operator.Authz, :require_operator}},
    {"/operator/replays/:org_id/:id", Samen.Web.Replay.PlayerLive, {Samen.Web.Operator.Authz, :require_operator}},
    {"/settings/replays", Samen.Web.Replay.IndexLive, {Samen.Web.TenantAuthz, :require_tenant}},
    {"/settings/replays/:id", Samen.Web.Replay.PlayerLive, {Samen.Web.TenantAuthz, :require_tenant}}
  ]

  test "the replay routes are declared by the framework macros, behind their plane's gate" do
    routes = Phoenix.Router.routes(PawChartWeb.Router)

    for {path, live_view, gate} <- @routes do
      route = Enum.find(routes, &(&1.path == path))
      assert route, "expected #{path} to be inherited from the framework route macros"

      {mounted, _action, _opts, live_session} = route.metadata.phoenix_live_view
      assert mounted == live_view

      hooks =
        Enum.map(live_session.extra[:on_mount] || [], fn
          %{id: id} -> id
          other -> other
        end)

      assert gate in hooks, "#{path} must carry #{inspect(gate)}"
    end
  end

  test "no PawChart-authored replay module exists" do
    {:ok, mods} = :application.get_key(:pawchart, :modules)
    refute Enum.any?(mods, &(Atom.to_string(&1) =~ "Replay"))
  end
end
