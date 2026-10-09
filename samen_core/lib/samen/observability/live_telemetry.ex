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
    * `request_id` — the Logger metadata id, ONLY when this server generated it (see below);
      `trace_id` / `span_id` (the current OTel span, if any), `duration_ms`, and for a request
      `method` + `status`.

  ## `request_id` — server-generated ids only (ADR-052 §2.1.2 item 1)

  `Plug.RequestId` adopts any client `x-request-id` of 20–200 bytes, so the Logger metadata id
  can be a string the client chose. It lands in the event verbatim only when it provably came
  from `Plug.RequestId.generate/0` in THIS process: exactly 20 url-safe base64 characters that
  decode to its `<<nanos::64, phash2({node(), self()}, 2^24)::24, unique::32>>` layout with the
  process hash matching `self()`, and — for a request, where the conn is in the metadata — equal
  to no request-header value. That id is also the response header, so the event stays
  correlatable with it. Any other id is replaced by `sub_` + a keyed hash (HMAC-SHA256 under a
  random per-node key, 16 url-safe characters): bounded and server-shaped, still the same for
  every event carrying the same client id on this node, and never the client's bytes.

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
    # Mint the per-node request-id substitution key once, here, not racily on first use.
    _ = request_id_key()

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
      {:ok, fields} -> WideEvent.emit(fields, :best_effort)
      :skip -> :ok
    end

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  @doc false
  # Pure-ish: the field map for one telemetry event (exposed for tests). Values are validated
  # once, by `WideEvent.emit(fields, :best_effort)`, which drops any that fail their type.
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
     |> put_common(measurements, assigns(socket), nil, config)}
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
     |> put_common(measurements, assigns(Map.get(metadata, :socket)), nil, config)}
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
     |> put_present(:status, status(field(conn, :status)))
     |> put_common(measurements, field(conn, :assigns), conn, config)}
  end

  def build(_event, _measurements, _metadata, _config), do: :skip

  # ---------------------------------------------------------------------------

  defp outcome(:stop), do: :ok
  defp outcome(:exception), do: :exception

  defp put_view(fields, view) when is_atom(view) and view not in [nil, true, false],
    do: put_present(fields, :view, inspect(view))

  defp put_view(fields, _), do: fields

  defp put_common(fields, measurements, assigns, conn, config) do
    assigns = if is_map(assigns), do: assigns, else: %{}

    fields
    |> put_present(:duration_ms, duration_ms(measurements))
    |> put_present(:tenant_id, tenant_id(Map.get(assigns, :org_id)))
    |> put_present(:actor_id, actor_id(Map.get(assigns, :samen_tenant_principal), config))
    |> put_present(:request_id, request_id(Logger.metadata()[:request_id], conn))
    |> put_trace()
  end

  # Absent stays absent. Type validation happens ONCE, at emit (`:best_effort` drops a value
  # that fails its bounded type, so one bad value still drops one field, not the event).
  defp put_present(fields, _key, nil), do: fields
  defp put_present(fields, key, value), do: Map.put(fields, key, value)

  # ---------------------------------------------------------------------------
  # request_id provenance (ADR-052 §2.1.2 item 1)

  @doc false
  # The value the event carries for a Logger-metadata request id (exposed for tests).
  @spec request_id(term(), term()) :: String.t() | nil
  def request_id(id, conn) when is_binary(id) do
    if server_generated?(id, conn), do: id, else: substitute_request_id(id)
  end

  def request_id(_id, _conn), do: nil

  # `Plug.RequestId.generate/0`: url_encode64(<<nanos::64, phash2({node(), self()}, 2^24)::24,
  # unique_integer::32>>) — 15 bytes, exactly 20 characters, no padding.
  defp server_generated?(id, conn) when byte_size(id) == 20 do
    case Base.url_decode64(id) do
      {:ok, <<_nanos::64, process_hash::24, _unique::32>>} ->
        process_hash == :erlang.phash2({node(), self()}, 16_777_216) and
          not client_sent?(id, conn)

      _ ->
        false
    end
  end

  defp server_generated?(_id, _conn), do: false

  # For a request the conn is in hand: a value the client sent in ANY header is the client's,
  # whatever the header is called (`Plug.RequestId`'s `:http_header` is configurable).
  defp client_sent?(id, %{req_headers: headers}) when is_list(headers),
    do: Enum.any?(headers, &match?({_, ^id}, &1))

  defp client_sent?(_id, _conn), do: false

  defp substitute_request_id(id) do
    digest = :crypto.mac(:hmac, :sha256, request_id_key(), id)
    "sub_" <> Base.url_encode64(binary_part(digest, 0, 12), padding: false)
  end

  @request_id_key {__MODULE__, :request_id_key}

  defp request_id_key do
    case :persistent_term.get(@request_id_key, nil) do
      nil ->
        key = :crypto.strong_rand_bytes(32)
        :persistent_term.put(@request_id_key, key)
        key

      key ->
        key
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
      |> put_present(:trace_id, to_string(:otel_span.hex_trace_id(ctx)))
      |> put_present(:span_id, to_string(:otel_span.hex_span_id(ctx)))
    else
      fields
    end
  rescue
    _ -> fields
  end
end
