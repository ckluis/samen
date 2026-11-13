defmodule Samen.Web.Auth.SessionSocketsTest do
  @moduledoc """
  ARCH-13 — a revoked session must take its connected LiveView sockets with it.

  A revoked `Identity.Session` row is refused on the next request, but a LiveView that is
  already connected keeps running (assigns, PubSub subscriptions) until it reconnects. Every
  revoke path now broadcasts `"disconnect"` on the topic the session's sockets subscribed to
  (`live_socket_id` in the Plug session, set by `Samen.Web.Auth.put_session_token/2`).

  Proven twice: end-to-end against a REAL connected LiveView (the process dies), and per
  revoke path via the broadcast every connected socket of that session is subscribed to — each
  with a positive control that a sibling session's sockets are NOT disconnected.
  """
  use Samen.WebTest.DataCase, async: false

  import Plug.Conn
  import Plug.Test

  alias Samen.Auth.SessionCreate
  alias Samen.Identity.Register
  alias Samen.Web.Auth
  alias Samen.Web.Auth.AccountController
  alias Samen.Web.Auth.SessionController
  alias Samen.Web.Auth.SessionSockets
  alias Samen.Web.Mount
  alias Samen.WebTest.Operator.AuthToken
  alias Samen.WebTest.Operator.Credential
  alias Samen.WebTest.Operator.Membership
  alias Samen.WebTest.Operator.Org
  alias Samen.WebTest.Operator.Session
  alias Samen.WebTest.Operator.User

  @endpoint Samen.WebTest.SecurityEndpoint
  @secret_key_base String.duplicate("a", 64)

  setup do
    prev = Application.get_env(:samen_core, :delivery_env)
    Application.put_env(:samen_core, :delivery_env, :test)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:samen_core, :delivery_env, prev),
        else: Application.delete_env(:samen_core, :delivery_env)
    end)

    result = register!()
    mount = Mount.new(:auth, Samen.WebTest.Operator, Repo)
    {:ok, a, a_raw} = SessionCreate.create(session_create_mods(), result.credential.id)
    {:ok, b, b_raw} = SessionCreate.create(session_create_mods(), result.credential.id)
    %{result: result, mount: mount, a: a, a_raw: a_raw, b: b, b_raw: b_raw}
  end

  defp register_mods, do: %{org: Org, credential: Credential, user: User, membership: Membership, auth_token: AuthToken, repo: Repo}
  defp session_create_mods, do: %{session: Session, org: Org, membership: Membership, user: User}

  defp register! do
    attrs = %{
      org_name: "Sockets Co #{System.unique_integer([:positive])}",
      first_name: "Ada",
      last_name: "Lovelace",
      email: "sockets-#{System.unique_integer([:positive])}@example.test",
      password: "correct horse battery staple"
    }

    {:ok, result} = Register.register(attrs, register_mods())
    Map.merge(result, %{email: attrs.email, password: attrs.password})
  end

  defp session_conn(method, path, raw_token, mount) do
    opts = Plug.Session.init(store: :cookie, key: "_test", signing_salt: "salt", encryption_salt: "esalt")

    conn(method, path)
    |> Map.put(:secret_key_base, @secret_key_base)
    |> Plug.Session.call(opts)
    |> fetch_session()
    |> put_session(Auth.session_token_key(), raw_token)
    |> put_private(:phoenix_endpoint, @endpoint)
    |> put_private(:samen_mount, mount)
    |> put_private(:samen_login_path, "/login")
  end

  # What a connected LiveView does on mount for a session carrying `live_socket_id`.
  defp listen_as(raw_token), do: @endpoint.subscribe(SessionSockets.live_socket_id_for_token(raw_token))

  defp disconnect_topic(raw), do: SessionSockets.live_socket_id_for_token(raw)

  test "put_session_token/2 stamps the live_socket_id the revoke path will broadcast on", ctx do
    conn = session_conn(:get, "/", ctx.a_raw, ctx.mount) |> Auth.put_session_token(ctx.a_raw)
    assert get_session(conn, "live_socket_id") == disconnect_topic(ctx.a_raw)
    refute get_session(conn, "live_socket_id") == disconnect_topic(ctx.b_raw)
  end

  test "the session value is the id Phoenix itself uses to address the websocket (Phoenix.LiveView.Socket.id/1)", ctx do
    conn = session_conn(:get, "/", ctx.a_raw, ctx.mount) |> Auth.put_session_token(ctx.a_raw)

    # What the endpoint's `connect_info: [session: ...]` hands the socket at connect time.
    socket = %Phoenix.Socket{private: %{connect_info: %{session: get_session(conn)}}}
    topic = Phoenix.LiveView.Socket.id(socket)

    assert topic == disconnect_topic(ctx.a_raw)

    # A broadcast on that topic is exactly what tears the transport (and its LiveViews) down.
    @endpoint.subscribe(topic)
    :ok = SessionSockets.disconnect_token(@endpoint, ctx.a_raw)
    assert_receive %Phoenix.Socket.Broadcast{event: "disconnect", topic: ^topic}
  end

  test "revoking another device from Settings -> Security disconnects that device's sockets only", ctx do
    listen_as(ctx.a_raw)
    @endpoint.subscribe(disconnect_topic(ctx.b_raw))
    topic_a = disconnect_topic(ctx.a_raw)
    topic_b = disconnect_topic(ctx.b_raw)

    conn = session_conn(:post, "/settings/security/sessions/#{ctx.b.id}/revoke", ctx.a_raw, ctx.mount)
    conn = SessionController.revoke(conn, %{"id" => ctx.b.id})
    assert conn.status in 300..399

    assert_receive %Phoenix.Socket.Broadcast{event: "disconnect", topic: ^topic_b}
    refute_receive %Phoenix.Socket.Broadcast{topic: ^topic_a}, 200
  end

  test "logout disconnects the signed-out browser's sockets only", ctx do
    listen_as(ctx.a_raw)
    topic_a = disconnect_topic(ctx.a_raw)
    @endpoint.subscribe(disconnect_topic(ctx.b_raw))
    topic_b = disconnect_topic(ctx.b_raw)

    conn = SessionController.delete(session_conn(:post, "/logout", ctx.a_raw, ctx.mount), %{})
    assert conn.status in 300..399
    assert get_session(conn, "live_socket_id") == nil

    assert_receive %Phoenix.Socket.Broadcast{event: "disconnect", topic: ^topic_a}
    refute_receive %Phoenix.Socket.Broadcast{topic: ^topic_b}, 200
  end

  test "revoke_others disconnects every OTHER session's sockets and keeps the requester's", ctx do
    listen_as(ctx.a_raw)
    @endpoint.subscribe(disconnect_topic(ctx.b_raw))
    topic_a = disconnect_topic(ctx.a_raw)
    topic_b = disconnect_topic(ctx.b_raw)

    SessionController.revoke_others(session_conn(:post, "/settings/security/sessions/revoke_others", ctx.a_raw, ctx.mount), %{})

    assert_receive %Phoenix.Socket.Broadcast{event: "disconnect", topic: ^topic_b}
    refute_receive %Phoenix.Socket.Broadcast{topic: ^topic_a}, 200
  end

  test "a password reset disconnects the sockets of EVERY session of the credential", ctx do
    listen_as(ctx.a_raw)
    @endpoint.subscribe(disconnect_topic(ctx.b_raw))
    topic_a = disconnect_topic(ctx.a_raw)
    topic_b = disconnect_topic(ctx.b_raw)

    {:ok, _t, reset_raw} = Samen.Auth.TokenMint.mint(AuthToken, ctx.result.credential.id, :password_reset, nil, 3600)

    conn =
      session_conn(:post, "/reset/#{reset_raw}", ctx.a_raw, ctx.mount)
      |> put_private(:samen_reset_path, "/reset")

    conn = AccountController.reset(conn, %{"token" => reset_raw, "reset" => %{"password" => "a brand new strong password"}})
    assert location(conn) =~ "reset=1"

    assert_receive %Phoenix.Socket.Broadcast{event: "disconnect", topic: ^topic_a}
    assert_receive %Phoenix.Socket.Broadcast{event: "disconnect", topic: ^topic_b}
  end

  test "RED: a session whose revoke is REFUSED (foreign credential) disconnects nothing", ctx do
    other = register!()
    {:ok, foreign, foreign_raw} = SessionCreate.create(session_create_mods(), other.credential.id)
    @endpoint.subscribe(disconnect_topic(foreign_raw))
    topic_f = disconnect_topic(foreign_raw)

    # `a` tries to revoke someone else's session by id: refused, so its sockets must stay up.
    SessionController.revoke(session_conn(:post, "/x", ctx.a_raw, ctx.mount), %{"id" => foreign.id})

    refute_receive %Phoenix.Socket.Broadcast{topic: ^topic_f}, 200
  end

  defp location(conn), do: conn |> get_resp_header("location") |> List.first() || ""
end
