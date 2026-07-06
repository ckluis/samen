defmodule Samen.Metrics.ContentionHandlers do
  @moduledoc """
  Telemetry handlers that surface DB pool and Oban queue contention as Prometheus
  signals (T2.8; doc §runs 4c/4d).

  ## Why

  On a single-substrate BEAM/Postgres deployment, contention is the most likely
  failure mode. A wedged Ecto connection checkout or an overloaded Oban queue
  starves unrelated requests silently. These handlers convert that silence into
  observable signals: counter increments and distribution buckets that fire
  when contention is real.

  ## What is attached

  1. **Ecto query handler** — listens to `[:my_app, :repo, :query]` events.
     When `queue_time` (time waiting in the connection pool) exceeds
     `pool_saturation_threshold_ms` (default 50 ms), emits
     `[:samen, :pool, :saturation]` with `%{count: 1}`.

  2. **Oban job stop handler** — listens to `[:oban, :job, :stop]` events.
     Re-emits as `[:samen, :oban, :job, :stop]` with bounded tags (`action`,
     `result`) extracted from the job metadata.

  3. **Oban job exception handler** — listens to `[:oban, :job, :exception]`.
     Re-emits as `[:samen, :oban, :job, :stop]` with `result: :error`.

  ## Simulation seam

  There is NO live Ecto pool saturation to trigger in unit tests. The tests use
  `:telemetry.execute/3` directly on the raw Ecto event name to fire the handler
  and assert that `[:samen, :pool, :saturation]` is subsequently emitted. This is
  the documented simulation seam — the handler logic is real, the saturation
  trigger in tests is synthetic.

  **Operator TODO:** in production, configure `repo_event_prefix` to match the
  actual Ecto repo telemetry prefix (e.g. `[:my_app, :repo]`). The Ecto event name
  is `repo_event_prefix ++ [:query]`.

  ## Usage

      # In your Application.start/2, after Repo is started:
      Samen.Metrics.ContentionHandlers.attach(
        repo_event_prefix: [:my_app, :repo],
        pool_saturation_threshold_ms: 50
      )
  """

  require Logger

  @default_threshold_ms 50

  @doc """
  Attach all contention telemetry handlers.

  Options:
    - `:repo_event_prefix` — the prefix for Ecto repo telemetry events (required).
      The handler attaches to `prefix ++ [:query]`.
    - `:pool_saturation_threshold_ms` — queue_time (in milliseconds) above which
      a pool saturation event is emitted. Default: #{@default_threshold_ms} ms.

  Returns `:ok`.
  """
  @spec attach(keyword()) :: :ok
  def attach(opts \\ []) do
    threshold = Keyword.get(opts, :pool_saturation_threshold_ms, @default_threshold_ms)
    repo_prefix = Keyword.get(opts, :repo_event_prefix, [:samen, :repo])
    ecto_event = repo_prefix ++ [:query]

    :telemetry.attach(
      "samen-pool-saturation-handler",
      ecto_event,
      &__MODULE__.handle_ecto_query/4,
      %{threshold_ms: threshold}
    )

    :telemetry.attach(
      "samen-oban-job-stop-handler",
      [:oban, :job, :stop],
      &__MODULE__.handle_oban_job_stop/4,
      %{}
    )

    :telemetry.attach(
      "samen-oban-job-exception-handler",
      [:oban, :job, :exception],
      &__MODULE__.handle_oban_job_exception/4,
      %{}
    )

    :ok
  end

  @doc """
  Detach all contention handlers (useful in test teardown).
  """
  @spec detach() :: :ok
  def detach do
    :telemetry.detach("samen-pool-saturation-handler")
    :telemetry.detach("samen-oban-job-stop-handler")
    :telemetry.detach("samen-oban-job-exception-handler")
    :ok
  rescue
    _ -> :ok
  end

  @doc false
  def handle_ecto_query(_event, measurements, metadata, config) do
    threshold_ms = Map.get(config, :threshold_ms, @default_threshold_ms)

    # queue_time is in native time units (System.monotonic_time/0 units)
    queue_time_native = Map.get(measurements, :queue_time, 0)
    queue_time_ms = System.convert_time_unit(queue_time_native, :native, :millisecond)

    if queue_time_ms >= threshold_ms do
      action = Map.get(metadata, :source, :unknown) |> to_bounded_action()

      :telemetry.execute(
        [:samen, :pool, :saturation],
        %{count: 1, queue_time_ms: queue_time_ms},
        %{action: action}
      )
    end
  rescue
    e -> Logger.debug("ContentionHandlers.handle_ecto_query rescued: #{inspect(e)}")
  end

  @doc false
  def handle_oban_job_stop(_event, measurements, metadata, _config) do
    worker = Map.get(metadata, :worker, "unknown")
    action = worker_to_action(worker)
    result = if Map.get(metadata, :state) == :failure, do: :error, else: :ok

    duration = Map.get(measurements, :duration, 0)
    queue_time = Map.get(measurements, :queue_time, 0)

    :telemetry.execute(
      [:samen, :oban, :job, :stop],
      %{duration: duration, queue_time: queue_time},
      %{action: action, result: result}
    )
  rescue
    e -> Logger.debug("ContentionHandlers.handle_oban_job_stop rescued: #{inspect(e)}")
  end

  @doc false
  def handle_oban_job_exception(_event, measurements, metadata, _config) do
    worker = Map.get(metadata, :worker, "unknown")
    action = worker_to_action(worker)
    duration = Map.get(measurements, :duration, 0)
    queue_time = Map.get(measurements, :queue_time, 0)

    :telemetry.execute(
      [:samen, :oban, :job, :stop],
      %{duration: duration, queue_time: queue_time},
      %{action: action, result: :error}
    )
  rescue
    e -> Logger.debug("ContentionHandlers.handle_oban_job_exception rescued: #{inspect(e)}")
  end

  # Convert an Ecto table/source name to a bounded action atom.
  # This keeps the pool saturation event tagged but cardinality-bounded
  # (table names are a fixed set, not per-row ids).
  defp to_bounded_action(source) when is_binary(source), do: String.to_atom(source)
  defp to_bounded_action(source) when is_atom(source), do: source
  defp to_bounded_action(_), do: :unknown

  # Convert an Oban worker module name string to a bounded action atom.
  # E.g. "MyApp.Workers.ErasureWorker" -> :erasure_worker
  defp worker_to_action(worker) when is_binary(worker) do
    worker
    |> String.split(".")
    |> List.last()
    |> Macro.underscore()
    |> String.to_atom()
  end

  defp worker_to_action(worker) when is_atom(worker), do: worker
  defp worker_to_action(_), do: :unknown
end
