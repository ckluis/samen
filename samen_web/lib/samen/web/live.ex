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
end
