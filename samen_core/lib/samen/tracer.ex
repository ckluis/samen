defmodule Samen.Tracer do
  @moduledoc """
  PII-safe OpenTelemetry tracing for the Samen substrate (T2.6; doc §runs 4a).

  ## Design goals

  Two scrubs keep tracing inside the no-plaintext invariant (vision doc §runs 4a):

    1. **`db_statement: :disabled`** — `OpentelemetryEcto.setup/2` MUST be called
       with `db_statement: :disabled` so the SQL text and bind parameters never
       serialize into a `db.statement` span attribute. The
       `Samen.NoPlaintextPii.Tiers.LogTelemetry` tier asserts this at both config
       level and live-setup time (Phase 2 extension, T2.6).

    2. **`:reveal` span attribute allow-list** — a reveal span carries EXACTLY
       `subject_id`, `grant_id`, `reason`. The decrypted value is NEVER a span
       attribute or event. `with_reveal_span/3` enforces this: any attr key not in
       the allow-list is stripped before the span is created. The red-path test
       asserts the stripped key is absent from the exported span.

  ## Oban trace propagation

  The enqueueing span id rides the Oban job row in `meta["trace_context"]` (a
  list of W3C-format propagated header key-value pairs). The worker calls
  `with_job_span/3` to restore the parent span context and continues the trace
  across the process / queue boundary. This gives one end-to-end trace per
  request even when work is deferred to a queue.

  The `inject_trace_context/1` helper is the canonical way to stamp a job
  changeset with the current trace context before passing it to
  `Samen.Jobs.enqueue_in_tx/3`.

  ## Module setup (in application start)

  Host applications MUST call this in `YourApp.Application.start/2`:

      # Attach the Ecto telemetry handler with SQL text disabled
      OpentelemetryEcto.setup([:your_app, :repo], db_statement: :disabled)

  And configure the verifier key:

      config :your_app, :opentelemetry_ecto, db_statement: :disabled

  ## Simulation seam

  There is NO physical OTel collector in the local development / CI environment.
  Tests use the in-process `:otel_exporter_pid` (built into the OTel SDK) which
  sends spans as `{:span, span_record}` messages to a test PID, enabling
  synchronous assertions without an external service.

  **Operator TODO:** wire a real OTLP exporter (e.g. `opentelemetry_exporter`
  pointing at Honeycomb/Tempo) in the deployed application config. The simulation
  seam is the `traces_exporter: :none` config in `config/config.exs` and the
  `:otel_exporter_pid` override in test setup.
  """

  @reveal_allowed_attrs ~w(subject_id grant_id reason)a

  @doc """
  The allow-list of span attribute keys permitted on a `:reveal` span.

  Exactly three keys: `subject_id`, `grant_id`, `reason`. The decrypted value
  is NEVER allowed. This list is the single source of truth for the allow-list
  enforcement in `with_reveal_span/3` and the red-path test.
  """
  @spec reveal_allowed_attrs() :: [atom()]
  def reveal_allowed_attrs, do: @reveal_allowed_attrs

  @doc """
  Open a named span and execute `block` within it. Generic wrapper.

  ## Example

      Samen.Tracer.with_span("ash.action") do
        # ... Ash action work ...
      end
  """
  defmacro with_span(name, start_opts \\ quote(do: %{}), do: block) do
    quote do
      tracer = :opentelemetry.get_application_tracer(__MODULE__)
      :otel_tracer.with_span(
        tracer,
        unquote(name),
        Map.new(unquote(start_opts)),
        fn _span_ctx -> unquote(block) end
      )
    end
  end

  @doc """
  Open a `:reveal` span and execute `block` within it, enforcing the allow-list.

  Any key in `attrs` NOT in `reveal_allowed_attrs/0` is STRIPPED SILENTLY
  before the span is created. The decrypted value must NEVER be passed as a span
  attribute — this function structurally prevents it.

  ## Example

      Samen.Tracer.with_reveal_span("reveal.contact.full_name",
        %{subject_id: sub_id, grant_id: grant_id, reason: "support", decrypted_value: plaintext}
      ) do
        # work with plaintext — NOT in the span attributes
      end
      # span carries only: subject_id, grant_id, reason

  ## Strip-not-raise contract

  A disallowed key does NOT raise — it is silently stripped. This is intentional:
  a caller that accidentally includes the decrypted value gets a silent strip, not
  an exception that would propagate out of the reveal path. The red-path test
  confirms the stripped key is absent from the exported span.
  """
  defmacro with_reveal_span(name, attrs, do: block) do
    quote do
      safe_start_opts = Samen.Tracer.filter_reveal_attrs(unquote(attrs))
      tracer = :opentelemetry.get_application_tracer(__MODULE__)
      :otel_tracer.with_span(
        tracer,
        unquote(name),
        safe_start_opts,
        fn _span_ctx -> unquote(block) end
      )
    end
  end

  @doc """
  Filter `attrs` to only the keys permitted on a reveal span, returning a
  `start_opts` map suitable for `OpenTelemetry.Tracer.with_span/3`.

  Called by `with_reveal_span/3`. Public so tests can verify the stripping
  behavior directly (the anti-tautology probe calls this before confirming the
  disallowed key is absent from the exported span).

  The `attrs` argument may be a flat map of attribute key-value pairs (e.g.
  `%{subject_id: "s1", decrypted_value: "Alice"}`) OR already a span start_opts
  map with an `attributes` key. In both cases, the resulting span will carry
  ONLY the three allowed keys.

  ## Example

      iex> Samen.Tracer.filter_reveal_attrs(%{subject_id: "s1", decrypted_value: "Alice"})
      %{attributes: %{subject_id: "s1"}}
  """
  @spec filter_reveal_attrs(map()) :: map()
  def filter_reveal_attrs(attrs) when is_map(attrs) do
    # If attrs is already a start_opts map (has :attributes key), extract and filter.
    # Otherwise treat as a flat attribute map.
    raw =
      case Map.fetch(attrs, :attributes) do
        {:ok, inner} when is_map(inner) -> inner
        _ -> attrs
      end

    filtered = Map.take(raw, @reveal_allowed_attrs)
    %{attributes: filtered}
  end

  @doc """
  Inject the current OTel span context into an Oban job changeset's `meta` map.

  Serializes the current W3C trace context headers into `meta["trace_context"]`
  (a list of `{"header-name", "value"}` tuples encoded as a list of 2-element
  lists for JSON compatibility). The worker calls `with_job_span/3` to restore
  the parent span.

  Returns the changeset unchanged if there is no active span (sampler decided
  not to record) — graceful degradation, never fails.

  ## Usage

      MyWorker.new(%{record_id: id})
      |> Samen.Tracer.inject_trace_context()
      |> Samen.Jobs.enqueue_in_tx(multi, :my_step)
  """
  @spec inject_trace_context(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  def inject_trace_context(%Ecto.Changeset{} = changeset) do
    # inject/1 takes a carrier (list) and returns it with W3C headers prepended.
    # The carrier format is a list of {key, value} tuples.
    headers = :otel_propagator_text_map.inject([])

    if headers == [] do
      changeset
    else
      # Encode as list-of-2-element-lists for JSONB storage in Oban meta
      # (Erlang tuples are not JSON-native; list-of-lists round-trips cleanly).
      encoded = Enum.map(headers, fn {k, v} -> [k, v] end)
      current_meta = Ecto.Changeset.get_field(changeset, :meta) || %{}
      new_meta = Map.put(current_meta, "trace_context", encoded)
      Ecto.Changeset.put_change(changeset, :meta, new_meta)
    end
  rescue
    _ -> changeset
  end

  @doc """
  Open a span as a child of the trace context stored in a job's `meta` map,
  execute `block` within it, and automatically restore the calling context.

  Call this at the start of `Oban.Worker.perform/1`:

      def perform(%Oban.Job{meta: meta}) do
        Samen.Tracer.with_job_span("MyWorker.perform", meta) do
          # all work here is a child of the enqueueing span
        end
      end

  If no trace context is found in `meta["trace_context"]`, the block runs in a
  fresh root span — graceful degradation, never fails closed on missing context.
  """
  defmacro with_job_span(name, meta, do: block) do
    quote do
      Samen.Tracer.__with_job_span__(unquote(name), unquote(meta), fn ->
        unquote(block)
      end)
    end
  end

  @doc false
  def __with_job_span__(name, meta, fun) when is_map(meta) do
    encoded = Map.get(meta, "trace_context", [])
    # Decode list-of-2-element-lists back to {key, value} tuples for the carrier
    headers =
      Enum.flat_map(encoded, fn
        [k, v] when is_binary(k) and is_binary(v) -> [{k, v}]
        _ -> []
      end)

    # Extract the parent context from the propagated headers.
    # :otel_propagator_text_map.extract/1 attaches the parent context as the
    # current process context and returns a token for restoration.
    token = :otel_propagator_text_map.extract(headers)

    tracer = :opentelemetry.get_application_tracer(__MODULE__)

    try do
      :otel_tracer.with_span(tracer, name, %{}, fn _span_ctx -> fun.() end)
    after
      :otel_ctx.detach(token)
    end
  rescue
    _ ->
      fun.()
  end

  def __with_job_span__(name, _meta, fun) do
    tracer = :opentelemetry.get_application_tracer(__MODULE__)
    :otel_tracer.with_span(tracer, name, %{}, fn _span_ctx -> fun.() end)
  rescue
    _ -> fun.()
  end
end
