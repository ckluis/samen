defmodule Samen.Web.Api.PageLimitClampTest do
  @moduledoc """
  Boundary clamp for JSON:API page[limit] (AC-G1-6 / RP-G1-6). The e2e proof that an
  over-max request returns EXACTLY max_page_size rows lives in the host apps
  (demo/test/api_pagination_test.exs — non-vacuous: 210 rows seeded against the 200
  cap); this covers the plug's rewrite semantics in isolation.
  """
  use ExUnit.Case, async: true

  alias Samen.Web.Api.PageLimitClamp

  defp run(query_string, opts \\ []) do
    :get
    |> Plug.Test.conn("/contacts?" <> query_string)
    |> PageLimitClamp.call(PageLimitClamp.init(opts))
  end

  test "clamps page[limit] above max to exactly max (default 200)" do
    conn = run("page[limit]=10000")
    assert conn.query_params["page"]["limit"] == "200"
    assert conn.params["page"]["limit"] == "200"
  end

  test "respects a custom :max" do
    conn = run("page[limit]=10000", max: 50)
    assert conn.query_params["page"]["limit"] == "50"
  end

  test "leaves an in-bounds limit untouched" do
    conn = run("page[limit]=150")
    assert conn.query_params["page"]["limit"] == "150"
  end

  test "leaves a malformed limit for Ash's own validation" do
    conn = run("page[limit]=banana")
    assert conn.query_params["page"]["limit"] == "banana"
  end

  test "no page params — conn passes through" do
    conn = run("filter=x")
    refute Map.has_key?(conn.query_params, "page")
  end

  # RED PATH (anti-tautology for the clamp mechanism itself): the clamp must
  # REWRITE, not merely re-read — a conn whose params were already fetched still
  # gets the clamped value downstream.
  test "red-path: pre-fetched params are rewritten, not shadowed" do
    conn =
      :get
      |> Plug.Test.conn("/contacts?page[limit]=9999")
      |> Plug.Conn.fetch_query_params()

    out = PageLimitClamp.call(conn, PageLimitClamp.init([]))
    assert out.query_params["page"]["limit"] == "200"
    assert out.params["page"]["limit"] == "200"
  end
end
