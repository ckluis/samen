defmodule Samen.Web.Webhook.RawBodyReader do
  @moduledoc """
  The `Plug.Parsers` body reader that CACHES the raw request bytes (ADR-038 §5.1;
  T19/B9). Signature verification requires the exact bytes the provider signed, so the
  raw body must be captured BEFORE `Plug.Parsers` decodes (and discards) it.

  A host wires this into the endpoint's parser for the webhook path:

      plug Plug.Parsers,
        parsers: [:urlencoded, :json],
        body_reader: {Samen.Web.Webhook.RawBodyReader, :read_body, []},
        json_decoder: Jason

  It stashes the raw bytes under `conn.assigns[:raw_webhook_body]` and otherwise
  behaves exactly like `Plug.Conn.read_body/2` — the parser still receives the bytes,
  so JSON params are populated as usual, and the ingress controller reads the untouched
  raw bytes for verification via `raw_body/1`.
  """

  @assign :raw_webhook_body

  @doc "Read the body and cache the raw bytes in `conn.assigns[:raw_webhook_body]`."
  def read_body(conn, opts) do
    {:ok, body, conn} = Plug.Conn.read_body(conn, opts)
    existing = conn.assigns[@assign] || ""
    {:ok, body, Plug.Conn.assign(conn, @assign, existing <> body)}
  end

  @doc """
  The cached raw request body. Falls back to a direct `read_body/1` (returns `""` if the
  parser already consumed it — the fail-closed shape: no bytes ⇒ verification fails).
  """
  @spec raw_body(Plug.Conn.t()) :: binary()
  def raw_body(%Plug.Conn{} = conn) do
    case conn.assigns[@assign] do
      body when is_binary(body) ->
        body

      _ ->
        case Plug.Conn.read_body(conn) do
          {:ok, body, _conn} -> body
          _ -> ""
        end
    end
  end
end
