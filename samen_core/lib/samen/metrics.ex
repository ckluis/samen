defmodule Samen.Metrics do
  @moduledoc """
  Bounded-cardinality Telemetry.Metrics definitions for the Samen substrate (T2.8).

  ## Cardinality contract (doc §runs 4d)

  Prometheus series are tagged with **bounded labels only**. The forbidden labels
  are `org_id`, `actor_id`, and `subject_id` — these are per-row identifiers with
  effectively unbounded cardinality that would create their own outage if used as
  Prometheus label dimensions.

  Allowed label dimensions:
    - `action` — a bounded Ash action name atom
    - `route` — a bounded HTTP route pattern (e.g. `/contacts/:id`, not `/contacts/uuid-literal`)
    - `result` — `:ok` / `:error` / `:timeout`
    - `tenant_tier` — a hashed/bucketed tenant tier label (`:free`, `:starter`, `:pro`, `:enterprise`)
      computed by `hash_tenant_tier/2` so neither the raw org_id nor the raw tier leaks

  Per-tenant detail lives in wide events and traces; metrics carry exemplars
  (a `trace_id` on the latency histogram bucket) so a spiking P95 links straight
  to an example trace (see `exemplar_trace_id/0`).

  ## Exemplar support

  `Telemetry.Metrics` itself does not yet standardise an exemplar API. Where the
  reporter allows (e.g. `TelemetryMetricsPrometheus` ≥ 1.1 with `exemplars: true`),
  attach the current `trace_id` as an exemplar on latency histogram buckets by
  including `:trace_id` in the measurement map at emission time. The canonical way
  to get the current trace id for a `:telemetry.execute/3` call is
  `Samen.Metrics.exemplar_trace_id/0`.

  **Operator TODO:** configure `TelemetryMetricsPrometheus.start_link` with
  `exemplars: true` and pass `trace_id` in measurements for the action latency
  histogram. The seam is `exemplar_trace_id/0` in this module.

  ## Label-lint CI check

  `mix samen.verify.metric_labels` (implemented in `Samen.Verify.MetricLabels`) scans
  all metric definitions in the application for raw `org_id`, `actor_id`, or
  `subject_id` tags and exits non-zero if any are found. Add it to `ci.sh` after
  the compile step.

  ## BEAM contention handlers

  `attach_contention_handlers/1` attaches `:telemetry` handlers for:
    - `[:my_app, :repo, :query]` — Ecto pool checkout waiting (slow queries as signals)
    - `Oban` queue depth — job latency above threshold

  These make buffer/connection contention observable as Prometheus signals, not
  mysteries. See `Samen.Metrics.ContentionHandlers` for the implementation.

  ## Pool saturation handler

  `Samen.Metrics.ContentionHandlers.attach/1` registers handlers for:
    - `[:ecto, :pool, :checkout]` (synthetic checkout latency from Ecto's `queue_time`)
    - Oban's `[:oban, :job, :stop]` and `[:oban, :job, :exception]` for job latency/failure

  The Ecto handler fires when `queue_time` on a completed query exceeds the
  configured threshold (default 50 ms), incrementing a `:pool_saturation_event`
  counter. The Oban handler fires on each job completion/failure, tracking
  `queue_time` (wait before execution) as a distribution.
  """

  @doc """
  The bounded label set for Samen metrics.

  Returns the list of tag keys that are safe to use as Prometheus label dimensions.
  Any key NOT in this set must not be used as a metric tag.
  """
  @spec bounded_tag_keys() :: [atom()]
  def bounded_tag_keys, do: [:action, :route, :result, :tenant_tier]

  @doc """
  The forbidden label set — raw identifiers that must never appear as metric tags.

  Used by `Samen.Verify.MetricLabels` (the label-lint CI check).
  """
  @spec forbidden_tag_keys() :: [atom()]
  def forbidden_tag_keys, do: [:org_id, :actor_id, :subject_id]

  @doc """
  Returns the current OTel `trace_id` as a hex string for use as a Prometheus exemplar.

  Where the reporter supports exemplars (e.g. `TelemetryMetricsPrometheus` ≥ 1.1),
  include this value in the measurement map under `:trace_id`:

      :telemetry.execute([:samen, :action, :stop], %{
        duration: System.monotonic_time() - t0,
        trace_id: Samen.Metrics.exemplar_trace_id()
      }, %{action: :create, result: :ok})

  Returns `nil` if there is no active span (safe to include; nil measurements are
  typically ignored by reporters).

  **Simulation seam:** in CI the OTel exporter is `:none`, so this returns the
  trace_id from the in-process test span. In production, with a real OTLP exporter,
  this is the live trace_id that links to Honeycomb/Tempo.
  """
  @spec exemplar_trace_id() :: String.t() | nil
  def exemplar_trace_id do
    ctx = :otel_tracer.current_span_ctx(:otel_ctx.get_current())

    case ctx do
      :undefined ->
        nil

      ctx ->
        try do
          trace_id = :otel_span.trace_id(ctx)
          # trace_id is a 128-bit integer; format as 32-char hex
          if trace_id == 0 do
            nil
          else
            Integer.to_string(trace_id, 16) |> String.downcase() |> String.pad_leading(32, "0")
          end
        rescue
          _ -> nil
        end
    end
  end

  @doc """
  Compute a bounded `tenant_tier` label for a given org_id and raw tier atom.

  The raw `org_id` is NOT emitted as a label. Instead, the tier is bucketed into
  one of four well-known values — `:free`, `:starter`, `:pro`, `:enterprise` — so
  the metric dimension stays bounded regardless of how many orgs exist.

  The `org_id` parameter is accepted to allow future per-tier-override lookup
  (e.g. an enterprise org on the free tier for a trial) but is NOT included in the
  output label. This is intentional — the label stays bounded.

  ## Example

      iex> Samen.Metrics.hash_tenant_tier("org_abc123", :starter)
      :starter

      iex> Samen.Metrics.hash_tenant_tier("org_abc123", :unknown)
      :unknown_tier
  """
  @spec hash_tenant_tier(String.t(), atom()) :: atom()
  def hash_tenant_tier(_org_id, tier) when tier in [:free, :starter, :pro, :enterprise],
    do: tier

  def hash_tenant_tier(_org_id, _tier), do: :unknown_tier

  @doc """
  The canonical `Telemetry.Metrics` definitions for Samen.

  These definitions use ONLY bounded tag keys. Pass this list to your Prometheus
  or StatsD reporter at application start:

      TelemetryMetricsPrometheus.start_link(Samen.Metrics.definitions())

  ## Metrics

    - `samen.action.duration` — histogram of Ash action latency, tagged by
      `action`, `result`, `tenant_tier`
    - `samen.action.count` — counter of Ash action completions, tagged by
      `action`, `result`, `tenant_tier`
    - `samen.http.request.duration` — histogram of HTTP request latency, tagged by
      `route`, `result`
    - `samen.pool.saturation.events` — counter incremented by the contention
      handler when pool queue_time exceeds threshold, tagged by `action`
    - `samen.oban.job.duration` — histogram of Oban job execution time, tagged by
      `action` (worker module), `result`
    - `samen.oban.job.queue_time` — histogram of time an Oban job spent waiting in
      the queue (contention signal), tagged by `action`
    - `samen.files.upload.byte_size` — histogram of uploaded file sizes in bytes
      (WS-F5 F5.2), tagged by `result`; emitted by `Samen.Files.upload/3`
    - `samen.search.query.duration` — histogram of full-text search latency
      (WS-F5 F5.2), no per-row tags; emitted by `Samen.Search.query/3`
    - `samen.csv.export.row_count` — histogram of rows in a CSV export (WS-F5 F5.2),
      tagged by `result`; emitted by `Samen.Web.Csv.export/3`
  """
  @spec definitions() :: [Telemetry.Metrics.t()]
  def definitions do
    import Telemetry.Metrics

    [
      # Ash action latency — bounded tags: action, result, tenant_tier
      distribution(
        "samen.action.duration",
        event_name: [:samen, :action, :stop],
        measurement: :duration,
        unit: {:native, :millisecond},
        tags: [:action, :result, :tenant_tier],
        description: "Ash action latency distribution (bounded labels only)"
      ),

      # Ash action count
      counter(
        "samen.action.count",
        event_name: [:samen, :action, :stop],
        tags: [:action, :result, :tenant_tier],
        description: "Ash action completion count (bounded labels only)"
      ),

      # HTTP request latency — bounded tags: route, result
      distribution(
        "samen.http.request.duration",
        event_name: [:samen, :http, :request, :stop],
        measurement: :duration,
        unit: {:native, :millisecond},
        tags: [:route, :result],
        description: "HTTP request latency distribution (route pattern, not raw URL)"
      ),

      # Pool saturation event counter — tagged by action (bounded atom)
      counter(
        "samen.pool.saturation.events",
        event_name: [:samen, :pool, :saturation],
        tags: [:action],
        description: "DB pool checkout wait events exceeding threshold — contention signal"
      ),

      # Oban job execution latency — tagged by action (worker module atom), result
      distribution(
        "samen.oban.job.duration",
        event_name: [:samen, :oban, :job, :stop],
        measurement: :duration,
        unit: {:native, :millisecond},
        tags: [:action, :result],
        description: "Oban job execution time (bounded labels: worker, result)"
      ),

      # Oban job queue time (wait before execution) — contention signal
      distribution(
        "samen.oban.job.queue_time",
        event_name: [:samen, :oban, :job, :stop],
        measurement: :queue_time,
        unit: {:native, :millisecond},
        tags: [:action],
        description: "Oban job queue wait time — pool/scheduler contention signal"
      ),

      # WS-F5 F5.2 — WS-E surface telemetry through this same bounded machinery.

      # File upload size — bounded tag: result. Emitted by Samen.Files.upload/3.
      distribution(
        "samen.files.upload.byte_size",
        event_name: [:samen, :files, :upload, :stop],
        measurement: :byte_size,
        unit: :byte,
        tags: [:result],
        description: "Uploaded file size in bytes (bounded label: result)"
      ),

      # Search query latency — no per-row tags (a search term is unbounded and never
      # a label). Emitted by Samen.Search.query/3.
      distribution(
        "samen.search.query.duration",
        event_name: [:samen, :search, :query, :stop],
        measurement: :duration,
        unit: {:native, :millisecond},
        tags: [],
        description: "Full-text search query latency (no unbounded term label)"
      ),

      # CSV export row count — bounded tag: result. Emitted by Samen.Web.Csv.export/3.
      distribution(
        "samen.csv.export.row_count",
        event_name: [:samen, :csv, :export, :stop],
        measurement: :row_count,
        tags: [:result],
        description: "Rows emitted by a CSV export (bounded label: result)"
      )
    ]
  end
end
