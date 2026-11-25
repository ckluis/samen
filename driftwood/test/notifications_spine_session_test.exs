defmodule Driftwood.NotificationsSpineSessionTest do
  @moduledoc """
  B2 at the host - the mounted `/notifications` inbox and `/notifications/settings` panel for a REAL
  framework-spine login (`Samen.Web.Auth.SessionController.create/2`, which writes only
  `samen_session_token`). The inbox used to resolve its user from `samen_current_user`, which no
  production login writes, so a signed-in user saw only org-addressed rows and none of the
  user-addressed ones (security notices, automation notify, reminders, escalations).

  Nothing is injected: the test registers a tenant, logs in through the controller, and renders the
  real router + endpoint with the session the login produced.
  """
  use Driftwood.DataCase, async: false

  import Phoenix.ConnTest
  import Plug.Conn, only: [get_session: 2]

  require Ash.Query

  alias Samen.Auth.OrgActor
  alias Samen.Identity.Register
  alias Samen.Notifications.Engine
  alias Samen.Web.Auth
  alias Samen.Web.Auth.SessionController
  alias Samen.Web.Mount
  alias Samen.Web.Notifications.InboxLive
  alias Samen.Web.Notifications.PreferencesLive

  alias Driftwood.Operator.{AuthToken, Credential, Membership, Org, User}

  @endpoint DriftwoodWeb.Endpoint
  @password "correct horse battery staple"

  setup do
    start_supervised!(DriftwoodWeb.Endpoint)

    prev_delivery = Application.get_env(:samen_core, :delivery_env)
    prev_auth = Application.get_env(:driftwood, :auth_required?)
    Application.put_env(:samen_core, :delivery_env, :test)
    Application.put_env(:driftwood, :auth_required?, true)

    on_exit(fn ->
      if prev_delivery,
        do: Application.put_env(:samen_core, :delivery_env, prev_delivery),
        else: Application.delete_env(:samen_core, :delivery_env)

      if prev_auth == nil,
        do: Application.delete_env(:driftwood, :auth_required?),
        else: Application.put_env(:driftwood, :auth_required?, prev_auth)
    end)

    :ok
  end

  defp register_mods,
    do: %{org: Org, credential: Credential, user: User, membership: Membership, auth_token: AuthToken, repo: Driftwood.Repo}

  defp register! do
    attrs = %{
      org_name: "Inbox Freight #{System.unique_integer([:positive])}",
      first_name: "Ada",
      last_name: "Lovelace",
      email: "inbox-#{System.unique_integer([:positive])}@example.test",
      password: @password
    }

    {:ok, result} = Register.register(attrs, register_mods())
    Map.put(result, :email, attrs.email)
  end

  # The real login: `SessionController.create/2` with the mount the router builds for the auth routes.
  defp log_in(account) do
    opts = Plug.Session.init(store: :cookie, key: "_test", signing_salt: "salt", encryption_salt: "esalt")

    conn =
      Plug.Test.conn(:post, "/login")
      |> Map.put(:secret_key_base, String.duplicate("b", 64))
      |> Plug.Session.call(opts)
      |> Plug.Conn.fetch_session()
      |> Plug.Conn.put_private(:samen_mount, Mount.new(:auth, Driftwood.Operator, Driftwood.Repo))
      |> Plug.Conn.put_private(:samen_login_path, "/login")

    conn = SessionController.create(conn, %{"login" => %{"email" => account.email, "password" => @password}})
    token = get_session(conn, Auth.session_token_key())
    assert is_binary(token), "the real login must write the spine session token"

    %{session: %{Auth.session_token_key() => token}}
  end

  defp user_id(account) do
    {:ok, %{user_id: id}} =
      OrgActor.resolve(%{user: User, membership: Membership}, account.credential.id, account.org.id)

    id
  end

  defp notify!(org_id, recipient_id, body) do
    {:ok, n} =
      Engine.notify(%{org_id: org_id, recipient_id: recipient_id, event_type: "invoice.created", channel: :in_app, rendered_body: body})

    n
  end

  defp inbox_html(login, org_id) do
    build_conn() |> Plug.Test.init_test_session(login.session) |> get("/notifications?org=#{org_id}") |> html_response(200)
  end

  # The compiled router's mount for `path`, deserialized exactly as a LiveView mount receives it.
  defp route_session(login, path) do
    route =
      DriftwoodWeb.Router.__routes__()
      |> Enum.filter(&Map.has_key?(&1.metadata, :phoenix_live_view))
      |> Enum.find(&(&1.path == path))

    {_view, _action, _opts, live_session} = route.metadata.phoenix_live_view
    Map.merge(login.session, get_in(live_session, [:extra, :session]))
  end

  defp live_socket(login, view, path, org_id) do
    session = route_session(login, path)
    params = %{"org" => org_id}
    socket = Phoenix.Component.assign(%Phoenix.LiveView.Socket{}, :__changed__, %{})
    {:cont, socket} = Samen.Web.TenantAuthz.on_mount(:require_tenant, params, session, socket)
    {:ok, socket} = view.mount(params, session, socket)
    socket
  end

  test "a spine-authenticated user sees their user-addressed notification (and the org-wide one); another user does not" do
    owner = register!()
    org_id = owner.org.id
    owner_user = user_id(owner)

    notify!(org_id, owner_user, "FOR-THE-OWNER-SENTINEL")
    notify!(org_id, org_id, "ORG-WIDE-SENTINEL")
    notify!(org_id, Ash.UUID.generate(), "FOR-SOMEONE-ELSE-SENTINEL")

    html = inbox_html(log_in(owner), org_id)

    assert html =~ "FOR-THE-OWNER-SENTINEL"
    assert html =~ "ORG-WIDE-SENTINEL"
    refute html =~ "FOR-SOMEONE-ELSE-SENTINEL"
  end

  test "mark_read through the real session marks the user's own notification, and the preferences panel edits the user's own row" do
    owner = register!()
    org_id = owner.org.id
    owner_user = user_id(owner)
    login = log_in(owner)

    mine = notify!(org_id, owner_user, "MINE")
    theirs = notify!(org_id, Ash.UUID.generate(), "THEIRS")

    socket = live_socket(login, InboxLive, "/notifications", org_id)
    assert socket.assigns.user_id == owner_user
    assert socket.assigns.user_role == :owner

    {:noreply, _} = InboxLive.handle_event("mark_read", %{"id" => theirs.id}, socket)
    assert Ash.get!(Driftwood.Primitives.Notification, theirs.id, authorize?: false).read_at == nil

    {:noreply, _} = InboxLive.handle_event("mark_read", %{"id" => mine.id}, socket)
    assert %DateTime{} = Ash.get!(Driftwood.Primitives.Notification, mine.id, authorize?: false).read_at

    prefs = live_socket(login, PreferencesLive, "/notifications/settings", org_id)
    assert prefs.assigns.recipient_id == owner_user

    {:noreply, _} =
      PreferencesLive.handle_event(
        "save",
        %{"_target" => ["prefs", "invoice.paid__in_app"], "prefs" => %{"invoice.paid__in_app" => "off"}},
        prefs
      )

    assert [%{recipient_id: ^owner_user, in_app_enabled: false}] =
             Driftwood.Primitives.NotificationPreference
             |> Ash.Query.filter(event_type == "invoice.paid")
             |> Ash.read!(authorize?: false)
  end
end
