defmodule Samen.WideEvent.Sinks.InMemory do
  @moduledoc """
  In-memory wide-event sink: a **bounded ring buffer** (doc §runs 4b TTL /
  blast-radius).

  A `GenServer` holding at most `retention.max_events` most-recent events. Oldest
  events are dropped when the cap is hit — the buffer NEVER grows without bound
  (an unbounded telemetry buffer is its own outage). Primarily for tests and dev
  inspection; production uses the OTLP adapter.

  Attach it with `attach/1` (registers the `[:samen, :wide_event]` telemetry
  handler), read with `events/0`, clear with `reset/0`.
  """

  use GenServer
  @behaviour Samen.WideEvent.Sink

  alias Samen.WideEvent
  alias Samen.WideEvent.Retention

  @handler_id {__MODULE__, :handler}

  @impl Samen.WideEvent.Sink
  def name, do: :in_memory

  # --- lifecycle -------------------------------------------------------------

  @doc "Start the in-memory sink. `:retention` and `:name` opts accepted."
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    retention = Keyword.get(opts, :retention, Retention.load())
    GenServer.start_link(__MODULE__, retention, name: name)
  end

  @doc "Attach the telemetry handler that routes wide events into this sink."
  @spec attach(GenServer.server()) :: :ok | {:error, :already_exists}
  def attach(server \\ __MODULE__) do
    :telemetry.attach(
      @handler_id,
      WideEvent.telemetry_event(),
      &__MODULE__.__handle__/4,
      %{server: server}
    )
  end

  @doc "Detach the telemetry handler."
  @spec detach() :: :ok | {:error, :not_found}
  def detach, do: :telemetry.detach(@handler_id)

  @doc "The most-recent events, oldest-first."
  @spec events(GenServer.server()) :: [WideEvent.t()]
  def events(server \\ __MODULE__), do: GenServer.call(server, :events)

  @doc "Clear the buffer."
  @spec reset(GenServer.server()) :: :ok
  def reset(server \\ __MODULE__), do: GenServer.call(server, :reset)

  # --- telemetry handler -----------------------------------------------------

  @doc false
  def __handle__(_event, measurements, metadata, %{server: server}) do
    ev = struct(WideEvent, Map.merge(measurements, metadata))
    GenServer.cast(server, {:event, ev})
  end

  @impl Samen.WideEvent.Sink
  def handle_event(%WideEvent{} = ev, _retention), do: GenServer.cast(__MODULE__, {:event, ev})

  # --- GenServer -------------------------------------------------------------

  @impl GenServer
  def init(%Retention{} = retention) do
    {:ok, %{retention: retention, buffer: :queue.new(), size: 0}}
  end

  @impl GenServer
  def handle_cast({:event, ev}, state) do
    buffer = :queue.in(ev, state.buffer)
    size = state.size + 1

    {buffer, size} =
      if size > state.retention.max_events do
        {{:value, _dropped}, trimmed} = :queue.out(buffer)
        {trimmed, size - 1}
      else
        {buffer, size}
      end

    {:noreply, %{state | buffer: buffer, size: size}}
  end

  @impl GenServer
  def handle_call(:events, _from, state) do
    {:reply, :queue.to_list(state.buffer), state}
  end

  def handle_call(:reset, _from, state) do
    {:reply, :ok, %{state | buffer: :queue.new(), size: 0}}
  end
end
