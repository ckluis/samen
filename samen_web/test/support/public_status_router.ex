defmodule Samen.WebTest.PublicStatusRouter do
  @moduledoc """
  T166 / ADR-050 — a REAL, compiled Phoenix router mounting
  `Samen.Web.Router.samen_fleet_status_route/1`, so the mount's PUBLIC posture is
  proven by ENUMERATING `Phoenix.Router.routes/1` rather than by prose (the
  `Samen.WebTest.FleetCockpitRouter` precedent inverted: that router proves no
  fleet path is un-gated, this one proves the status path is deliberately, and
  *only* the status path).

  Deliberately a SEPARATE router from `FleetCockpitRouter`: this is the only
  fleet-substrate surface with no authority gate on it, and keeping it out of the
  cockpit router keeps RP-J-12's enumeration ("no un-gated `/fleet*` path") exact
  rather than carve-out-ridden. The path is `/status`, not under `/fleet`, so
  `mix samen.verify.fleet_wire --router ...`'s `/fleet*` route-surface comparison
  is untouched too.

  No Endpoint: `Phoenix.Router.routes/1` works off the compiled module.
  """
  use Phoenix.Router

  import Samen.Web.Router

  pipeline :browser do
    plug(:accepts, ["html"])
  end

  scope "/" do
    pipe_through(:browser)

    samen_fleet_status_route(namespace: Samen.WebTest.Fleet)
  end
end
