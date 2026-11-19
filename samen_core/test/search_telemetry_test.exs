defmodule Samen.SearchTelemetryTest do
  @moduledoc """
  WS-F5 F5.2 — `Samen.Search.query/3` emits a latency sample through the bounded
  Samen.Metrics machinery (`samen.search.query.duration`). The search TERM is never a
  label (unbounded); only a duration + a bounded result_count are measured. A blank
  term short-circuits with no query, so it emits nothing.
  """

  use ExUnit.Case, async: false

  alias Samen.Search
  alias SamenCore.Support.NotificationFixture.SearchIndex

  setup do
    Samen.TestSandbox.shared!(SamenCore.TestRepo)
    :ok
  end

  # A READABLE registry with nothing registered: an honest `[]`. (An unreadable registry raises since honest-reads phase E,
  # so it can no longer stand in for "no rows".)
  defp scope do
    org = Ash.UUID.generate()
    %Samen.Scope{actor: %{id: "u:#{org}", org_id: org, role: :member, plane: :tenant}}
  end

  defp opts, do: [search_index: SearchIndex, repo: SamenCore.TestRepo, resources: []]

  defp attach(event) do
    handler = {:search_telemetry, System.unique_integer([:positive])}
    test_pid = self()

    :telemetry.attach(
      handler,
      event,
      fn _e, measurements, metadata, _ ->
        send(test_pid, {:search_telemetry, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  test "a non-blank query emits [:samen, :search, :query, :stop] with a duration" do
    attach([:samen, :search, :query, :stop])

    # The org registered nothing, so this returns [] — but the emission fires because a real query ran. That is exactly the seam we
    # measure: the latency of a search, independent of hits.
    assert [] = Search.query(scope(), "anything", opts())

    assert_receive {:search_telemetry, measurements, metadata}
    assert is_integer(measurements.duration)
    assert measurements.result_count == 0
    # No unbounded term label — metadata is empty (bounded-cardinality contract).
    assert metadata == %{}
  end

  test "a BLANK query short-circuits and emits nothing (no query ran)" do
    attach([:samen, :search, :query, :stop])

    assert [] = Search.query(scope(), "   ", opts())

    refute_receive {:search_telemetry, _, _}
  end
end
