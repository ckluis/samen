defmodule Samen.Observability.JobSpansTest do
  @moduledoc """
  ADR-052 §2.1 (P1 item 2) — trace context across the queue boundary, by construction:

    * `Samen.Jobs.enqueue_in_tx/4` stamps the CURRENT span's W3C context into the job's
      `meta["trace_context"]` (and leaves the changeset alone when there is no span);
    * `Samen.Observability.JobSpans` (default ON in `child_specs/2`) opens an `oban.job` span
      on Oban's `[:oban, :job, :start]` telemetry, parented on that context, and ends it on
      `:stop` / `:exception` — so a worker needs no per-worker `with_job_span/3`;
    * the job span carries only the worker / queue / attempt, never args.
  """
  use ExUnit.Case, async: false

  require Record
  require Samen.Tracer

  Record.defrecord(:span, Record.extract(:span, from_lib: "opentelemetry/include/otel_span.hrl"))

  alias Samen.Jobs
  alias Samen.Jobs.RollupRefreshWorker
  alias Samen.Observability
  alias Samen.Observability.JobSpans

  @repo SamenCore.TestRepo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(@repo)
    Ecto.Adapters.SQL.Sandbox.mode(@repo, {:shared, self()})
    :otel_simple_processor.set_exporter(:otel_exporter_pid, self())
    JobSpans.detach()
    :ok = JobSpans.attach()

    on_exit(fn ->
      JobSpans.detach()
      :otel_simple_processor.set_exporter(:otel_exporter_pid, :undefined)
    end)

    :ok
  end

  # Run the enqueue multi for real and return the INSERTED job's meta (the multi step is an
  # Oban-built closure, so the row is the only honest observation).
  defp enqueued_meta(args) do
    {:ok, %{job: %Oban.Job{} = job}} =
      @repo.transaction(Jobs.enqueue_in_tx(Ecto.Multi.new(), :job, RollupRefreshWorker.new(args)))

    job.meta
  end

  defp spans_named(name, acc \\ []) do
    receive do
      {:span, s} -> spans_named(name, [s | acc])
    after
      200 -> acc |> Enum.reverse() |> Enum.filter(&(span(&1, :name) == name))
    end
  end

  test "enqueue_in_tx stamps the active span's trace context into the job meta" do
    parent_trace =
      Samen.Tracer.with_span "request" do
        send(self(), {:meta, enqueued_meta(%{})})
        :otel_span.hex_trace_id(:otel_tracer.current_span_ctx())
      end

    assert_receive {:meta, %{"trace_context" => [[_header, value] | _]}}
    assert value =~ to_string(parent_trace)
  end

  test "POSITIVE CONTROL: with no active span the changeset meta is untouched" do
    refute Map.has_key?(enqueued_meta(%{}) || %{}, "trace_context")
  end

  test "the oban.job span is a CHILD of the enqueuing span (one trace across the queue)" do
    {meta, parent_trace} =
      Samen.Tracer.with_span "request" do
        {enqueued_meta(%{a: 1}), :otel_span.trace_id(:otel_tracer.current_span_ctx())}
      end

    job = %{
      id: 4242,
      meta: meta,
      worker: "Samen.Jobs.RollupRefreshWorker",
      queue: "rollups",
      attempt: 1,
      args: %{"secret" => "alice@example.com"}
    }

    # Oban runs start → perform → stop in ONE process.
    Task.async(fn ->
      :telemetry.execute([:oban, :job, :start], %{system_time: 0}, %{job: job})
      :telemetry.execute([:oban, :job, :stop], %{duration: 1}, %{job: job, state: :success})
    end)
    |> Task.await()

    assert [s] = spans_named(JobSpans.span_name())
    assert span(s, :trace_id) == parent_trace

    attrs = s |> span(:attributes) |> :otel_attributes.map()
    assert attrs[:"oban.worker"] == "Samen.Jobs.RollupRefreshWorker"
    assert attrs[:"oban.queue"] == "rollups"
    refute inspect(attrs) =~ "alice"
  end

  test "an exception ends the span with an error status; a malformed job never detaches" do
    job = %{id: 4343, meta: %{}, worker: "W", queue: "default", attempt: 2}

    Task.async(fn ->
      :telemetry.execute([:oban, :job, :start], %{}, %{job: job})
      :telemetry.execute([:oban, :job, :exception], %{}, %{job: job, kind: :error, reason: :boom})
    end)
    |> Task.await()

    assert [s] = spans_named(JobSpans.span_name())
    assert {:status, :error, _} = span(s, :status)

    :telemetry.execute([:oban, :job, :start], %{}, %{job: :not_a_job})
    :telemetry.execute([:oban, :job, :stop], %{}, %{})

    assert Enum.any?(
             :telemetry.list_handlers([:oban, :job, :start]),
             &(&1.id == JobSpans.handler_id())
           )
  end

  test "wired by child_specs/2 ON by default; job_spans: false opts out" do
    ids = fn specs -> for %{id: id} <- specs, do: id end
    assert {Observability, :job_spans, :js_app} in ids.(Observability.child_specs(:js_app))

    refute {Observability, :job_spans, :js_app} in ids.(
             Observability.child_specs(:js_app, job_spans: false)
           )
  end
end
