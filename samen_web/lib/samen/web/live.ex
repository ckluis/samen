defmodule Samen.Web.Live do
  @moduledoc """
  Shared plumbing for the framework LiveViews: reading the `Samen.Web.Mount` out of the
  `live_session` session and assigning it (ADR-009 §3.5).

  The router macro (`Samen.Web.Router.samen_module_routes/3`) threads the mount through
  `live_session session: %{"samen_mount" => Samen.Web.Mount.to_session(mount)}`, so it is
  present on BOTH the initial dead render and the websocket reconnect. Every framework
  LiveView calls `assign_mount/2` first thing in `mount/3` to rebuild the struct once.
  """

  import Phoenix.Component, only: [assign: 3]

  @doc """
  Read the `"samen_mount"` value from the session, rebuild the `Samen.Web.Mount` struct,
  and assign it as `:samen_mount`. A missing/blank session (e.g. an isolated component
  test that mounts without the router) is tolerated by leaving `:samen_mount` unset — but
  the framework routes always populate it.
  """
  def assign_mount(socket, %{"samen_mount" => raw} = session) when is_map(raw) do
    socket
    |> assign(:samen_mount, Samen.Web.Mount.from_session(raw))
    |> assign(:samen_acting_as, Samen.Web.CurrentOrg.acting_as?(session))
  end

  def assign_mount(socket, _session), do: socket

  @doc """
  The client IP for a LiveView surface, for per-IP rate limiting (ADR-038 §6.3; T103).

  Reads `:peer_data` from `get_connect_info/2` — available on the CONNECTED socket when
  the host endpoint declares `connect_info: [:peer_data]` on its live socket (the submit
  that a rate limit guards fires over the connected socket). When it is unavailable
  (disconnected dead render, or a host that did not opt into `:peer_data`), it returns
  `"unknown"`: the per-IP limit then degrades to a single shared bucket — a STRICTER
  (global) bound, never a weaker one, so the brute-force control fails safe.
  """
  def client_ip(socket) do
    case peer_data(socket) do
      %{address: address} when is_tuple(address) -> address |> :inet.ntoa() |> to_string()
      _ -> "unknown"
    end
  end

  # `get_connect_info/2` raises outside the mount lifecycle (e.g. a unit test that calls
  # `mount/3` on a synthetic socket) and returns nil on a disconnected dead render or a
  # host that did not opt into `:peer_data`. Either way we want the safe `"unknown"`
  # fallback (a stricter, global per-IP bucket), never a crash.
  defp peer_data(socket) do
    Phoenix.LiveView.get_connect_info(socket, :peer_data)
  rescue
    _ -> nil
  end
end
