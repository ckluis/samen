defmodule Samen.Api.Help.Endpoint do
  @moduledoc """
  `GET /api/help` and `GET /api/help/:type`: the plug that serves `Samen.Api.Help` to the caller whose key made the
  request. A host mounts it next to its API endpoint, with its own router and key plug:

      forward("/api/help", Samen.Api.Help.Endpoint, router: MyWeb.Api.Router, key_auth: MyWeb.Api.KeyAuthPlug)

  (in a `Plug.Router`: `forward("/api/help", to: Samen.Api.Help.Endpoint, router: …, key_auth: …)`).

    * The host's key plug runs first and resolves the actor exactly as for the API. Only an actor that carries the
      key (`:api_key`, which the key plug sets) is described: no actor, or an actor that something other than the key
      plug assigned, answers `401` with `WWW-Authenticate: Bearer` and nothing else; a key lookup that could not be
      checked answers the plug's own `503`.
    * The answer is JSON, or the same map as HTML (`Samen.Api.Help.Html`) on `Accept: text/html` or `?format=html`.
    * A type the caller may not use and a type that does not exist answer the SAME `404` body, byte for byte.
    * Every answer, errors included, is `Cache-Control: private, no-store` and `Vary: Authorization, Accept`: a
      description is per caller and is never stored or shared.
    * Only `GET` and `HEAD` are served. Describing reads no tenant row and writes none; the host's key plug does what
      it does for any API request (the demo's stamps the key's `last_used_at`).

  Options: `:router` (the host's `AshJsonApi.Router`) and `:key_auth` (the host's key plug) are required; `:prefix`
  (where the API is mounted, default `"/api/v1"`) and `:help` (where this is mounted, default `"/api/help"`) only
  shape the links.
  """
  @behaviour Plug

  import Plug.Conn

  alias Samen.Api.Help

  @not_found Jason.encode!(%{
               "errors" => [%{"status" => "404", "code" => "not_found", "title" => "Not Found", "detail" => "not_found"}],
               "jsonapi" => %{"version" => "1.0"}
             })

  @unauthorized Jason.encode!(%{
                  "errors" => [
                    %{"status" => "401", "code" => "unauthorized", "title" => "Unauthorized", "detail" => "A valid API key is needed."}
                  ],
                  "jsonapi" => %{"version" => "1.0"}
                })

  @impl true
  def init(opts) do
    %{
      router: Keyword.fetch!(opts, :router),
      key_auth: Keyword.fetch!(opts, :key_auth),
      prefix: Keyword.get(opts, :prefix, "/api/v1"),
      help: Keyword.get(opts, :help, "/api/help")
    }
  end

  @impl true
  def call(conn, %{key_auth: key_auth} = opts) do
    conn = private_headers(conn)

    case conn.method do
      method when method in ["GET", "HEAD"] ->
        conn = key_auth.call(conn, key_auth.init([]))

        cond do
          conn.halted -> conn
          key_actor?(actor = Ash.PlugHelpers.get_actor(conn)) -> serve(conn, actor, opts)
          true -> unauthorized(conn)
        end

      _ ->
        conn |> put_resp_header("allow", "GET, HEAD") |> send_resp(405, "") |> halt()
    end
  end

  # The description is the key's: an actor that does not carry the key map is not a key request, and the key-scope
  # policy would let it through, so it is refused here rather than described.
  defp key_actor?(%{api_key: %{}}), do: true
  defp key_actor?(_actor), do: false

  defp serve(conn, actor, opts) do
    help_opts = [prefix: opts.prefix, help: opts.help]

    case conn.path_info do
      [] -> respond(conn, Help.index(actor, opts.router, help_opts), :index)
      [type] -> detail(conn, actor, opts, type, help_opts)
      _ -> not_found(conn)
    end
  end

  defp detail(conn, actor, opts, type, help_opts) do
    case Help.resource(actor, opts.router, type, help_opts) do
      {:ok, map} -> respond(conn, map, :detail)
      :not_found -> not_found(conn)
    end
  end

  defp respond(conn, map, kind) do
    if html?(conn) do
      conn
      |> put_resp_content_type("text/html")
      |> put_resp_header("content-security-policy", "default-src 'none'; style-src 'unsafe-inline'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'")
      |> send_resp(200, Samen.Api.Help.Html.render(map, kind))
    else
      conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(map))
    end
    |> halt()
  end

  defp not_found(conn), do: conn |> put_resp_content_type("application/json") |> send_resp(404, @not_found) |> halt()

  defp unauthorized(conn) do
    conn
    |> put_resp_header("www-authenticate", "Bearer")
    |> put_resp_content_type("application/json")
    |> send_resp(401, @unauthorized)
    |> halt()
  end

  defp private_headers(conn) do
    conn
    |> put_resp_header("cache-control", "private, no-store")
    |> put_resp_header("vary", "Authorization, Accept")
    |> put_resp_header("x-content-type-options", "nosniff")
  end

  defp html?(conn) do
    conn = fetch_query_params(conn)

    case conn.query_params do
      %{"format" => "html"} -> true
      %{"format" => _other} -> false
      _ -> conn |> get_req_header("accept") |> Enum.any?(&String.contains?(&1, "text/html"))
    end
  end
end
