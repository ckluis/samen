defmodule Samen.Web.Auth.SessionSockets do
  @moduledoc """
  Tie a LiveView socket to the `Identity.Session` that opened it, so revoking the session
  disconnects the socket (ARCH-13).

  A revoked session row is refused on the NEXT request, but a LiveView that is already
  connected keeps its process, its assigns and its PubSub subscriptions until it
  reconnects — so a signed-out device (or one the user just revoked from Settings ->
  Security, or every device after a password reset) kept receiving live data.

  Phoenix has the mechanism built in: a `"live_socket_id"` in the Plug session makes every
  LiveView mounted from it subscribe to that topic, and `Endpoint.broadcast(topic,
  "disconnect", %{})` tears them down. This module is the framework's one place that

    * derives the topic from the session's token digest (`live_socket_id/1`) — the digest is
      what the row stores, so the SAME value is computable at login (from the raw token, in
      `Samen.Web.Auth.put_session_token/2`) and at revoke time (from the row), with no extra
      lookup and no raw token. It is hashed again with a domain prefix so the topic is not the
      row's lookup key;
    * broadcasts the disconnect (`disconnect/2`) on every revoke path: logout, revoke one,
      revoke others, recovery-code sign-in and password reset.
  """

  @prefix "samen_live_session:"

  @doc "The PubSub/LiveView socket topic for a session, from its token digest."
  @spec live_socket_id(String.t()) :: String.t()
  def live_socket_id(token_digest) when is_binary(token_digest) do
    @prefix <> (:crypto.hash(:sha256, "live_socket:" <> token_digest) |> Base.url_encode64(padding: false))
  end

  @doc "The topic for a RAW session token (what the session cookie carries)."
  @spec live_socket_id_for_token(String.t()) :: String.t()
  def live_socket_id_for_token(raw_token) when is_binary(raw_token),
    do: raw_token |> Samen.Auth.TokenMint.digest() |> live_socket_id()

  @doc """
  Disconnect every LiveView socket held open by the sessions with these token digests.
  `target` is the `Plug.Conn` of the request doing the revoking (its endpoint carries the
  PubSub) or an endpoint module. Returns `:ok`; a target with no endpoint is a no-op.
  """
  @spec disconnect(Plug.Conn.t() | module() | nil, [String.t()]) :: :ok
  def disconnect(%Plug.Conn{} = conn, digests), do: disconnect(conn.private[:phoenix_endpoint], digests)
  def disconnect(nil, _digests), do: :ok

  def disconnect(endpoint, digests) when is_atom(endpoint) and is_list(digests) do
    Enum.each(digests, fn digest ->
      endpoint.broadcast(live_socket_id(digest), "disconnect", %{})
    end)
  end

  @doc "Disconnect the sockets of the session carrying this RAW token (logout)."
  @spec disconnect_token(Plug.Conn.t() | module() | nil, String.t() | nil) :: :ok
  def disconnect_token(target, raw_token) when is_binary(raw_token),
    do: disconnect(target, [Samen.Auth.TokenMint.digest(raw_token)])

  def disconnect_token(_target, _), do: :ok
end
