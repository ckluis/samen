defmodule Samen.Web.MetricsControllerTest do
  @moduledoc """
  WS-F5 F5.1 — the framework `GET /metrics` scrape endpoint (`Samen.Web.MetricsController`).

  The endpoint self-gates: it serves a 200 exposition ONLY when a reporter is actually
  running (resolved at request time via `apply/3`, so samen_web needs no reporter dep),
  and returns a plain 404 otherwise — it NEVER fabricates an empty 200 that a scraper
  would misread as "up but silent".
  """

  use ExUnit.Case, async: true

  import Plug.Test
  import Plug.Conn

  alias Samen.Web.MetricsController

  # A dependency-free reporter stand-in with the `scrape/1` contract the controller calls.
  defmodule OkReporter do
    def scrape(name), do: "# HELP up 1\nup{name=\"#{name}\"} 1\n"
  end

  defmodule RaisingReporter do
    def scrape(_name), do: raise("reporter not started")
  end

  defp call(private) do
    conn(:get, "/metrics")
    |> Map.update!(:private, &Map.merge(&1, private))
    |> MetricsController.scrape(%{})
  end

  test "egress ON — a running reporter yields a 200 text exposition" do
    conn = call(%{samen_metrics: %{reporter: OkReporter, name: :test_reporter}})

    assert conn.status == 200
    assert conn.resp_body =~ "up{name=\"test_reporter\"}"
    assert get_resp_header(conn, "content-type") |> List.first() =~ "text/plain"
  end

  test "egress OFF (no private metadata) — 404, never a fake empty 200" do
    conn = call(%{})

    assert conn.status == 404
    assert conn.resp_body == "metrics egress disabled"
  end

  test "reporter absent/unloadable — 404" do
    conn = call(%{samen_metrics: %{reporter: Samen.Web.NoSuchReporter, name: :x}})
    assert conn.status == 404
  end

  test "reporter raises (not started) — collapses to 404, never a 500" do
    conn = call(%{samen_metrics: %{reporter: RaisingReporter, name: :x}})
    assert conn.status == 404
  end
end
