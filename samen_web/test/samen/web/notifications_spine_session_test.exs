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

  # -- :denied and :unavailable, reached end to end through actor_in_org ---------------------------

  # Rename a table out from under a resource so every read of it is a REAL database error (the
  # repo's honest-failure idiom, see notifications_sources_test.exs); always renamed back.
  defp with_unreadable(resource, fun) do
    table = AshPostgres.DataLayer.Info.table(resource)
    Samen.WebTest.Repo.query!("ALTER TABLE #{table} RENAME TO #{table}_unreadable")

    try do
      ExUnit.CaptureLog.capture_log(fn -> send(self(), {:result, fun.()}) end)
      assert_received {:result, result}
      result
    after
      Samen.WebTest.Repo.query!("ALTER TABLE #{table}_unreadable RENAME TO #{table}")
    end
  end

  defp reenter(view, socket, org_id) do
    {:noreply, socket} = view.handle_params(%{"org" => org_id}, "http://localhost/notifications?org=#{org_id}", socket)
    socket
  end

  test "a pinned org whose membership is suspended AFTER the mount is :denied on re-entry (?org=): no org-addressed rows, nothing marked", ctx do
    member_user = user_id(ctx.member, ctx.org_id)
    org_row = notify!(ctx.org_id, ctx.org_id, "ORG-ROW-DENIED-SENTINEL")
    own_row = notify!(ctx.org_id, member_user, "OWN-ROW-DENIED-SENTINEL")

    socket = live_socket(log_in(ctx.member), InboxLive, "/notifications", ctx.org_id)

    # positive control: while active, the member reads both rows
    assert socket.assigns.recipient_state == :ok
    assert socket.assigns.org_id == ctx.org_id
    assert render_html(InboxLive, socket.assigns) =~ "ORG-ROW-DENIED-SENTINEL"

    suspend!(member_user, ctx.org_id)
    socket = reenter(InboxLive, socket, ctx.org_id)

    # the pinned authorized set still names the org, so it is `actor_in_org` that refuses
    assert socket.assigns.org_id == ctx.org_id
    assert socket.assigns.recipient_state == :denied
    html = render_html(InboxLive, socket.assigns)
    assert html =~ ~s(id="notifications-denied")
    refute html =~ "ORG-ROW-DENIED-SENTINEL"
    refute html =~ "OWN-ROW-DENIED-SENTINEL"

    # nothing is written and a realtime envelope reads nothing
    {:noreply, socket} = InboxLive.handle_event("mark_all_read", %{}, socket)
    {:noreply, socket} = InboxLive.handle_info({:notification_created, %{id: org_row.id}}, socket)
    assert socket.assigns.unread_count == 0
    assert raw(org_row.id).read_at == nil
    assert raw(own_row.id).read_at == nil
  end

  test "a pinned org whose membership is suspended AFTER the mount is :denied in the preferences panel too", ctx do
    member_user = user_id(ctx.member, ctx.org_id)
    socket = live_socket(log_in(ctx.member), PreferencesLive, "/notifications/settings", ctx.org_id)

    # positive control
    assert socket.assigns.access == :ok
    assert socket.assigns.recipient_id == member_user

    suspend!(member_user, ctx.org_id)
    socket = reenter(PreferencesLive, socket, ctx.org_id)

    assert socket.assigns.org_id == ctx.org_id
    assert socket.assigns.access == :denied
    assert socket.assigns.recipient_id == nil
    html = render_html(PreferencesLive, socket.assigns)
    assert html =~ ~s(id="preferences-denied")
    refute html =~ ~s(id="preferences-grid")

    {:noreply, _} =
      PreferencesLive.handle_event(
        "save",
        %{"_target" => ["prefs", "chat_mention__in_app"], "prefs" => %{"chat_mention__in_app" => "off"}},
        socket
      )

    assert Ash.read!(NotificationPreference, authorize?: false) == []
  end

  test "a FAILED OrgActor lookup (the User read errors) is {:error, :unavailable}: the inbox and the preferences panel show the error state, never an inbox", ctx do
    member_user = user_id(ctx.member, ctx.org_id)
    notify!(ctx.org_id, ctx.org_id, "ORG-ROW-OUTAGE-SENTINEL")
    notify!(ctx.org_id, member_user, "OWN-ROW-OUTAGE-SENTINEL")

    login = log_in(ctx.member)
    inbox = live_socket(login, InboxLive, "/notifications", ctx.org_id)
    prefs = live_socket(login, PreferencesLive, "/notifications/settings", ctx.org_id)
    assert inbox.assigns.recipient_state == :ok
    assert prefs.assigns.access == :ok

    {inbox, prefs} =
      with_unreadable(Op.User, fn ->
        {reenter(InboxLive, inbox, ctx.org_id), reenter(PreferencesLive, prefs, ctx.org_id)}
      end)

    assert inbox.assigns.recipient_state == :unavailable
    inbox_html = render_html(InboxLive, inbox.assigns)
    assert inbox_html =~ ~s(id="notifications-unavailable")
    refute inbox_html =~ "ORG-ROW-OUTAGE-SENTINEL"
    refute inbox_html =~ "OWN-ROW-OUTAGE-SENTINEL"

    assert prefs.assigns.access == :unavailable
    prefs_html = render_html(PreferencesLive, prefs.assigns)
    assert prefs_html =~ "preferences-error"
    refute prefs_html =~ ~s(id="preferences-grid")

    # a realtime envelope on the unavailable inbox reads nothing
    {:noreply, inbox} = InboxLive.handle_info({:notification_created, %{id: Ash.UUID.generate()}}, inbox)
    assert inbox.assigns.unread_count == 0
  end

  # -- a settings screen re-derives its user when ?org= switches to ANOTHER authorized org ------------------

  test "settings screens: a patch to another authorized org acts as THAT org's user, never the mount org's id", ctx do
    own_org = ctx.member.org.id
    refute own_org == ctx.org_id

    host_user = user_id(ctx.member, ctx.org_id)
    own_user = user_id(ctx.member, own_org)
    refute host_user == own_user

    login = log_in(ctx.member)

    for {view, path} <- [
          {Samen.Web.Settings.ProfileLive, "/settings/profile"},
          {Samen.Web.Settings.ApiKeysLive, "/settings/api-keys"},
          {Samen.Web.Settings.InvitationsLive, "/settings/invitations"}
        ] do
      socket = live_socket(login, view, path, ctx.org_id)

      # positive control: mounted on the host org, the screen acts as the host org's user
      assert socket.assigns.org_id == ctx.org_id
      assert socket.assigns.user_id == host_user, "#{inspect(view)} mount"

      socket = reenter(view, socket, own_org)

      assert socket.assigns.org_id == own_org
      assert socket.assigns.user_id == own_user, "#{inspect(view)} kept the mount org's user id on a patch to another org"
      refute socket.assigns.user_id == host_user
    end
  end

  test "settings screens: a patch to an org where the principal's membership is not active shows the honest no-user state", ctx do
    host_user = user_id(ctx.member, ctx.org_id)
    own_org = ctx.member.org.id
    login = log_in(ctx.member)
    socket = live_socket(login, Samen.Web.Settings.ProfileLive, "/settings/profile", own_org)
    assert socket.assigns.user_id == user_id(ctx.member, own_org)

    suspend!(host_user, ctx.org_id)
    # the pinned set still names the host org, but the member holds no ACTIVE membership there any more
    socket = reenter(Samen.Web.Settings.ProfileLive, socket, ctx.org_id)

    assert socket.assigns.org_id == ctx.org_id
    assert socket.assigns.user_id == nil
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

  # -- B1: chat @-mentions reach the mentioned PERSON ---------------------------------------

  defp chat_mount,
    do: Mount.new(:chat, Samen.WebTest.Chat, Samen.WebTest.Repo, labels: %{identity_namespace: Samen.WebTest.Operator})

  defp thread_with_participants!(ctx) do
    mount = chat_mount()
    scope = Mount.scope(mount, ctx.org_id)

    {:ok, thread} = Samen.Web.Chat.create_thread(mount, scope, %{org_id: ctx.org_id, subject: "Mentions", kind: :cross_plane, status: :open})

    add = fn account, handle ->
      {:ok, p} =
        Samen.Web.Chat.add_participant(mount, scope, %{
          org_id: ctx.org_id,
          thread_id: thread.id,
          party: :tenant,
          principal_kind: :user,
          principal_id: user_id(account, ctx.org_id),
          handle: handle,
          role: :member
        })

      p
    end

    %{thread: thread, owner_p: add.(ctx.owner, "the-owner"), member_p: add.(ctx.member, "the-member"), viewer_p: add.(ctx.viewer, "the-viewer")}
  end

  defp mention!(ctx, chat, body) do
    mount = chat_mount()

    Samen.Web.Chat.post_message(
      mount,
      Mount.scope(mount, ctx.org_id),
      %{org_id: ctx.org_id, thread_id: chat.thread.id, participant_id: chat.owner_p.id, sender_party: :tenant, body: body},
      broadcast: false,
      notify: engine_opts()
    )
  end

  test "B1: a chat @-mention is visible in the mentioned member's inbox through a real login, and in no one else's", ctx do
    chat = thread_with_participants!(ctx)
    assert {:ok, _} = mention!(ctx, chat, "ping @the-member please")

    # the stored row is addressed to the member's PER-ORG USER, not the participant row
    member_user = user_id(ctx.member, ctx.org_id)
    assert [%{recipient_id: ^member_user}] = Notification |> Ash.Query.filter(event_type == "chat_mention") |> Ash.read!(authorize?: false)

    # positive control: the mentioned member sees it
    assert inbox_html(log_in(ctx.member).conn, ctx.org_id) =~ "mentioned you in a conversation"
    # nobody else does: not the sender, not another member, not the viewer
    refute inbox_html(log_in(ctx.owner).conn, ctx.org_id) =~ "mentioned you in a conversation"
    refute inbox_html(log_in(ctx.viewer).conn, ctx.org_id) =~ "mentioned you in a conversation"
  end

  test "B1: the mention preference is set by its owner (real session) and gates delivery", ctx do
    chat = thread_with_participants!(ctx)
    member_user = user_id(ctx.member, ctx.org_id)

    socket = live_socket(log_in(ctx.member), PreferencesLive, "/notifications/settings", ctx.org_id)

    {:noreply, _socket} =
      PreferencesLive.handle_event(
        "save",
        %{"_target" => ["prefs", "chat_mention__in_app"], "prefs" => %{"chat_mention__in_app" => "off"}},
        socket
      )

    assert [%{recipient_id: ^member_user, event_type: "chat_mention", in_app_enabled: false}] =
             NotificationPreference |> Ash.Query.filter(event_type == "chat_mention") |> Ash.read!(authorize?: false)

    assert {:ok, _} = mention!(ctx, chat, "ping @the-member again")
    assert Notification |> Ash.Query.filter(event_type == "chat_mention") |> Ash.read!(authorize?: false) == []

    # positive control: another member's mention is still delivered
    assert {:ok, _} = mention!(ctx, chat, "ping @the-viewer too")
    assert [_one] = Notification |> Ash.Query.filter(event_type == "chat_mention") |> Ash.read!(authorize?: false)
  end

  test "B1: a conversation started from the real session maps its initiator to the per-org user", ctx do
    login = log_in(ctx.member)

    mount =
      Mount.new(:chat, Samen.WebTest.Chat, Samen.WebTest.Repo,
        labels: %{
          otp_app: SecurityHost.otp_app(),
          authn: {:app_env, SecurityHost.otp_app(), :auth_required?},
          authorized_orgs: {SecurityHost, :authorized_org_ids, []},
          identity_namespace: Samen.WebTest.Operator
        }
      )

    session = Map.merge(login.session, %{"samen_mount" => Mount.to_session(mount)})
    socket = Phoenix.Component.assign(%Phoenix.LiveView.Socket{}, :__changed__, %{})
    {:cont, socket} = Samen.Web.TenantAuthz.on_mount(:require_tenant, %{"org" => ctx.org_id}, session, socket)
    {:ok, socket} = Samen.Web.Chat.ThreadsLive.mount(%{"org" => ctx.org_id}, session, socket)

    {:noreply, _socket} =
      Samen.Web.Chat.ThreadsLive.handle_event("new_conversation", %{"subject" => "Hello", "handle" => "initiator"}, socket)

    participants = Samen.WebTest.Chat.ChatParticipant |> Ash.read!(authorize?: false)
    member_user = user_id(ctx.member, ctx.org_id)
    assert Enum.any?(participants, &(&1.principal_id == member_user and &1.principal_kind == :user))
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
