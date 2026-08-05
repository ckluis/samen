defmodule Samen.Web.AI.McpPlug do
  @moduledoc """
  The D4 MCP server's HTTP transport (ADR-043 §9; T69) — a **Streamable-HTTP + SSE** endpoint
  mounted in `samen_web`, the thin wire in front of the `samen_core` tool engine
  `Samen.AI.Mcp`. `AshAi.Mcp` is the protocol reference (version 2025-03-26, the router shape,
  the api-key plug seam), not a dependency.

  A vertical mounts it in ONE line (`Samen.Web.Router.samen_mcp_route/1`; INV-5):

      import Samen.Web.Router

      samen_mcp_route(
        actor_resolver: {MyWeb.Api.KeyAuthPlug, :resolve_scope, []},
        tool_opts: [domains: [MyApp.Crm], repo: MyApp.Repo,
                    approval_resource: MyApp.Primitives.Approval,
                    kinds: MyApp.approval_kinds()]
      )

  ## Auth — per-operator API tokens (the demo `KeyAuthPlug` precedent, §9)

  Every request MUST carry `Authorization: Bearer <token>`. The `:actor_resolver` seam
  (a 1-arity fun or a `{module, function, args}` MFA taking the RAW token, returning
  `{:ok, scope}` or anything else) maps the token → `%Samen.Scope{}` actor + plane via the
  host's own SHA-256 digest lookup — no new token resource is minted here (ADR-043 §11
  "MCP token storage shape" resolved: reuse the host's existing per-operator API token).
  A missing/invalid/unresolvable token ⇒ **401** (fail-closed); no resolver wired ⇒ 401.

  ## Transport

    * **POST** — a single JSON-RPC request (`initialize` / `tools/list` / `tools/call` /
      `ping` / notifications). The decoded request is dispatched to
      `Samen.AI.Mcp.handle_rpc/3` against the token's scope. The response is returned as
      `text/event-stream` (one SSE `message` event) when the client `Accept`s it — the
      streamable-SSE surface — else as `application/json`. A notification (`{:noreply}`) is
      a bare `202`.
    * **GET** — no server-initiated SSE stream is offered (the server is stateless per
      request; ADR-043 §11 "SSE session bookkeeping" is resolved as stateless), so a GET is a
      spec-permitted `405` with `Allow: POST`.

  ## EG4 — masked by construction

  This plug never touches resource data: `Samen.AI.Mcp` routes EVERY tool output through the
  chokepoint `:mcp` scrub before it is serialized here (masked vault fields, no `vt_*` tokens,
  org-scoped). The plug's own responsibility is auth + protocol framing.
  """

  @behaviour Plug

  import Plug.Conn

  alias Samen.AI.Mcp

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{method: "POST"} = conn, opts), do: rpc(conn, opts)

  def call(%Plug.Conn{method: "GET"} = conn, _opts) do
    conn
    |> put_resp_header("allow", "POST")
    |> send_resp(405, "MCP: no server-initiated SSE stream; POST a JSON-RPC request")
  end

  def call(conn, _opts) do
    conn
    |> put_resp_header("allow", "POST")
    |> send_resp(405, "method not allowed")
  end

  # --- POST: authenticate → decode → dispatch → respond ------------------------------------

  defp rpc(conn, opts) do
    case authenticate(conn, opts) do
      {:ok, scope} ->
        case read_request(conn) do
          {:ok, request, conn} ->
            case Mcp.handle_rpc(scope, request, tool_opts(opts)) do
              {:reply, response} -> respond(conn, response)
              :noreply -> send_resp(conn, 202, "")
            end

          {:error, conn} ->
            respond(conn, error_envelope(nil, -32_700, "parse error"))
        end

      :unauthorized ->
        unauthorized(conn)
    end
  end

  # --- auth (per-operator token → scope, fail-closed) --------------------------------------

  defp authenticate(conn, opts) do
    with ["Bearer " <> raw | _] <- get_req_header(conn, "authorization"),
         true <- byte_size(raw) > 0,
         {:ok, scope} <- resolve_actor(opts[:actor_resolver], raw) do
      {:ok, scope}
    else
      _ -> :unauthorized
    end
  end

  # No resolver wired ⇒ fail closed (never a silent unauthenticated session).
  defp resolve_actor(nil, _raw), do: :unauthorized

  defp resolve_actor(fun, raw) when is_function(fun, 1), do: normalize_actor(fun.(raw))

  defp resolve_actor({mod, fun, args}, raw) when is_atom(mod) and is_atom(fun) and is_list(args),
    do: normalize_actor(apply(mod, fun, [raw | args]))

  defp resolve_actor(_other, _raw), do: :unauthorized

  defp normalize_actor({:ok, scope}) when not is_nil(scope), do: {:ok, scope}
  defp normalize_actor(_), do: :unauthorized

  defp unauthorized(conn) do
    conn
    |> put_resp_header("www-authenticate", "Bearer")
    |> put_resp_header("content-type", "application/json")
    |> send_resp(401, Jason.encode!(error_envelope(nil, -32_001, "unauthorized")))
  end

  # --- request decoding (prefer the endpoint's parsed body; else read + decode) ------------

  defp read_request(conn) do
    case conn.body_params do
      %{"method" => _} = params ->
        {:ok, params, conn}

      _ ->
        case read_body(conn) do
          {:ok, body, conn} -> decode(body, conn)
          {:more, _partial, conn} -> {:error, conn}
          {:error, _reason} -> {:error, conn}
        end
    end
  end

  defp decode(body, conn) do
    case Jason.decode(body) do
      {:ok, %{"method" => _} = req} -> {:ok, req, conn}
      _ -> {:error, conn}
    end
  end

  # --- response framing (content negotiation: SSE if accepted, else JSON) ------------------

  defp respond(conn, response) do
    json = Jason.encode!(response)

    if accepts_sse?(conn) do
      conn
      |> put_resp_header("content-type", "text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> send_resp(200, "event: message\ndata: " <> json <> "\n\n")
    else
      conn
      |> put_resp_header("content-type", "application/json")
      |> send_resp(200, json)
    end
  end

  defp accepts_sse?(conn) do
    conn
    |> get_req_header("accept")
    |> Enum.any?(&String.contains?(&1, "text/event-stream"))
  end

  defp error_envelope(id, code, message),
    do: %{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => code, "message" => message}}

  # --- tool wiring passthrough -------------------------------------------------------------

  defp tool_opts(opts) do
    case Keyword.get(opts, :tool_opts, []) do
      kw when is_list(kw) -> kw
      fun when is_function(fun, 0) -> fun.()
      {mod, fun, args} -> apply(mod, fun, args)
      _ -> []
    end
  end
end
