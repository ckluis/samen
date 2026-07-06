defmodule Samen.MetricsContentionHandlerTest do
  @moduledoc """
  Tests that the pool saturation telemetry handler fires under (simulated) pool
  saturation (T2.8 — contention as a signal).

  ## Simulation seam

  There is no live Ecto pool contention in the test suite. Instead we use
  `:telemetry.execute/3` to fire the Ecto query event directly with a
  `queue_time` value that exceeds the configured threshold. The handler logic
  is real; the saturation trigger is synthetic.

  This is documented in `Samen.Metrics.ContentionHandlers` as the simulation seam.
  """

  use ExUnit.Case, async: false

  alias Samen.Metrics.ContentionHandlers

  setup do
    # Detach any previously attached handlers from other test runs
    ContentionHandlers.detach()

    # Attach with a low threshold so tests can trigger it easily
    ContentionHandlers.attach(
      repo_event_prefix: [:samen_test, :repo],
      pool_saturation_threshold_ms: 5
    )

    on_exit(fn -> ContentionHandlers.detach() end)

    :ok
  end

  describe "Ecto pool saturation handler" do
    test "fires [:samen, :pool, :saturation] when queue_time exceeds threshold" do
      # Subscribe to the saturation event
      ref = make_ref()
      test_pid = self()

      :telemetry.attach(
        "test-saturation-subscriber-#{:erlang.ref_to_list(ref)}",
        [:samen, :pool, :saturation],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:saturation_event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn ->
        :telemetry.detach("test-saturation-subscriber-#{:erlang.ref_to_list(ref)}")
      end)

      # Simulate an Ecto query with queue_time of 100ms (> 5ms threshold)
      # queue_time is in native time units
      queue_time_native = System.convert_time_unit(100, :millisecond, :native)

      :telemetry.execute(
        [:samen_test, :repo, :query],
        %{queue_time: queue_time_native, total_time: queue_time_native},
        %{source: "contacts", type: :ecto_sql_query}
      )

      assert_receive {:saturation_event, measurements, _metadata}, 1000
      assert measurements[:queue_time_ms] >= 5
    end

    test "does NOT fire when queue_time is below threshold" do
      ref = make_ref()
      test_pid = self()

      :telemetry.attach(
        "test-saturation-noop-#{:erlang.ref_to_list(ref)}",
        [:samen, :pool, :saturation],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:saturation_event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn ->
        :telemetry.detach("test-saturation-noop-#{:erlang.ref_to_list(ref)}")
      end)

      # queue_time of 1ms — below the 5ms threshold
      queue_time_native = System.convert_time_unit(1, :millisecond, :native)

      :telemetry.execute(
        [:samen_test, :repo, :query],
        %{queue_time: queue_time_native, total_time: queue_time_native},
        %{source: "contacts", type: :ecto_sql_query}
      )

      # Should NOT receive a saturation event
      refute_receive {:saturation_event, _, _}, 100
    end
  end

  describe "Oban job stop handler" do
    test "re-emits as [:samen, :oban, :job, :stop] with bounded tags" do
      ref = make_ref()
      test_pid = self()

      :telemetry.attach(
        "test-oban-job-#{:erlang.ref_to_list(ref)}",
        [:samen, :oban, :job, :stop],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:oban_job_stop, measurements, metadata})
        end,
        nil
      )

      on_exit(fn ->
        :telemetry.detach("test-oban-job-#{:erlang.ref_to_list(ref)}")
      end)

      duration = System.convert_time_unit(500, :millisecond, :native)
      queue_time = System.convert_time_unit(25, :millisecond, :native)

      :telemetry.execute(
        [:oban, :job, :stop],
        %{duration: duration, queue_time: queue_time},
        %{worker: "Samen.Jobs.RevealAutoRevoke", state: :success, queue: "reveal"}
      )

      assert_receive {:oban_job_stop, measurements, metadata}, 1000

      # Verify bounded tags — no raw ids
      assert is_atom(metadata[:action])
      assert metadata[:result] in [:ok, :error]
      refute Map.has_key?(metadata, :org_id)
      refute Map.has_key?(metadata, :actor_id)
      refute Map.has_key?(metadata, :subject_id)

      assert is_integer(measurements[:duration]) or is_float(measurements[:duration])
    end

    test "oban exception handler emits result: :error" do
      ref = make_ref()
      test_pid = self()

      :telemetry.attach(
        "test-oban-exc-#{:erlang.ref_to_list(ref)}",
        [:samen, :oban, :job, :stop],
        fn _event, _measurements, metadata, _config ->
          send(test_pid, {:oban_exc_stop, metadata})
        end,
        nil
      )

      on_exit(fn ->
        :telemetry.detach("test-oban-exc-#{:erlang.ref_to_list(ref)}")
      end)

      :telemetry.execute(
        [:oban, :job, :exception],
        %{duration: 100, queue_time: 10},
        %{worker: "Samen.Jobs.SomeWorker", kind: :error, reason: "timeout", queue: "default"}
      )

      assert_receive {:oban_exc_stop, metadata}, 1000
      assert metadata[:result] == :error
    end
  end

  describe "bounded label invariant" do
    test "saturation event tags never include raw identifiers" do
      ref = make_ref()
      test_pid = self()

      :telemetry.attach(
        "test-bounded-check-#{:erlang.ref_to_list(ref)}",
        [:samen, :pool, :saturation],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:saturation, measurements, metadata})
        end,
        nil
      )

      on_exit(fn ->
        :telemetry.detach("test-bounded-check-#{:erlang.ref_to_list(ref)}")
      end)

      queue_time_native = System.convert_time_unit(100, :millisecond, :native)

      :telemetry.execute(
        [:samen_test, :repo, :query],
        %{queue_time: queue_time_native},
        %{source: "org_events", type: :ecto_sql_query}
      )

      assert_receive {:saturation, _measurements, metadata}, 1000

      # Forbidden raw identifiers must NOT appear as tag keys
      refute Map.has_key?(metadata, :org_id)
      refute Map.has_key?(metadata, :actor_id)
      refute Map.has_key?(metadata, :subject_id)

      # The :action tag is a bounded atom (table name or atom)
      assert is_atom(metadata[:action])
    end
  end
end
