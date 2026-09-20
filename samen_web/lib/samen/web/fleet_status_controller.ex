defmodule Samen.Web.FleetStatusController do
  @moduledoc """
  `GET /status` — the PUBLIC, unauthenticated fleet status page (T166 / ADR-050,
  closing G11). Mounted by `Samen.Web.Router.samen_fleet_status_route/1`.

  The `Samen.Web.FleetController` / `BytesController` seam shape: route wiring
  here, enforcement (rate limit, opt-in filter, masking, fail-closed) in
  `Samen.Web.Fleet.PublicStatus`. Nothing branches in this module, so nothing can
  be gated in it either.
  """
  use Phoenix.Controller, formats: [:html]

  alias Samen.Web.Fleet.PublicStatus

  def index(conn, _params), do: PublicStatus.index(conn, status_opts(conn))

  defp status_opts(conn), do: conn.private[:samen_fleet_status] || []
end
