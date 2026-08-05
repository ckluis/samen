defmodule Samen.Web.AI.McpPlugTest do
  @moduledoc """
  RP-T69 (transport) — the D4 MCP HTTP+SSE endpoint (`Samen.Web.AI.McpPlug`).

  Proves the wire contract the ADR §9 fixes as non-negotiable at the transport layer:

    * **auth** — no/invalid bearer token ⇒ 401 (fail-closed); a valid token resolves to a
      scope and the request proceeds (the positive control);
    * **protocol** — `initialize` / `tools/list` speak the fixed shape; the four tools are
      advertised; a notification is a bare 202; a GET offers no server-initiated SSE (405);
    * **dispatch** — a `tools/call` routes to `Samen.AI.Mcp` (keyless Fake completion path);
    * **streamable SSE** — a client that `Accept`s `text/event-stream` gets the response
      framed as one SSE `message` event; otherwise `application/json`.

  The EG4 masking / org-scope / grant / human-gate invariants are proven at the tool layer in
  `samen_core`'s `Samen.AI.McpTest` (the chokepoint `:mcp` scrub the tools route through).
  """
  use ExUnit.Case, async: true

  import Plug.Test
  import Plug.Conn

  alias Samen.Web.AI.McpPlug

  @token "operator-token-abc"

  # The per-operator token → scope resolver seam (a host's SHA-256 digest lookup precedent).
  defp resolver do
    fn
      @token -> {:ok, %Samen.Scope{actor: %{id: "op1", org_id: Ash.UUID.generate(), role: :member, plane: :tenant}}}
      _ -> :error
    end
  end

  defp plug_opts(extra \\ []) do
    McpPlug.init([actor_resolver: resolver(), tool_opts: []] ++ extra)
  end

  defp post(request, headers \\ [{"authorization", "Bearer " <> @token}]) do
    conn = conn(:post, "/mcp", Jason.encode!(request))
    conn = Enum.reduce(headers, conn, fn {k, v}, c -> put_req_header(c, k, v) end)
    McpPlug.call(conn, plug_opts())
  end

  defp body_json(conn), do: Jason.decode!(conn.resp_body)

  # ==========================================================================
  # Auth — 401 fail-closed
  # ==========================================================================

  describe "auth (per-operator bearer token)" do
    test "no Authorization header ⇒ 401" do
      conn = McpPlug.call(conn(:post, "/mcp", Jason.encode!(%{"method" => "tools/list", "id" => 1})), plug_opts())
      assert conn.status == 401
    end

    test "an invalid token ⇒ 401 (resolver rejects)" do
      conn = post(%{"method" => "tools/list", "id" => 1}, [{"authorization", "Bearer wrong"}])
      assert conn.status == 401
    end

    test "no resolver wired ⇒ 401 (fail-closed)" do
      conn =
        conn(:post, "/mcp", Jason.encode!(%{"method" => "tools/list", "id" => 1}))
        |> put_req_header("authorization", "Bearer " <> @token)
        |> McpPlug.call(McpPlug.init([]))

      assert conn.status == 401
    end

    test "a valid token proceeds (positive control)" do
      conn = post(%{"method" => "ping", "id" => 1})
      assert conn.status == 200
    end
  end

  # ==========================================================================
  # Protocol
  # ==========================================================================

  describe "protocol surface" do
    test "initialize returns the fixed protocol shape" do
      conn = post(%{"method" => "initialize", "id" => 1})
      assert conn.status == 200
      body = body_json(conn)
      assert body["result"]["protocolVersion"] == Samen.AI.Mcp.protocol_version()
      assert body["result"]["serverInfo"]["name"] == "samen-mcp"
    end

    test "tools/list advertises the four tools" do
      conn = post(%{"method" => "tools/list", "id" => 2})
      names = conn |> body_json() |> get_in(["result", "tools"]) |> Enum.map(& &1["name"]) |> Enum.sort()
      assert names == ["action_proposals", "browse", "drafts", "search"]
    end

    test "a notification (no id) ⇒ 202, no body" do
      conn = post(%{"method" => "notifications/initialized"})
      assert conn.status == 202
    end

    test "GET offers no server-initiated SSE stream ⇒ 405 Allow: POST" do
      conn = McpPlug.call(conn(:get, "/mcp"), plug_opts())
      assert conn.status == 405
      assert get_resp_header(conn, "allow") == ["POST"]
    end
  end

  # ==========================================================================
  # Dispatch + streamable SSE framing
  # ==========================================================================

  describe "tools/call dispatch + SSE framing" do
    test "tools/call drafts routes to Samen.AI.Mcp (keyless Fake) and returns a draft" do
      conn =
        post(%{
          "method" => "tools/call",
          "id" => 5,
          "params" => %{"name" => "drafts", "arguments" => %{"verb" => "generate", "input" => "a welcome email"}}
        })

      assert conn.status == 200
      result = conn |> body_json() |> get_in(["result"])
      assert result["isError"] == false
      assert result["structuredContent"]["kind"] == "draft"
    end

    test "Accept: text/event-stream frames the response as one SSE message event" do
      conn =
        conn(:post, "/mcp", Jason.encode!(%{"method" => "tools/list", "id" => 6}))
        |> put_req_header("authorization", "Bearer " <> @token)
        |> put_req_header("accept", "text/event-stream")
        |> McpPlug.call(plug_opts())

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") |> List.first() =~ "text/event-stream"
      assert conn.resp_body =~ ~r/^event: message\ndata: /
    end

    test "application/json when SSE is not accepted" do
      conn = post(%{"method" => "tools/list", "id" => 7})
      assert get_resp_header(conn, "content-type") |> List.first() =~ "application/json"
    end
  end
end
