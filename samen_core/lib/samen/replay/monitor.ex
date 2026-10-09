defmodule Samen.Replay.Monitor do
  @moduledoc """
  Follows each recorded LiveView from its first frame to storage (ADR-052 §2.2).

  Owns the `Samen.Replay.Buffer` table. `watch/2` monitors a recording LiveView process; when
  it exits, the monitor records a bounded `:exit` frame (`normal | shutdown | killed | crash`
  — never the exit term, which can carry the very value being processed), takes the session
  out of the buffer, and — in a supervised task, off the monitor's own loop — persists it
  through `Samen.Replay.Store` when it saw at least one user interaction. A session with none
  is discarded. Persist failures are logged (bounded reason) and dropped; they never reach the
  LiveView, which has already exited.
  """
  use GenServer

  require Logger

  alias Samen.Replay.{Buffer, Store}

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Monitor the recording process `pid` for session `id`."
  @spec watch(pid(), String.t()) :: :ok
  def watch(pid, id), do: GenServer.cast(__MODULE__, {:watch, pid, id})

  @doc false
  # Test seam: wait until every queued finalization has run (synchronous drain).
  @spec flush(timeout()) :: :ok
  def flush(timeout \\ 5_000), do: GenServer.call(__MODULE__, :flush, timeout)

  @impl true
  def init(opts) do
    Buffer.create_table()
    {:ok, %{refs: %{}, tasks: %{}, waiting: [], task_sup: Keyword.fetch!(opts, :task_sup)}}
  end

  @impl true
  def handle_cast({:watch, pid, id}, state) do
    ref = Process.monitor(pid)
    {:noreply, %{state | refs: Map.put(state.refs, ref, id)}}
  end

  @impl true
  def handle_call(:flush, from, state) do
    if map_size(state.refs) == 0 and map_size(state.tasks) == 0 do
      {:reply, :ok, state}
    else
      {:noreply, %{state | waiting: [from | state.waiting]}}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{refs: refs} = state)
      when is_map_key(refs, ref) do
    {id, refs} = Map.pop(refs, ref)

    task =
      Task.Supervisor.async_nolink(state.task_sup, fn -> finalize(id, exit_reason(reason)) end)

    {:noreply, maybe_reply(%{state | refs: refs, tasks: Map.put(state.tasks, task.ref, id)})}
  end

  def handle_info({ref, _result}, %{tasks: tasks} = state) when is_map_key(tasks, ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, maybe_reply(%{state | tasks: Map.delete(tasks, ref)})}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{tasks: tasks} = state)
      when is_map_key(tasks, ref) do
    {:noreply, maybe_reply(%{state | tasks: Map.delete(tasks, ref)})}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp maybe_reply(%{refs: refs, tasks: tasks, waiting: [_ | _] = waiting} = state)
       when map_size(refs) == 0 and map_size(tasks) == 0 do
    Enum.each(waiting, &GenServer.reply(&1, :ok))
    %{state | waiting: []}
  end

  defp maybe_reply(state), do: state

  @doc false
  # The bounded exit enum — the exit term itself is never recorded.
  @spec exit_reason(term()) :: :normal | :shutdown | :killed | :crash
  def exit_reason(:normal), do: :normal
  def exit_reason(:shutdown), do: :shutdown
  def exit_reason({:shutdown, _}), do: :shutdown
  def exit_reason(:killed), do: :killed
  def exit_reason(_), do: :crash

  @doc false
  @spec finalize(String.t(), atom()) :: :persisted | :discarded | :error
  def finalize(id, reason) do
    case Buffer.take(id) do
      {:ok, meta, frames, counters} ->
        if counters.interactions > 0 do
          persist(meta, frames, counters, reason)
        else
          :telemetry.execute([:samen, :replay, :discarded], %{frames: length(frames)}, %{})
          :discarded
        end

      :error ->
        :error
    end
  rescue
    e ->
      Logger.error("[Samen.Replay] finalize failed: #{inspect(e.__struct__)}")
      :error
  end

  defp persist(meta, frames, counters, reason) do
    case Store.persist(meta, frames, Map.put(counters, :exit_reason, reason)) do
      {:ok, _session} ->
        :telemetry.execute([:samen, :replay, :persisted], %{frames: length(frames)}, %{})
        :persisted

      {:error, kind} ->
        Logger.error("[Samen.Replay] persist failed: #{inspect(kind)}")
        :error
    end
  end
end
