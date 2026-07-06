defmodule Samen.WideEvent.Sinks.Otlp do
  @moduledoc """
  Honeycomb-shaped OTLP wide-event sink **skeleton** (doc §runs 4b:
  "OpenTelemetry → Honeycomb/Tempo/Loki").

  This is the production transport SEAM, deliberately a skeleton in this
  environment: **there is no live Honeycomb/OTLP collector in local dev/CI**, so
  the adapter does not open a network connection. It:

    * shapes a wide event into a Honeycomb-style flat attribute map
      (`shape/1` — the on-the-wire form: bounded IDs / tokens / enums / numbers,
      the exact set the J2 schema guarantees), and
    * dispatches it to a configured **export function** (`config
      :samen_core, :wide_event_otlp, export: fn attrs -> … end`) — defaulting to a
      no-op that records nothing. Wiring a real `opentelemetry_exporter` OTLP call
      here is an **operator TODO** (documented in the observability guide).

  ## Retention seam (honest)

  Unlike the in-memory (ring buffer) and file (prune) adapters, an OTLP sink's TTL
  is the **third-party backend's dataset retention** — Samen cannot prune
  Honeycomb. `retention_note/1` returns the documented window; enforcing it is the
  backend's responsibility, registered as an operator TODO. This is the "one seam
  this sink has that the in-Postgres tiers don't: it is third-party and
  append-only, so key-shred cannot reach it" — which is exactly why `actor_id` is
  a KMS-keyed pseudonym that unlinks on shred rather than a value key-shred must
  chase.
  """

  @behaviour Samen.WideEvent.Sink

  alias Samen.WideEvent
  alias Samen.WideEvent.Retention

  @handler_id {__MODULE__, :handler}
  @service_name "samen"

  @impl Samen.WideEvent.Sink
  def name, do: :otlp

  @doc "Attach the telemetry handler that shapes + exports wide events over OTLP."
  @spec attach(keyword()) :: :ok | {:error, :already_exists}
  def attach(opts \\ []) do
    export = Keyword.get(opts, :export) || configured_export()
    retention = Keyword.get(opts, :retention, Retention.load())

    :telemetry.attach(
      @handler_id,
      WideEvent.telemetry_event(),
      &__MODULE__.__handle__/4,
      %{export: export, retention: retention}
    )
  end

  @doc "Detach the telemetry handler."
  @spec detach() :: :ok | {:error, :not_found}
  def detach, do: :telemetry.detach(@handler_id)

  @doc false
  def __handle__(_event, measurements, metadata, %{export: export}) do
    ev = struct(WideEvent, Map.merge(measurements, metadata))
    export.(shape(ev))
    :ok
  end

  @impl Samen.WideEvent.Sink
  def handle_event(%WideEvent{} = ev, _retention) do
    configured_export().(shape(ev))
    :ok
  end

  @doc """
  Shape a wide event into a Honeycomb-style flat attribute map.

  Honeycomb ingests flat key/value attributes; OTLP span attrs are similar. Keys
  are dotted (`samen.request_id`, `samen.op`, …) and values are the bounded
  ID/token/enum/number the schema guarantees. `nil` fields are omitted. This is
  the on-the-wire form — the ingress-class contract lives at the SCHEMA (J2), so
  this shaper never has to classify.
  """
  @spec shape(WideEvent.t()) :: %{String.t() => term()}
  def shape(%WideEvent{} = ev) do
    ev
    |> Map.from_struct()
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Enum.map(fn {k, v} -> {"#{@service_name}.#{k}", wire_value(v)} end)
    |> Map.new()
    |> Map.put("service.name", @service_name)
  end

  # Enum atoms serialize to strings on the wire (Honeycomb has no atom type). This
  # is safe: the value is a bounded enum label, never free text (the schema check
  # forbids a :string field, so no name reaches here).
  defp wire_value(v) when is_atom(v), do: Atom.to_string(v)
  defp wire_value(v), do: v

  @doc "The documented backend-retention note for operators (TTL is the backend's, not ours)."
  @spec retention_note(Retention.t()) :: String.t()
  def retention_note(%Retention{ttl_seconds: ttl}) do
    "OTLP sink retention is the third-party backend's dataset TTL (~#{div(ttl, 86_400)}d " <>
      "target). Samen cannot prune Honeycomb/Tempo; configure dataset retention at the " <>
      "backend. actor_id is a KMS-keyed pseudonym that unlinks on shred — the sink is " <>
      "ingress-class, not destruction-class (doc §runs 4b). Operator TODO: wire a real " <>
      "opentelemetry_exporter OTLP endpoint."
  end

  # Default export is a no-op (no live collector in this environment). Operators
  # override via config to point at a real OTLP exporter.
  defp configured_export do
    :samen_core
    |> Application.get_env(:wide_event_otlp, [])
    |> Keyword.get(:export, fn _attrs -> :ok end)
  end
end
