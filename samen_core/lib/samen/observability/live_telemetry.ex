defmodule Samen.Observability.LiveTelemetry do
  @moduledoc """
  The LiveView + request **wide events** (ADR-052 §2.1, P1 item 1).

  One `:telemetry` attachment, wired by `Samen.Observability.child_specs/2` and ON by default
  (`request_events: false` opts out), turns each Phoenix callback into exactly ONE
  `Samen.WideEvent`:

  | Telemetry event | Wide event |
  |---|---|
  | `[:phoenix, :live_view, :mount, :stop \\| :exception]` | `action: :live_view, callback: :mount` |
  | `[:phoenix, :live_view, :handle_params, :stop \\| :exception]` | `action: :live_view, callback: :handle_params` |
  | `[:phoenix, :live_view, :handle_event, :stop \\| :exception]` | `action: :live_view, callback: :handle_event, event: …` |
  | `[:phoenix, :live_component, :handle_event, :stop \\| :exception]` | `action: :live_component, callback: :component_event, event: …` |
  | `[:phoenix, :endpoint, :stop]` | `action: :http_request, callback: :request, method:, status:` |

  `:telemetry.span/3` emits `:stop` OR `:exception` for a callback, never both, so a callback
  yields one event.

  ## What each event carries — bounded values only

    * `view` — the LiveView (or LiveComponent) **module** name: a code identifier.
    * `event` — `Samen.Observability.LiveEvents.resolve/2`: the view's OWN static
      `handle_event` literal, else `:other`. The client string is a lookup key, never an atom.
    * `outcome` — `:ok` / `:exception`. The exception's reason is NEVER recorded (a raised
      error can carry the very value being processed).
    * `tenant_id` — the socket/conn `:org_id` assign, kept only if it is a UUID.
    * `actor_id` — `Samen.WideEvent.for_subject/2` of the `:samen_tenant_principal` assign:
      the per-subject HMAC pseudonym (unlinkable on shred), never the raw id or an email.
      Computed at most once per process (a LiveView process memoizes it), omitted when the
      subject has no live key.
    * `request_id` (Logger metadata, set by `Plug.RequestId`), `trace_id` / `span_id` (the
      current OTel span, if any), `duration_ms`, and for a request `method` + `status`.

  Params, session, URI, path, query string and assigns other than the two above are never
  read into the event.

  ## A handler that can never crash its caller

  `:telemetry` DETACHES a handler that raises — one malformed metadata map would silently
  turn the plane dark again. `handle_event/4` therefore rescues and catches everything and
  returns `:ok`; a value that fails its bounded type is dropped from the event, and an event
  that still fails validation is dropped whole. Observability is best-effort; the request is
  not.
  """

  alias Samen.Observability.LiveEvents
  alias Samen.WideEvent

  @handler_id {__MODULE__, :wide_events}

  @lv_callbacks [:mount, :handle_params, :handle_event]

  @events (for cb <- @lv_callbacks, kind <- [:stop, :exception] do
             [:phoenix, :live_view, cb, kind]
           end) ++
            [
              [:phoenix, :live_component, :handle_event, :stop],
              [:phoenix, :live_component, :handle_event, :exception],
              [:phoenix, :endpoint, :stop]
            ]

  @methods %{
    "GET" => :get,
    "HEAD" => :head,
    "POST" => :post,
    "PUT" => :put,
    "PATCH" => :patch,
    "DELETE" => :delete,
    "OPTIONS" => :options
  }

  @doc "The handler id this module attaches under."
  @spec handler_id() :: term()
  def handler_id, do: @handler_id

  @doc "The telemetry events handled."
  @spec events() :: [[atom()]]
  def events, do: @events

  @doc """
  Attach the handler. Options:

    * `:kms` — the `Samen.Kms` adapter for the actor pseudonym (default: the configured one).

  Returns `:ok` or `{:error, :already_exists}` (restart-safe).
  """
  @spec attach(keyword()) :: :ok | {:error, :already_exists}
  def attach(opts \\ []) do
    :telemetry.attach_many(@handler_id, @events, &__MODULE__.handle_event/4, %{
      kms: Keyword.get(opts, :kms)
    })
  end

  @doc "Detach the handler."
  @spec detach() :: :ok | {:error, :not_found}
  def detach, do: :telemetry.detach(@handler_id)

  @doc false
  # The telemetry callback. Never raises, never throws, never exits: a crashing handler
  # is detached by :telemetry, which would turn the plane dark for the rest of the node's life.
  def handle_event(event, measurements, metadata, config) do
    case build(event, measurements, metadata, config) do
      {:ok, fields} -> WideEvent.emit(fields, :build)
      :skip -> :ok
    end

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  @doc false
  # Pure-ish: the bounded field map for one telemetry event (exposed for tests).
  @spec build([atom()], map(), map(), map()) :: {:ok, map()} | :skip
  def build([:phoenix, :live_view, callback, kind], measurements, metadata, config)
      when callback in @lv_callbacks and kind in [:stop, :exception] do
    socket = Map.get(metadata, :socket)
    view = field(socket, :view)

    base = %{action: :live_view, callback: callback, outcome: outcome(kind)}

    base =
      if callback == :handle_event,
        do: Map.put(base, :event, LiveEvents.resolve(view, Map.get(metadata, :event))),
        else: base

    {:ok,
     base
     |> put_view(view)
     |> put_common(measurements, assigns(socket), config)}
  end

  def build([:phoenix, :live_component, :handle_event, kind], measurements, metadata, config)
      when kind in [:stop, :exception] do
    component = Map.get(metadata, :component)

    base = %{
      action: :live_component,
      callback: :component_event,
      outcome: outcome(kind),
      event: LiveEvents.resolve(component, Map.get(metadata, :event))
    }

    {:ok,
     base
     |> put_view(component)
     |> put_common(measurements, assigns(Map.get(metadata, :socket)), config)}
  end

  def build([:phoenix, :endpoint, :stop], measurements, metadata, config) do
    conn = Map.get(metadata, :conn)

    base = %{
      action: :http_request,
      callback: :request,
      outcome: :ok,
      method: Map.get(@methods, field(conn, :method), :other)
    }

    {:ok,
     base
     |> put_bounded(:status, status(field(conn, :status)))
     |> put_common(measurements, field(conn, :assigns), config)}
  end

  def build(_event, _measurements, _metadata, _config), do: :skip

  # ---------------------------------------------------------------------------

  defp outcome(:stop), do: :ok
  defp outcome(:exception), do: :exception

  defp put_view(fields, view) when is_atom(view) and view not in [nil, true, false],
    do: put_bounded(fields, :view, inspect(view))

  defp put_view(fields, _), do: fields

  defp put_common(fields, measurements, assigns, config) do
    assigns = if is_map(assigns), do: assigns, else: %{}

    fields
    |> put_bounded(:duration_ms, duration_ms(measurements))
    |> put_bounded(:tenant_id, tenant_id(Map.get(assigns, :org_id)))
    |> put_bounded(:actor_id, actor_id(Map.get(assigns, :samen_tenant_principal), config))
    |> put_bounded(:request_id, Logger.metadata()[:request_id])
    |> put_trace()
  end

  # Keep `value` only if it passes its declared bounded type on its own — so one bad value
  # drops one field, not the whole event.
  defp put_bounded(fields, _key, nil), do: fields

  defp put_bounded(fields, key, value) do
    case WideEvent.new(%{key => value, :action => :live_view}) do
      {:ok, _} -> Map.put(fields, key, value)
      {:error, _} -> fields
    end
  end

  defp field(map, key) when is_map(map), do: Map.get(map, key)
  defp field(_, _), do: nil

  defp assigns(socket), do: field(socket, :assigns)

  defp status(code) when is_integer(code), do: code
  defp status(_), do: nil

  defp duration_ms(%{duration: native}) when is_integer(native),
    do: System.convert_time_unit(native, :native, :microsecond) / 1000

  defp duration_ms(_), do: nil

  defp tenant_id(org_id) when is_binary(org_id) do
    case Ecto.UUID.cast(org_id) do
      {:ok, uuid} -> uuid
      :error -> nil
    end
  end

  defp tenant_id(_), do: nil

  # The HMAC pseudonym of the principal (`for_subject/2`), memoized per process: a LiveView
  # process computes it once, not per callback. `:none` caches "no live key" too.
  defp actor_id(principal, config) when is_binary(principal) and byte_size(principal) > 0 do
    key = {__MODULE__, :actor_id, principal}

    case Process.get(key) do
      nil ->
        value = pseudonym(principal, Map.get(config || %{}, :kms))
        Process.put(key, value || :none)
        value

      :none ->
        nil

      value ->
        value
    end
  end

  defp actor_id(_, _), do: nil

  defp pseudonym(principal, nil), do: pseudonym(principal, Samen.Kms.adapter())

  defp pseudonym(principal, kms) do
    case WideEvent.for_subject(principal, kms) do
      {:ok, actor_id} -> actor_id
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp put_trace(fields) do
    ctx = :otel_tracer.current_span_ctx()

    if :otel_span.is_valid(ctx) do
      fields
      |> put_bounded(:trace_id, to_string(:otel_span.hex_trace_id(ctx)))
      |> put_bounded(:span_id, to_string(:otel_span.hex_span_id(ctx)))
    else
      fields
    end
  rescue
    _ -> fields
  end
end
