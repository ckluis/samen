defmodule Samen.WideEvent.Sink do
  @moduledoc """
  The sink-adapter behaviour for wide events (doc §runs 4b).

  A wide event is emitted via `:telemetry.execute([:samen, :wide_event], …)`; a
  sink adapter attaches as a telemetry handler and ships the event to a backend
  (in-memory ring buffer, a JSONL file, or an OTLP/Honeycomb exporter).

  ## Retention / TTL (the doc's "the sink is retained under a stated TTL besides")

  Every adapter takes a `Samen.WideEvent.Retention` config and enforces it:

    * the **in-memory** adapter is a bounded ring buffer (`max_events`) — it never
      grows without bound (blast-radius: an unbounded telemetry buffer is its own
      outage, per the metrics §4c reasoning);
    * the **file** adapter prunes events older than `ttl_seconds` on each write (a
      cheap, deterministic prune — no background sweeper needed in dev/CI);
    * the **OTLP** adapter documents that TTL is enforced **at the third-party
      backend** (Honeycomb/Tempo dataset retention), which is the honest seam: a
      third-party append-only sink's retention is the backend's, registered as an
      operator TODO.

  ## Ingress-class guarantee

  A sink only ever RECEIVES tokens / bounded IDs / pseudonyms (the J2 schema
  guarantees this at write time). The adapter does NOT re-validate — the
  `Samen.WideEvent` struct is already schema-validated at `emit/1`. The sink's job
  is transport + retention, not classification.
  """

  @doc "Handle one wide event. `event` is a `Samen.WideEvent` struct."
  @callback handle_event(Samen.WideEvent.t(), Samen.WideEvent.Retention.t()) :: :ok

  @doc "A short atom name for the adapter (diagnostics / handler id)."
  @callback name() :: atom()
end

defmodule Samen.WideEvent.Retention do
  @moduledoc """
  Retention / TTL config for a wide-event sink (the doc's "stated TTL").

    * `ttl_seconds` — events older than this are pruned (file adapter) or the
      documented backend retention window (OTLP adapter). Default 7 days.
    * `max_events` — hard cap for the in-memory ring buffer (bounded blast radius).
      Default 10_000.

  A wide-event sink is a **debug** surface; its retention is deliberately bounded
  and short. Long-lived compliance records live in `aud_event` (a separate DB
  tier), not here — the doc keeps the two surfaces separate on purpose.
  """
  @default_ttl_seconds 7 * 24 * 60 * 60
  @default_max_events 10_000

  defstruct ttl_seconds: @default_ttl_seconds, max_events: @default_max_events

  @type t :: %__MODULE__{ttl_seconds: pos_integer(), max_events: pos_integer()}

  @doc "Build a retention config, reading `config :samen_core, :wide_event_retention` for overrides."
  @spec load() :: t()
  def load do
    cfg = Application.get_env(:samen_core, :wide_event_retention, [])

    %__MODULE__{
      ttl_seconds: Keyword.get(cfg, :ttl_seconds, @default_ttl_seconds),
      max_events: Keyword.get(cfg, :max_events, @default_max_events)
    }
  end

  @doc "The default TTL in seconds."
  @spec default_ttl_seconds() :: pos_integer()
  def default_ttl_seconds, do: @default_ttl_seconds

  @doc "The default in-memory max event count."
  @spec default_max_events() :: pos_integer()
  def default_max_events, do: @default_max_events
end
