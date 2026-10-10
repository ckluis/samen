defmodule Samen.Observability.JobSpans do
  @moduledoc """
  Generic Oban job spans (ADR-052 §2.1, P1 item 2) — the `with_job_span/3` effect for EVERY
  worker, without editing each worker.

  `Samen.Jobs.enqueue_in_tx/4` stamps the enqueuing span's W3C context into
  `meta["trace_context"]` (`Samen.Tracer.inject_trace_context/1`). This attachment, wired by
  `Samen.Observability.child_specs/2` and ON by default (`job_spans: false` opts out), reads it
  back on Oban's own job telemetry:

    * `[:oban, :job, :start]` — extract the parent context from the job's meta (if any), start
      an `oban.job` span as its child, make it current;
    * `[:oban, :job, :stop | :exception]` — end that span (status `error` on exception) and
      restore the previous context.

  Oban emits start and stop/exception from the SAME executing process, so the span state lives
  in that process's dictionary, keyed by job id. The span carries only code-bounded attributes:
  the worker module name, the queue name and the attempt number — never args, never meta
  values, never the error reason.

  Like `Samen.Observability.LiveTelemetry`, the handler never raises (`:telemetry` would
  detach it): a malformed job is skipped.
  """

  @handler_id {__MODULE__, :spans}
  @events [[:oban, :job, :start], [:oban, :job, :stop], [:oban, :job, :exception]]
  @span_name "oban.job"

  @doc "The handler id this module attaches under."
  @spec handler_id() :: term()
  def handler_id, do: @handler_id

  @doc "The span name every job span carries."
  @spec span_name() :: String.t()
  def span_name, do: @span_name

  @doc "Attach the handler (`:ok` or `{:error, :already_exists}` — restart-safe)."
  @spec attach() :: :ok | {:error, :already_exists}
  def attach, do: :telemetry.attach_many(@handler_id, @events, &__MODULE__.handle_event/4, %{})

  @doc "Detach the handler."
  @spec detach() :: :ok | {:error, :not_found}
  def detach, do: :telemetry.detach(@handler_id)

  @doc false
  def handle_event([:oban, :job, :start], _measurements, %{job: job}, _config) do
    # W3C trace context only — never baggage (ADR-052 §2.1.2 item 6).
    token = Samen.Tracer.attach_job_trace_context(Map.get(job, :meta))
    tracer = :opentelemetry.get_application_tracer(__MODULE__)

    span_ctx =
      :otel_tracer.start_span(tracer, @span_name, %{
        kind: :consumer,
        attributes: attributes(job)
      })

    :otel_tracer.set_current_span(span_ctx)
    Process.put(key(job), {span_ctx, token})
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  def handle_event([:oban, :job, kind], _measurements, %{job: job}, _config)
      when kind in [:stop, :exception] do
    case Process.delete(key(job)) do
      {span_ctx, token} ->
        if kind == :exception,
          do: :otel_span.set_status(span_ctx, :opentelemetry.status(:error, "exception"))

        :otel_span.end_span(span_ctx)
        :otel_ctx.detach(token)

      _ ->
        :ok
    end

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  def handle_event(_event, _measurements, _metadata, _config), do: :ok

  # ---------------------------------------------------------------------------

  defp key(job), do: {__MODULE__, Map.get(job, :id)}

  defp attributes(job) do
    %{
      "oban.worker": bounded(Map.get(job, :worker)),
      "oban.queue": bounded(Map.get(job, :queue)),
      "oban.attempt": Map.get(job, :attempt)
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp bounded(v) when is_binary(v) and byte_size(v) <= 256, do: v
  defp bounded(v) when is_atom(v) and v not in [nil, true, false], do: Atom.to_string(v)
  defp bounded(_), do: nil
end
