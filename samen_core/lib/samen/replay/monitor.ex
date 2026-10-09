defmodule Samen.Replay.Monitor do
  @moduledoc """
  Follows each recorded LiveView from its first frame to storage (ADR-052 §2.2).

  Owns the `Samen.Replay.Buffer` table. `watch/2` monitors a recording LiveView process; when
  it exits, the monitor records a bounded `:exit` frame (`normal | shutdown | killed | crash`
  — never the exit term, which can carry the very value being processed), takes the session
  out of the buffer, and — in a supervised task, off the monitor's own loop — persists it
  through `Samen.Replay.Store` when it saw at least one user interaction. A session with none
  is discarded. Persist failures never reach the LiveView, which has already exited.

  ## Bounded, counted (ADR-052 §2.4.1)

  The persist tasks run under `Samen.Replay.TaskSupervisor`, whose `max_children` is the
  capture config's `max_persist_tasks` (default 16). When that many persists are already in
  flight the session is DROPPED (its buffer row freed) and counted — the monitor never waits
  for a slot, so nothing upstream (the recording LiveViews' casts) ever queues behind a slow
  database. Every outcome is counted: `stats/0` (this node, since the monitor started) and one
  `[:samen, :replay, :session]` telemetry event per session with a bounded `result`
  (`:persisted | :discarded | :failed | :dropped`), the `samen.replay.session.count` metric
  in `Samen.Metrics`. A failure is never only a log line.
  """
  use GenServer

  require Logger

  alias Samen.Replay.{Buffer, Store}

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Monitor the recording process `pid` for session `id`."
  @spec watch(pid(), String.t()) :: :ok
  def watch(pid, id), do: GenServer.cast(__MODULE__, {:watch, pid, id})

  @results [:persisted, :discarded, :failed, :dropped]

  @doc "The bounded session outcomes counted by `stats/0` and the telemetry event."
  @spec results() :: [atom()]
  def results, do: @results

  @doc """
  Session outcomes on this node since the monitor started:
  `%{persisted: n, discarded: n, failed: n, dropped: n}`.
  """
  @spec stats() :: %{atom() => non_neg_integer()}
  def stats, do: GenServer.call(__MODULE__, :stats)

  @doc false
  # Test seam: wait until every queued finalization has run (synchronous drain).
  @spec flush(timeout()) :: :ok
  def flush(timeout \\ 5_000), do: GenServer.call(__MODULE__, :flush, timeout)

  @impl true
  def init(opts) do
    Buffer.create_table()

    {:ok,
     %{
       refs: %{},
       tasks: %{},
       waiting: [],
       task_sup: Keyword.fetch!(opts, :task_sup),
       counts: Map.new(@results, &{&1, 0})
     }}
  end

  @impl true
  def handle_cast({:watch, pid, id}, state) do
    ref = Process.monitor(pid)
    {:noreply, %{state | refs: Map.put(state.refs, ref, id)}}
  end

  @impl true
  def handle_call(:stats, _from, state), do: {:reply, state.counts, state}

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
    state = %{state | refs: refs}

    case start_finalize(state.task_sup, id, exit_reason(reason)) do
      {:ok, task} ->
        {:noreply, maybe_reply(%{state | tasks: Map.put(state.tasks, task.ref, id)})}

      :max_children ->
        # Over the bound: drop the session (free its buffer row) and count it. Never wait.
        _ = Buffer.take(id)
        {:noreply, maybe_reply(count(state, :dropped))}
    end
  end

  def handle_info({ref, result}, %{tasks: tasks} = state) when is_map_key(tasks, ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, maybe_reply(count(%{state | tasks: Map.delete(tasks, ref)}, outcome(result)))}
  end

  # A finalize task that died before replying (it rescues, so this is a kill or a link exit).
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{tasks: tasks} = state)
      when is_map_key(tasks, ref) do
    {:noreply, maybe_reply(count(%{state | tasks: Map.delete(tasks, ref)}, :failed))}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # `async_nolink` RAISES once the task supervisor is at `max_children`; the monitor must not
  # crash on it (it owns every in-flight session's buffer).
  defp start_finalize(task_sup, id, reason) do
    {:ok, Task.Supervisor.async_nolink(task_sup, fn -> finalize(id, reason) end)}
  rescue
    RuntimeError -> :max_children
  end

  defp outcome(:persisted), do: :persisted
  defp outcome(:discarded), do: :discarded
  defp outcome(_), do: :failed

  defp count(state, result) do
    :telemetry.execute([:samen, :replay, :session], %{count: 1}, %{result: result})
    %{state | counts: Map.update!(state.counts, result, &(&1 + 1))}
  end

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

      # No buffer row: recording was stopped on purpose (an org switch, R11) — nothing to keep.
      :error ->
        :discarded
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
