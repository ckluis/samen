defmodule Samen.Web.FleetIngressController do
  @moduledoc """
  `POST /fleet/enroll` + `POST /fleet/heartbeat` — the COCKPIT-SIDE fleet ingest
  routes (ADR-044 §4.4a). Mounted by `Samen.Web.Router.samen_fleet_ingest_routes/1`.
  Delegates to `Samen.Web.Fleet.CockpitIngress`.
  """
  use Phoenix.Controller, formats: [:json]

  alias Samen.Web.Fleet.CockpitIngress

  def enroll(conn, _params), do: CockpitIngress.enroll(conn, fleet_opts(conn))
  def heartbeat(conn, _params), do: CockpitIngress.heartbeat(conn, fleet_opts(conn))

  defp fleet_opts(conn), do: conn.private[:samen_fleet_ingest] || []
end
