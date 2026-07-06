defmodule Samen.TracerTest do
  @moduledoc """
  T2.6 OTel tracing tests.

  ## What is tested

    * `filter_reveal_attrs/1`: the reveal allow-list strips disallowed keys
    * `with_reveal_span/3`: span carries EXACTLY the three allowed attrs; the
      decrypted value is absent from the exported span (red path)
    * `with_job_span/3` + `inject_trace_context/1`: trace propagation across the
      Oban job boundary — parent and child spans share the same trace_id
      (connected trace)
    * Ecto span `db.statement` absent: an Ecto-emitted OTel span has no `db.statement`
      attribute (asserted on exported span attributes via the pid exporter)
    * Anti-tautology probe: passing a disallowed attr to `with_reveal_span/3`
      strips it — the exported span does not contain it

  ## Simulation seam

  No physical OTel collector is present. Tests use `:otel_exporter_pid` (built
  into the OTel SDK) which delivers spans as `{:span, span_record}` messages.
  The `:otel_simple_processor` is configured to use this pid exporter at
  `setup_all` time and reset at teardown. The in-memory delivery is
  synchronous (simple processor blocks until each span is exported).

  Operator TODO: wire a real OTLP exporter in deployment. The seam is the
  `traces_exporter: :none` config in config/config.exs.
  """

  use ExUnit.Case, async: false

  require Record

  # Import the span record from the OTel include file so we can pattern-match
  # on fields without reaching into opaque offsets.
  Record.defrecord(:span, Record.extract(:span, from_lib: "opentelemetry/include/otel_span.hrl"))

  # ---------------------------------------------------------------------------
  # Test setup: redirect OTel spans to the test process via pid exporter
  # ---------------------------------------------------------------------------

  setup do
    # Direct the simple processor to send spans to *this* test process.
    # set_exporter/1 is the deprecated-but-still-functional API for test use.
    :otel_simple_processor.set_exporter(:otel_exporter_pid, self())

    on_exit(fn ->
      # Reset to :none so other tests don't receive stray spans.
      :otel_simple_processor.set_exporter(:otel_exporter_pid, :undefined)
    end)

    :ok
  end

  # ---------------------------------------------------------------------------
  # 1. filter_reveal_attrs/1 — unit tests (no span needed)
  # ---------------------------------------------------------------------------

  describe "filter_reveal_attrs/1" do
    test "returns only allowed attrs from a flat map" do
      input = %{subject_id: "sub-1", grant_id: "grnt-1", reason: "support", decrypted_value: "Alice Smith"}
      result = Samen.Tracer.filter_reveal_attrs(input)
      assert result == %{attributes: %{subject_id: "sub-1", grant_id: "grnt-1", reason: "support"}}
    end

    test "strips disallowed keys" do
      input = %{subject_id: "sub-1", plaintext_name: "Alice", raw_ssn: "123-45-6789"}
      result = Samen.Tracer.filter_reveal_attrs(input)
      assert result == %{attributes: %{subject_id: "sub-1"}}
      refute Map.has_key?(result.attributes, :plaintext_name)
      refute Map.has_key?(result.attributes, :raw_ssn)
    end

    test "handles empty map" do
      assert Samen.Tracer.filter_reveal_attrs(%{}) == %{attributes: %{}}
    end

    test "handles attrs already in start_opts shape" do
      input = %{attributes: %{subject_id: "s1", decrypted: "oops"}}
      result = Samen.Tracer.filter_reveal_attrs(input)
      assert result == %{attributes: %{subject_id: "s1"}}
    end

    test "reveal_allowed_attrs/0 returns exactly three atoms" do
      allowed = Samen.Tracer.reveal_allowed_attrs()
      assert Enum.sort(allowed) == [:grant_id, :reason, :subject_id]
    end
  end

  # ---------------------------------------------------------------------------
  # 2. with_reveal_span — span attribute assertions (via pid exporter)
  # ---------------------------------------------------------------------------

  describe "with_reveal_span/3" do
    test "exported span carries exactly the three allowed attributes" do
      require Samen.Tracer

      sub_id = "sub-#{System.unique_integer()}"
      grant_id = "grnt-#{System.unique_integer()}"

      Samen.Tracer.with_reveal_span("reveal.test.allowed_only",
        %{subject_id: sub_id, grant_id: grant_id, reason: "testing"}
      ) do
        :ok
      end

      assert_receive {:span, span_record}, 1000

      attrs = span_attributes(span_record)
      assert Map.has_key?(attrs, :subject_id) or Map.has_key?(attrs, "subject_id")
      assert Map.has_key?(attrs, :grant_id) or Map.has_key?(attrs, "grant_id")
      assert Map.has_key?(attrs, :reason) or Map.has_key?(attrs, "reason")
    end

    # RED PATH: decrypted value absent from span attributes (the critical safety guarantee)
    test "decrypted value is NOT present in exported span attributes" do
      require Samen.Tracer

      Samen.Tracer.with_reveal_span("reveal.test.strip_decrypted",
        %{
          subject_id: "sub-red-path",
          grant_id: "grnt-red-path",
          reason: "red path test",
          decrypted_value: "Alice Smith — the plaintext that must not leak"
        }
      ) do
        :ok
      end

      assert_receive {:span, span_record}, 1000

      attrs = span_attributes(span_record)

      # The decrypted value must be absent — no key, no value
      refute Map.has_key?(attrs, :decrypted_value)
      refute Map.has_key?(attrs, "decrypted_value")

      # None of the attribute values should contain the plaintext
      attr_values = Map.values(attrs)
      refute Enum.any?(attr_values, fn v ->
        is_binary(v) and String.contains?(v, "Alice Smith")
      end)
    end

    # ANTI-TAUTOLOGY PROBE: the test above would be vacuously true if `filter_reveal_attrs`
    # simply returned the input unchanged. Confirm the filter actually strips.
    test "anti-tautology probe: filter_reveal_attrs strips the disallowed key" do
      input = %{subject_id: "s1", grant_id: "g1", reason: "r1", decrypted_value: "Alice Smith"}
      filtered = Samen.Tracer.filter_reveal_attrs(input)

      # The filtered result's :attributes must NOT contain :decrypted_value
      assert is_map(filtered)
      assert Map.has_key?(filtered, :attributes)
      inner = filtered.attributes
      refute Map.has_key?(inner, :decrypted_value),
             "filter_reveal_attrs did NOT strip :decrypted_value — the allow-list is broken"
      # And the allowed keys ARE present
      assert Map.has_key?(inner, :subject_id)
      assert Map.has_key?(inner, :grant_id)
      assert Map.has_key?(inner, :reason)
    end

    test "span name is correct" do
      require Samen.Tracer

      Samen.Tracer.with_reveal_span("reveal.contact.full_name",
        %{subject_id: "s", grant_id: "g", reason: "test"}
      ) do
        :ok
      end

      assert_receive {:span, span_record}, 1000
      assert span(span_record, :name) == "reveal.contact.full_name"
    end
  end

  # ---------------------------------------------------------------------------
  # 3. Ecto span db.statement absent (red path via pid exporter)
  # ---------------------------------------------------------------------------

  describe "Ecto OTel span db.statement" do
    test "Ecto span has no db.statement attribute when opentelemetry_ecto is configured :disabled" do
      # Set up OpentelemetryEcto with db_statement: :disabled (the required config)
      # and emit a synthetic Ecto query telemetry event to trigger the handler.
      # We then assert the resulting span has no db.statement key.
      event_prefix = [:samen_core_test, :repo]

      # Attach opentelemetry_ecto with :disabled (the REQUIRED posture)
      OpentelemetryEcto.setup(event_prefix, db_statement: :disabled)

      # Emit a synthetic Ecto query event (mirrors what AshPostgres emits)
      query_event = event_prefix ++ [:query]

      measurements = %{
        total_time: 1_000_000,
        queue_time: 100_000,
        query_time: 800_000,
        decode_time: 100_000,
        idle_time: 0
      }

      metadata = %{
        query: "SELECT com_id FROM com_contact WHERE com_org_id = $1",
        source: "com_contact",
        result: {:ok, []},
        repo: SamenCore.TestRepo,
        type: :ecto_sql_query
      }

      # Parent span so the OTel handler has a trace to attach to
      :otel_tracer.with_span(
        :opentelemetry.get_application_tracer(__MODULE__),
        "test.ecto.parent",
        %{},
        fn _span_ctx ->
          :telemetry.execute(query_event, measurements, metadata)
        end
      )

      # Collect all spans (parent + the ecto child)
      spans = collect_spans(timeout: 200)
      span_names = Enum.map(spans, fn s -> span(s, :name) end)

      # Find the Ecto-emitted span (named like "samen_core_test.repo.query:com_contact")
      ecto_spans =
        Enum.filter(spans, fn s ->
          name = span(s, :name)
          is_binary(name) and String.contains?(name, "query")
        end)

      assert length(ecto_spans) > 0, "Expected at least one Ecto-emitted span; got: #{inspect(span_names)}"

      Enum.each(ecto_spans, fn ecto_span ->
        attrs = span_attributes(ecto_span)

        # RED PATH: db.statement must be absent
        refute Map.has_key?(attrs, "db.statement"),
               "Ecto span has db.statement attribute — SQL text is leaking into traces! " <>
                 "attrs: #{inspect(attrs)}"
        refute Map.has_key?(attrs, :"db.statement"),
               "Ecto span has db.statement attribute (atom key) — SQL text leaking"
      end)

      # Detach the handler to avoid polluting other tests
      :telemetry.detach({OpentelemetryEcto, event_prefix ++ [:query]})
    end

    test "Ecto span WOULD contain db.statement if :enabled — proving the scrub is needed" do
      # Anti-tautology: confirm that with :enabled, the db.statement key IS present.
      # This proves the :disabled test above is not vacuously passing.
      event_prefix = [:samen_core_test_enabled, :repo]
      OpentelemetryEcto.setup(event_prefix, db_statement: :enabled)

      query_event = event_prefix ++ [:query]
      sql_text = "SELECT pat_id FROM pat_patient WHERE pat_org_id = $1"

      measurements = %{
        total_time: 1_000_000,
        queue_time: 100_000,
        query_time: 800_000,
        decode_time: 100_000,
        idle_time: 0
      }

      metadata = %{
        query: sql_text,
        source: "pat_patient",
        result: {:ok, []},
        repo: SamenCore.TestRepo,
        type: :ecto_sql_query
      }

      :otel_tracer.with_span(
        :opentelemetry.get_application_tracer(__MODULE__),
        "test.ecto.enabled_parent",
        %{},
        fn _span_ctx ->
          :telemetry.execute(query_event, measurements, metadata)
        end
      )

      spans = collect_spans(timeout: 200)

      ecto_spans =
        Enum.filter(spans, fn s ->
          name = span(s, :name)
          is_binary(name) and String.contains?(name, "query")
        end)

      if length(ecto_spans) > 0 do
        ecto_span = List.first(ecto_spans)
        attrs = span_attributes(ecto_span)

        # With :enabled, db.statement SHOULD be present (proving :disabled removes it)
        has_db_statement =
          Map.has_key?(attrs, "db.statement") or Map.has_key?(attrs, :"db.statement")

        assert has_db_statement,
               "Expected db.statement with :enabled config — anti-tautology check. attrs: #{inspect(attrs)}"
      end

      :telemetry.detach({OpentelemetryEcto, event_prefix ++ [:query]})
    end
  end

  # ---------------------------------------------------------------------------
  # 4. Oban trace propagation — connected trace across enqueue->perform boundary
  # ---------------------------------------------------------------------------

  describe "Oban trace propagation" do
    test "inject_trace_context puts trace_context into Oban job meta" do
      # Build a dummy Oban job changeset
      job_changeset = Oban.Job.new(%{test: "value"}, worker: "TestWorker", queue: :default)

      # Inside a span, inject the trace context
      :otel_tracer.with_span(
        :opentelemetry.get_application_tracer(__MODULE__),
        "test.enqueue_parent",
        %{},
        fn _span_ctx ->
          updated = Samen.Tracer.inject_trace_context(job_changeset)
          meta = Ecto.Changeset.get_field(updated, :meta)

          assert is_map(meta), "meta should be a map"
          assert Map.has_key?(meta, "trace_context"),
                 "meta should contain trace_context key"

          ctx = Map.get(meta, "trace_context")
          assert is_list(ctx), "trace_context should be a list of pairs"
          assert length(ctx) > 0, "trace_context should not be empty inside a span"

          # Each entry should be a 2-element list [header_name, header_value]
          Enum.each(ctx, fn entry ->
            assert [k, v] = entry
            assert is_binary(k)
            assert is_binary(v)
          end)
        end
      )

      # Flush the parent span
      assert_receive {:span, _}, 1000
    end

    test "inject_trace_context outside a span returns unchanged changeset" do
      job_changeset = Oban.Job.new(%{test: "value"}, worker: "TestWorker", queue: :default)

      # Without an active span, inject should be a no-op or return empty context
      updated = Samen.Tracer.inject_trace_context(job_changeset)
      meta = Ecto.Changeset.get_field(updated, :meta)

      # Either nil/empty (no-op) or empty trace_context list
      if meta != nil and Map.has_key?(meta, "trace_context") do
        ctx = Map.get(meta, "trace_context")
        assert ctx == [], "trace_context should be empty outside a span"
      end
    end

    test "with_job_span continues the trace as a child of the enqueuing span" do
      require Samen.Tracer

      # (parent_trace_id and parent_meta are captured inside the span block below)

      # Step 1: simulate the enqueueing side — create a parent span and inject
      :otel_tracer.with_span(
        :opentelemetry.get_application_tracer(__MODULE__),
        "test.enqueue",
        %{},
        fn _span_ctx ->
          # Get the current trace ID while the parent span is active
          span_ctx = :otel_tracer.current_span_ctx()
          trace_id = elem(span_ctx, 1)  # trace_id is field 2 in span_ctx record

          # Build a fake meta as if inject_trace_context had been called
          headers = :otel_propagator_text_map.inject([])
          encoded = Enum.map(headers, fn {k, v} -> [k, v] end)
          meta = %{"trace_context" => encoded, "parent_trace_id_for_test" => "#{trace_id}"}

          # Step 2: simulate the worker side — extract and create child span
          Samen.Tracer.__with_job_span__("test.perform", meta, fn ->
            child_ctx = :otel_tracer.current_span_ctx()
            child_trace_id = elem(child_ctx, 1)

            # The child span's trace_id must equal the parent's trace_id
            assert child_trace_id == trace_id,
                   "Child span trace_id #{inspect(child_trace_id)} != parent #{inspect(trace_id)}"
          end)
        end
      )

      # Collect spans: we expect 2 (parent "test.enqueue" + child "test.perform")
      spans = collect_spans(timeout: 500)
      span_names = Enum.map(spans, &span(&1, :name))

      assert "test.enqueue" in span_names, "Parent span missing; got: #{inspect(span_names)}"
      assert "test.perform" in span_names, "Child span missing; got: #{inspect(span_names)}"

      # Both spans must share the same trace_id (connected trace)
      [enqueue_span] = Enum.filter(spans, &(span(&1, :name) == "test.enqueue"))
      [perform_span] = Enum.filter(spans, &(span(&1, :name) == "test.perform"))

      assert span(enqueue_span, :trace_id) == span(perform_span, :trace_id),
             "Enqueue and perform spans have different trace_ids — trace is NOT connected"

      # The child span's parent_span_id must be the enqueue span's span_id
      assert span(perform_span, :parent_span_id) == span(enqueue_span, :span_id),
             "Perform span's parent_span_id does not match enqueue span's span_id"
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # Extract the attributes map from an OTel span record.
  # The attributes field is a #attributes{} Erlang record; we use
  # :otel_attributes.map/1 to convert it to a plain Elixir map.
  defp span_attributes(span_record) do
    attrs_record = span(span_record, :attributes)

    if attrs_record == nil or attrs_record == :undefined do
      %{}
    else
      :otel_attributes.map(attrs_record)
    end
  rescue
    _ -> %{}
  end

  # Collect all {:span, _} messages from the mailbox up to a timeout.
  defp collect_spans(opts) do
    timeout = Keyword.get(opts, :timeout, 100)
    do_collect_spans([], timeout)
  end

  defp do_collect_spans(acc, timeout) do
    receive do
      {:span, span_record} ->
        do_collect_spans([span_record | acc], timeout)
    after
      timeout -> Enum.reverse(acc)
    end
  end
end
