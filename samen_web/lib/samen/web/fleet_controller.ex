defmodule Samen.Web.FleetController do
  @moduledoc """
  `GET /fleet/health` + `POST /fleet/directive` — the APP-SIDE (reporting-side)
  fleet routes (ADR-044 §4.4a, §9.1 — "`Samen.Web.MetricsController`-shaped: self-
  gating, fail-honest, no plane"). Mounted by `Samen.Web.Router.samen_fleet_routes/1`.
  Delegates to `Samen.Web.Fleet.Ingress` — the `BytesController` seam pattern (route
  wiring here, enforcement in the logic module).
  """
  use Phoenix.Controller, formats: [:json]

  alias Samen.Web.Fleet.Ingress

  def health(conn, _params), do: Ingress.health(conn, fleet_opts(conn))
  def directive(conn, _params), do: Ingress.directive(conn, fleet_opts(conn))

  defp fleet_opts(conn), do: conn.private[:samen_fleet] || []
end
