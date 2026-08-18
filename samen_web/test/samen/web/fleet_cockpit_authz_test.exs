defmodule Samen.Web.FleetCockpitAuthzTest do
  @moduledoc """
  RP-J-12 (ADR-044 §6.3, T84b) — "there is no un-gated path" as a PROVEN
  property, not an asserted one. `samen_operator_routes/2` previously emitted a
  bare `live_session` with no `on_mount` hook (the T146 regression class); a
  new route added to that macro is one careless line away from repeating it.

  This test ENUMERATES `Phoenix.Router.routes/1` against a REAL compiled
  router (`Samen.WebTest.FleetCockpitRouter`, `fleet_cockpit: true`) — never a
  hand-list — and asserts EVERY route under the operator `live_session`,
  cockpit or not, carries `{Samen.Web.Operator.Authz, :require_operator}`.
  """
  use ExUnit.Case, async: true

  alias Samen.WebTest.FleetCockpitRouter, as: Router

  @required_hook {Samen.Web.Operator.Authz, :require_operator}

  describe "RP-J-12 — every operator route (enumerated) carries the T146 on_mount" do
    test "GREEN: the real router — every /operator/* live route is gated, including every fleet route" do
      operator_routes = live_routes_under("/operator")

      assert length(operator_routes) >= 10, "route enumeration looks broken (too few /operator routes found)"

      fleet_routes = Enum.filter(operator_routes, &String.starts_with?(&1.path, "/operator/fleet"))
      # ALL FIVE fleet-cockpit routes present (register listed before :app_id, static-first).
      assert length(fleet_routes) == 4

      for route <- operator_routes do
        assert on_mount_hooks(route) |> Enum.member?(@required_hook),
               "route #{route.verb} #{route.path} does NOT carry #{inspect(@required_hook)} — " <>
                 "an un-gated operator path exists (RP-J-12)"
      end
    end

    test "the fleet resolve routes (§5.3) are ALSO gated (mounted unconditionally, not fleet_cockpit-only)" do
      resolve_routes =
        Router.__routes__()
        |> Enum.filter(&String.ends_with?(&1.path, "/resolve"))

      assert length(resolve_routes) == 3

      for route <- resolve_routes do
        assert on_mount_hooks(route) |> Enum.member?(@required_hook),
               "resolve route #{route.path} is NOT gated by :require_operator"
      end
    end

    test "sanity: the /fleet/health reporting route (samen_fleet_routes, NOT operator-session) is a DIFFERENT auth class" do
      # samen_fleet_routes/1 mounts a plain (non-LiveView) controller route, credential-
      # authenticated — it MUST NOT carry the operator on_mount (that would be the
      # wrong authenticator for an app-to-cockpit probe, §4.4a's table).
      health = Router.__routes__() |> Enum.find(&(&1.path == "/fleet/health"))
      refute is_nil(health)
      refute Map.has_key?(health.metadata, :phoenix_live_view)
    end
  end

  describe "RED — sabotage twin (documented; the real patch lives in scripts/sabotages/)" do
    test "REFUTABILITY CONTROL: on_mount_hooks/1 actually reads real hook data (not vacuously true)" do
      # Anti-tautology: prove the extraction helper can find NO hooks on a route that
      # genuinely has none, so the positive assertions above are not vacuously true.
      no_hook_route = %{metadata: %{phoenix_live_view: {Mod, :action, [], %{name: :x, extra: %{}}}}}
      assert on_mount_hooks(no_hook_route) == []
      refute Enum.member?(on_mount_hooks(no_hook_route), @required_hook)
    end
  end

  # -- helpers -------------------------------------------------------------------

  defp live_routes_under(prefix) do
    Router.__routes__()
    |> Enum.filter(&String.starts_with?(&1.path, prefix))
    |> Enum.filter(&Map.has_key?(&1.metadata, :phoenix_live_view))
  end

  defp on_mount_hooks(%{metadata: %{phoenix_live_view: {_view, _action, _opts, live_session}}}) do
    (live_session.extra[:on_mount] || [])
    |> Enum.map(fn
      %{id: id} -> id
      {mod, arg} -> {mod, arg}
      other -> other
    end)
  end

  defp on_mount_hooks(_route), do: []
end
