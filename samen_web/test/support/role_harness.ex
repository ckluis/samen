defmodule Samen.WebTest.RoleHarness do
  @moduledoc """
  The shared harness of the tests that drive a tenant page as a REAL signed-in person
  (`tenant_role_*_test.exs`): a registered org, accounts holding real memberships at each role, a real
  `POST /login` through `Samen.WebTest.SecurityEndpoint`, and the socket a REAL route would hand the view
  (the login's session plus the route's mount session, through the real `Samen.Web.TenantAuthz.on_mount`,
  then the view's own `mount/3`).

  Not a hand-built scope: the role a page acts with comes from the membership row, so changing that row
  (`SpineAccounts.suspend!/2`, `SpineAccounts.set_role!/3`) is what a suspension or a demotion looks like.
  """
  import ExUnit.Assertions
  import Phoenix.ConnTest

  alias Samen.WebTest.SecurityHost
  alias Samen.WebTest.SpineAccounts

  @endpoint Samen.WebTest.SecurityEndpoint

  @doc """
  Arm the host and register an org with an owner, an admin, a member and a viewer. Call from `setup`:
  the previous environment is restored on exit. Returns `%{owner:, admin:, member:, viewer:, org_id:}`.
  """
  def setup_accounts do
    prev = Application.get_env(SecurityHost.otp_app(), :auth_required?)
    prev_delivery = Application.get_env(:samen_core, :delivery_env)
    Application.put_env(:samen_core, :delivery_env, :test)
    SecurityHost.arm!()

    ExUnit.Callbacks.on_exit(fn ->
      restore(SecurityHost.otp_app(), :auth_required?, prev)
      restore(:samen_core, :delivery_env, prev_delivery)
    end)

    owner = SpineAccounts.register!()
    admin = SpineAccounts.accept_into!(owner, :admin)
    member = SpineAccounts.accept_into!(owner, :member)
    viewer = SpineAccounts.accept_into!(owner, :viewer)
    %{owner: owner, admin: admin, member: member, viewer: viewer, org_id: owner.org.id}
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, v), do: Application.put_env(app, key, v)

  @doc "Log `account` in through the real `POST /login`. One login per person: the route is rate limited."
  def log_in(account) do
    conn = post(build_conn(), "/login", %{"login" => %{"email" => account.email, "password" => SpineAccounts.password()}})
    assert redirected_to(conn)
    %{conn: recycle(conn), session: Plug.Conn.get_session(conn)}
  end

  @doc "The mounted socket of `view` at the route `path`, for the logged-in person `login` in `org_id`."
  def live_socket(login, view, path, org_id, extra \\ %{}) do
    {_path, mount_session} =
      Samen.WebTest.SecurityRouter
      |> Phoenix.Router.routes()
      |> Enum.filter(&Map.has_key?(&1.metadata, :phoenix_live_view))
      |> Enum.map(fn r ->
        {_v, _a, _o, ls} = r.metadata.phoenix_live_view
        {r.path, get_in(ls, [:extra, :session])}
      end)
      |> Enum.find(fn {p, _} -> p == path end)

    session = Map.merge(login.session, mount_session)
    params = Map.merge(%{"org" => org_id}, extra)
    socket = %Phoenix.LiveView.Socket{} |> Phoenix.Component.assign(:__changed__, %{})
    socket = %{socket | assigns: Map.put(socket.assigns, :flash, %{})}

    {:cont, socket} =
      case Samen.Web.TenantAuthz.on_mount(:require_tenant, params, session, socket) do
        {:cont, _} = ok -> ok
        other -> flunk("tenant gate refused #{path}: #{inspect(elem(other, 0))}")
      end

    {:ok, socket} = view.mount(params, session, socket)
    socket
  end

  @doc "Send `name` to the view's `handle_event/3`; the new socket."
  def event(view, name, params, socket) do
    {:noreply, socket} = view.handle_event(name, params, socket)
    socket
  end

  @doc """
  The OPEN page: the same mount `live_socket/5` does, on a socket carrying a real LiveView lifecycle (so the actor guard
  attaches for real), then `handle_params/3` as the router would call it. Dispatch its events with `live_event/4`.
  """
  def open_socket(login, view, path, org_id, extra \\ %{}) do
    {_path, mount_session} =
      Samen.WebTest.SecurityRouter
      |> Phoenix.Router.routes()
      |> Enum.filter(&Map.has_key?(&1.metadata, :phoenix_live_view))
      |> Enum.map(fn r ->
        {_v, _a, _o, ls} = r.metadata.phoenix_live_view
        {r.path, get_in(ls, [:extra, :session])}
      end)
      |> Enum.find(fn {p, _} -> p == path end)

    session = Map.merge(login.session, mount_session)
    params = Map.merge(%{"org" => org_id}, extra)
    socket = %Phoenix.LiveView.Socket{} |> Phoenix.Component.assign(:__changed__, %{})

    socket = %{
      socket
      | assigns: Map.put(socket.assigns, :flash, %{}),
        private: Map.put(socket.private, :lifecycle, %Phoenix.LiveView.Lifecycle{}),
        view: view,
        router: Samen.WebTest.SecurityRouter
    }

    {:cont, socket} = Samen.Web.TenantAuthz.on_mount(:require_tenant, params, session, socket)
    {:ok, socket} = view.mount(params, session, socket)
    uri = "http://localhost#{String.replace(path, ":id", extra["id"] || ":id")}?org=#{org_id}"
    {:cont, socket} = Phoenix.LiveView.Lifecycle.handle_params(params, uri, socket)
    {:noreply, socket} = view.handle_params(params, uri, socket)
    socket
  end

  @doc """
  An event as the channel delivers it: the lifecycle `:handle_event` hooks first (the actor guard re-resolves who acts),
  the view's `handle_event/3` only if no hook halted. For a socket from `open_socket/5`.
  """
  def live_event(view, name, params, socket) do
    case Phoenix.LiveView.Lifecycle.handle_event(name, params, socket) do
      {:halt, socket} -> socket
      {:halt, _reply, socket} -> socket
      {:cont, socket} -> event(view, name, params, socket)
    end
  end

  @doc """
  A NAVIGATION on an open page (a `live_patch`, back/forward, an `?org=` switch), the way the channel delivers it:
  `Phoenix.LiveView.Lifecycle.handle_params/3` first (the `:handle_params` hooks the page attached for real), then the
  view's own `handle_params/3`. `extra` are the query params (`%{"org" => other_org_id}` switches organisation);
  `org` defaults to the page's current one. The socket must come from `open_socket/5`.
  """
  def navigate(view, socket, extra \\ %{}) do
    params = Map.merge(%{"org" => socket.assigns.org_id}, extra)
    uri = "http://localhost/x?org=#{params["org"]}"
    {:cont, socket} = Phoenix.LiveView.Lifecycle.handle_params(params, uri, socket)
    {:noreply, socket} = view.handle_params(params, uri, socket)
    socket
  end

  @doc "Re-enter `handle_params/3` (a navigation) WITHOUT the lifecycle hooks: for the unit-socket pages (`live_socket/5`)."
  def params(view, socket, extra) do
    {:noreply, socket} =
      view.handle_params(Map.merge(%{"org" => socket.assigns.org_id}, extra), "http://localhost/x", socket)

    socket
  end

  @doc "Make the identity lookup fail on this socket's mount (an outage of the membership read)."
  def break_identity(socket) do
    mount = socket.assigns.samen_mount
    broken = %{mount | labels: Map.put(mount.labels, :identity_namespace, Samen.WebTest.NoSuchIdentity)}
    Phoenix.Component.assign(socket, :samen_mount, broken)
  end
end
