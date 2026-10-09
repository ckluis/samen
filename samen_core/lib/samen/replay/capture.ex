defmodule Samen.Replay.Capture do
  @moduledoc """
  The capture entry points the recorder and LiveView's own telemetry use (ADR-052 §2.2).

    * `open/1` — called by the recorder (`Samen.Web.Replay.Recorder`) from the LiveView process
      once the org is known and capture is decided ON: opens the buffer session, records the
      session actor ONLY as the P1 HMAC pseudonym (`Samen.WideEvent.for_subject/2`), the view
      module and its MD5 (for P3's code-drift marker), and asks the monitor to watch.
    * `record/3` — append a frame (the recorder's mount / params / render / info frames).
    * `handle_event/4` — a `:telemetry` handler on
      `[:phoenix, :live_view | :live_component, :handle_event, :start]`. `:start` fires before
      any `on_mount` hook can halt the event, so a halted event is still recorded. It runs in
      the LiveView process: an unrecorded LiveView pays one ETS lookup. The event name is the
      bounded label (`Samen.Replay.event_label/3`), the params their SHAPE
      (`Samen.Replay.Sanitizer.params/2`), with values only for declared keep-list keys.

  Every function here returns normally whatever it is handed: `:telemetry` detaches a handler
  that raises, and a recorder must never crash the LiveView it observes.
  """

  alias Samen.Replay.{Buffer, Monitor, Sanitizer}

  @handler_id {__MODULE__, :events}
  @events [
    [:phoenix, :live_view, :handle_event, :start],
    [:phoenix, :live_component, :handle_event, :start]
  ]

  @doc "The handler id."
  @spec handler_id() :: term()
  def handler_id, do: @handler_id

  @doc "The telemetry events handled."
  @spec events() :: [[atom()]]
  def events, do: @events

  @doc "Attach the event handler (restart-safe)."
  @spec attach() :: :ok | {:error, :already_exists}
  def attach, do: :telemetry.attach_many(@handler_id, @events, &__MODULE__.handle_event/4, nil)

  @doc "Detach the event handler."
  @spec detach() :: :ok | {:error, :not_found}
  def detach, do: :telemetry.detach(@handler_id)

  @doc """
  Open a capture session for the calling LiveView process. `attrs`: `:org_id` (UUID),
  `:principal` (the session principal id — stored only as its pseudonym), `:view` (module).
  Returns `{:ok, session_id}` or `:error` (capture not running, node session cap reached).
  """
  @spec open(map()) :: {:ok, String.t()} | :error
  def open(%{org_id: org_id, view: view} = attrs) do
    with %{} = cfg <- Samen.Replay.runtime_config(),
         {:ok, id} <-
           Buffer.open(
             self(),
             %{
               org_id: org_id,
               actor_ref: pseudonym(Map.get(attrs, :principal)),
               view: inspect(view),
               view_md5: md5(view),
               started_at: DateTime.utc_now(),
               started_mono: System.monotonic_time(:millisecond)
             },
             cfg
           ) do
      Monitor.watch(self(), id)
      {:ok, id}
    else
      _ -> :error
    end
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  @doc "Append a frame for the calling process's session."
  @spec record(atom(), map(), boolean()) :: :ok | :truncated | :error
  def record(kind, payload, interaction? \\ false),
    do: Buffer.record(self(), kind, payload, interaction?)

  @doc """
  Stop recording the calling process: later frames and events are not captured. The frames
  already buffered stay, and persist when the process exits (the monitor finalizes by session).
  """
  @spec stop() :: :ok
  def stop, do: Buffer.stop(self())

  @doc "Is the calling process recording and under its caps (worth sanitizing a frame for)?"
  @spec accepting?() :: boolean()
  def accepting?, do: Buffer.accepting?(self())

  @doc "Is the calling process recording?"
  @spec recording?() :: boolean()
  def recording?, do: match?({:ok, _}, Buffer.session(self()))

  @doc false
  def handle_event(event, _measurements, metadata, _config) do
    capture(event, metadata)
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp capture([:phoenix, :live_view, :handle_event, :start], %{socket: socket, event: ev} = meta) do
    if recording?() do
      view = Map.get(socket, :view)
      keep = keep(view)
      label = Samen.Replay.event_label(view, ev, keep)
      params = Sanitizer.params(Map.get(meta, :params), Map.get(keep.params, label, []))
      record(:event, %{event: label, params: params}, true)
    end
  end

  defp capture(
         [:phoenix, :live_component, :handle_event, :start],
         %{component: mod, event: ev} = meta
       ) do
    if recording?() do
      keep = keep(mod)
      label = Samen.Replay.event_label(mod, ev, keep)
      params = Sanitizer.params(Map.get(meta, :params), Map.get(keep.params, label, []))

      record(
        :component_event,
        %{component: component_name(mod), event: label, params: params},
        true
      )
    end
  end

  defp capture(_event, _metadata), do: :ok

  defp component_name(mod) do
    name = inspect(mod)
    if Samen.Replay.FrameSchema.module_name?(name), do: name
  end

  # The keep declaration, memoized per process (a view module never changes in a process).
  @doc false
  @spec keep(module()) :: map()
  def keep(module) do
    key = {__MODULE__, :keep, module}

    case Process.get(key) do
      nil ->
        value = Samen.Replay.keep(module)
        Process.put(key, value)
        value

      value ->
        value
    end
  end

  @doc false
  @spec md5(module()) :: String.t() | nil
  def md5(module) when is_atom(module) do
    if Code.ensure_loaded?(module),
      do: module.module_info(:md5) |> Base.encode16(case: :lower),
      else: nil
  rescue
    _ -> nil
  end

  def md5(_), do: nil

  # The session actor, as the P1 HMAC pseudonym only (`HMAC(psk_S, subject_id)` — unlinkable
  # on shred). No live subject key → no actor recorded.
  defp pseudonym(principal) when is_binary(principal) and byte_size(principal) > 0 do
    case Samen.WideEvent.for_subject(principal, Samen.Kms.adapter()) do
      {:ok, ref} -> ref
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp pseudonym(_), do: nil
end
