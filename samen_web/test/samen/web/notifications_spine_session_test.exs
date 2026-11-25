defmodule Samen.Web.NotificationsSpineSessionTest do
  @moduledoc """
  B2 - the notifications inbox and the preferences panel for a REAL framework-spine login.

  Production login is `POST /login` -> `Samen.Web.Auth.SessionController`, which writes ONLY
  `samen_session_token`. The inbox used to resolve "which user am I" from `samen_current_user`
  (a key no production login writes), so a signed-in user acted as the org broker and saw only
  org-addressed rows: every user-addressed notice (security notices, automation notify,
  reminders, escalations, chat mentions) was hidden, and the preferences panel said "no
  recipient wired". Every other test injected `:user_id` by hand.

  Here nothing is injected: the test logs in through the real route, then renders the real
  `/notifications` (dead render, through the real router + `TenantAuthz` + endpoint) and drives
  the LiveView callbacks with the session the login produced.

  Every refusal is paired with a positive control (the recipient DOES see the row).
  """
  use Samen.WebTest.DataCase, async: false

  import Phoenix.ConnTest

  require Ash.Query

  alias Samen.Auth.OrgActor
  alias Samen.Identity.Invite
  alias Samen.Identity.Register
  alias Samen.Notifications.Engine
  alias Samen.Web.Mount
  alias Samen.Web.Notifications.InboxLive
  alias Samen.Web.Notifications.PreferencesLive
  alias Samen.WebTest.Operator, as: Op
  alias Samen.WebTest.Primitives.Notification
  alias Samen.WebTest.Primitives.NotificationPreference
  alias Samen.WebTest.SecurityHost

  @endpoint Samen.WebTest.SecurityEndpoint
  @password "correct horse battery staple"

  setup do
    prev = Application.get_env(SecurityHost.otp_app(), :auth_required?)
    prev_delivery = Application.get_env(:samen_core, :delivery_env)
    Application.put_env(:samen_core, :delivery_env, :test)
    SecurityHost.arm!()

    on_exit(fn ->
      case prev do
        nil -> Application.delete_env(SecurityHost.otp_app(), :auth_required?)
        v -> Application.put_env(SecurityHost.otp_app(), :auth_required?, v)
      end

      case prev_delivery do
        nil -> Application.delete_env(:samen_core, :delivery_env)
        v -> Application.put_env(:samen_core, :delivery_env, v)
      end
    end)

    owner = register!()
    member = accept_into!(owner, :member)
    viewer = accept_into!(owner, :viewer)

    %{owner: owner, member: member, viewer: viewer, org_id: owner.org.id}
  end

  # -- harness ---------------------------------------------------------------------

  defp register_mods,
    do: %{org: Op.Org, credential: Op.Credential, user: Op.User, membership: Op.Membership, auth_token: Op.AuthToken, repo: Samen.WebTest.Repo}

  defp invite_mods,
    do: %{invitation: Op.Invitation, credential: Op.Credential, user: Op.User, membership: Op.Membership, repo: Samen.WebTest.Repo}

  defp identity_mods, do: %{user: Op.User, membership: Op.Membership}

  defp register! do
    attrs = %{
      org_name: "Inbox Co #{System.unique_integer([:positive])}",
      first_name: "Ada",
      last_name: "Lovelace",
      email: "inbox-#{System.unique_integer([:positive])}@example.test",
      password: @password
    }

    {:ok, result} = Register.register(attrs, register_mods())
    Map.put(result, :email, attrs.email)
  end

  # Land a fresh account into `host`'s org at `role` through the sanctioned invite/accept path.
  defp accept_into!(host, role) do
    invitee = register!()

    owner_scope = %Samen.Scope{
      actor: %{id: host.user.id, org_id: host.org.id, role: :owner, verified?: true, kind: :tenant, plane: :tenant}
    }

    {:ok, _invitation, raw_token} = Invite.create(invite_mods(), owner_scope, %{email: invitee.email, role: role})
    {:ok, _joined} = Invite.accept(invite_mods(), raw_token)
    invitee
  end

  # The REAL login: POST /login through the router + SessionController. Returns the conn that
  # carries the signed session cookie, recycled for the next request.
  defp log_in(account) do
    conn =
      post(build_conn(), "/login", %{"login" => %{"email" => account.email, "password" => @password}})

    assert redirected_to(conn)
    refute redirected_to(conn) =~ "error"
    %{conn: recycle(conn), session: Plug.Conn.get_session(conn)}
  end

  # The per-org `Identity.User` id the credential holds in `org_id` (the id notifications address).
  defp user_id(account, org_id) do
    {:ok, %{user_id: id}} = OrgActor.resolve(identity_mods(), account.credential.id, org_id)
    id
  end

  defp engine_opts,
    do: [notification_module: Notification, preference_module: NotificationPreference, repo: Samen.WebTest.Repo]

  defp notify!(org_id, recipient_id, body) do
    {:ok, n} =
      Engine.notify(
        %{org_id: org_id, recipient_id: recipient_id, event_type: "invoice.created", channel: :in_app, rendered_body: body},
        engine_opts()
      )

    n
  end

  defp raw(id), do: Ash.get!(Notification, id, authorize?: false)

  defp inbox_html(conn, org_id), do: conn |> get("/notifications?org=#{org_id}") |> html_response(200)

  # The LiveView session the real login produced + the compiled route's mount: what a connected
  # mount receives. `TenantAuthz.on_mount/4` (the real hook) pins the principal first.
  defp live_socket(%{session: login_session}, view, path, org_id) do
    {_path, mount_session} =
      router_mounts()
      |> Enum.find(fn {p, _} -> p == path end)

    session = Map.merge(login_session, mount_session)
    params = %{"org" => org_id}

    socket = %Phoenix.LiveView.Socket{} |> Phoenix.Component.assign(:__changed__, %{})
    {:cont, socket} = Samen.Web.TenantAuthz.on_mount(:require_tenant, params, session, socket)
    {:ok, socket} = view.mount(params, session, socket)
    socket
  end

  defp router_mounts do
    Samen.WebTest.SecurityRouter
    |> Phoenix.Router.routes()
    |> Enum.filter(&Map.has_key?(&1.metadata, :phoenix_live_view))
    |> Enum.map(fn route ->
      {_view, _action, _opts, live_session} = route.metadata.phoenix_live_view
      {route.path, get_in(live_session, [:extra, :session])}
    end)
  end

  # -- the inbox, through the real login ---------------------------------------------

  test "a spine-authenticated user sees THEIR user-addressed notification; another member does not", ctx do
    member_user = user_id(ctx.member, ctx.org_id)
    owner_user = user_id(ctx.owner, ctx.org_id)

    notify!(ctx.org_id, member_user, "FOR-THE-MEMBER-SENTINEL")
    notify!(ctx.org_id, owner_user, "FOR-THE-OWNER-SENTINEL")

    member_html = inbox_html(log_in(ctx.member).conn, ctx.org_id)
    # positive control: the recipient sees theirs
    assert member_html =~ "FOR-THE-MEMBER-SENTINEL"
    refute member_html =~ "FOR-THE-OWNER-SENTINEL"

    owner_html = inbox_html(log_in(ctx.owner).conn, ctx.org_id)
    assert owner_html =~ "FOR-THE-OWNER-SENTINEL"
    refute owner_html =~ "FOR-THE-MEMBER-SENTINEL"
  end

  test "the org-addressed row reaches a member, not a viewer (the resolved role, not a hard-coded :member)", ctx do
    notify!(ctx.org_id, ctx.org_id, "ORG-WIDE-SENTINEL")
    notify!(ctx.org_id, user_id(ctx.viewer, ctx.org_id), "VIEWERS-OWN-SENTINEL")

    assert inbox_html(log_in(ctx.member).conn, ctx.org_id) =~ "ORG-WIDE-SENTINEL"

    viewer_html = inbox_html(log_in(ctx.viewer).conn, ctx.org_id)
    assert viewer_html =~ "VIEWERS-OWN-SENTINEL"
    refute viewer_html =~ "ORG-WIDE-SENTINEL"

    socket = live_socket(log_in(ctx.viewer), InboxLive, "/notifications", ctx.org_id)
    assert socket.assigns.user_role == :viewer
  end

  test "mark_read through the real session marks the user's own notification and no one else's", ctx do
    member_user = user_id(ctx.member, ctx.org_id)
    mine = notify!(ctx.org_id, member_user, "MINE")
    theirs = notify!(ctx.org_id, user_id(ctx.owner, ctx.org_id), "THEIRS")

    socket = live_socket(log_in(ctx.member), InboxLive, "/notifications", ctx.org_id)
    assert socket.assigns.user_id == member_user
    assert socket.assigns.unread_count == 1

    {:noreply, socket} = InboxLive.handle_event("mark_read", %{"id" => theirs.id}, socket)
    assert raw(theirs.id).read_at == nil

    {:noreply, socket} = InboxLive.handle_event("mark_read", %{"id" => mine.id}, socket)
    assert %DateTime{} = raw(mine.id).read_at
    assert socket.assigns.unread_count == 0
  end

  test "a membership that is not ACTIVE gets no access: nothing is read, nothing is written", ctx do
    member_user = user_id(ctx.member, ctx.org_id)
    row = notify!(ctx.org_id, member_user, "SUSPENDED-SENTINEL")

    # positive control: while active, the row is visible
    assert inbox_html(log_in(ctx.member).conn, ctx.org_id) =~ "SUSPENDED-SENTINEL"

    suspend!(member_user, ctx.org_id)

    login = log_in(ctx.member)
    html = inbox_html(login.conn, ctx.org_id)
    refute html =~ "SUSPENDED-SENTINEL"
    # the armed gate no longer authorizes this org for the principal: it falls back to its own org

    socket = live_socket(login, InboxLive, "/notifications", ctx.org_id)
    refute socket.assigns.org_id == ctx.org_id
    {:noreply, _socket} = InboxLive.handle_event("mark_read", %{"id" => row.id}, socket)
    assert raw(row.id).read_at == nil
  end

  test "a failed identity lookup is an ERROR state, not an empty inbox", ctx do
    notify!(ctx.org_id, user_id(ctx.member, ctx.org_id), "OUTAGE-SENTINEL")
    login = log_in(ctx.member)
    # disarmed: the dev `?org=` names the org, so the org resolves and ONLY the user lookup fails
    SecurityHost.disarm!()

    # The same compiled route's mount, with an Identity namespace that cannot be read.
    {_path, mount_session} = Enum.find(router_mounts(), fn {p, _} -> p == "/notifications" end)
    broken = Mount.from_session(mount_session["samen_mount"])
    broken = %{broken | labels: Map.put(broken.labels, :identity_namespace, Samen.WebTest.NoSuchIdentity)}
    session = Map.merge(login.session, %{"samen_mount" => Mount.to_session(broken)})

    socket = Phoenix.Component.assign(%Phoenix.LiveView.Socket{}, :__changed__, %{})
    {:ok, socket} = InboxLive.mount(%{"org" => ctx.org_id}, session, socket)

    assert socket.assigns.recipient_state == :unavailable
    html = render_html(InboxLive, socket.assigns)
    assert html =~ "notifications-unavailable"
    refute html =~ "No notifications yet."
    refute html =~ "OUTAGE-SENTINEL"
  end

  # -- the preferences panel, through the real login -------------------------------------

  test "the preferences panel edits the signed-in user's OWN row (and not another user's)", ctx do
    member_user = user_id(ctx.member, ctx.org_id)
    owner_user = user_id(ctx.owner, ctx.org_id)

    socket = live_socket(log_in(ctx.member), PreferencesLive, "/notifications/settings", ctx.org_id)
    assert socket.assigns.recipient_id == member_user
    refute render_html(PreferencesLive, socket.assigns) =~ "no-recipient"

    {:noreply, _socket} =
      PreferencesLive.handle_event(
        "save",
        %{"_target" => ["prefs", "chat_mention__in_app"], "prefs" => %{"chat_mention__in_app" => "off"}},
        socket
      )

    rows = NotificationPreference |> Ash.Query.filter(event_type == "chat_mention") |> Ash.read!(authorize?: false)
    assert [%{recipient_id: ^member_user, in_app_enabled: false}] = rows
    refute Enum.any?(rows, &(&1.recipient_id == owner_user))
  end

  # -- helpers needing the endpoint -----------------------------------------------------

  defp suspend!(user_id, org_id) do
    [membership] =
      Op.Membership
      |> Ash.Query.filter(user_id == ^user_id and org_id == ^org_id)
      |> Ash.read!(authorize?: false)

    membership
    |> Ash.Changeset.for_update(:update, %{status: "suspended"}, authorize?: false)
    |> Ash.update!()
  end
end
