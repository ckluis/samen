defmodule Samen.Replay.Buffer do
  @moduledoc """
  The in-flight replay buffer: ONE public ETS table, written by each recorded LiveView process
  for its own session (so recording never waits on another process), read back and cleared by
  `Samen.Replay.Monitor` when that process exits.

  Rows:

    * `{{:proc, pid}, session_id, started_mono_ms, max_frames, max_bytes}` — finds the session
      of the calling process (one lookup per event for an unrecorded LiveView);
    * `{{:meta, session_id}, pid, meta}` — the session's bounded metadata (org, actor
      pseudonym, view, view MD5, start time);
    * `{{:ctr, session_id}, seq, bytes, interactions, truncated}` — counters;
    * `{{:frame, session_id, seq}, frame}` — one per captured frame;
    * `{:sessions, n}` — live sessions on this node (the `max_sessions` memory cap).

  ## Caps — truncate, never crash

  A session stops storing frames once it has `max_frames` frames or `max_bytes` bytes (the
  external term size of the sanitized payloads). The first frame past a cap is replaced by ONE
  `:truncated` marker frame naming the cap; later frames are dropped (interactions are still
  counted, so the persist decision stays right). Every function here returns a value — a
  missing table (capture not running) is `:error`, never a raise into the LiveView.
  """

  @table :samen_replay_buffer

  @doc "The ETS table name."
  @spec table() :: atom()
  def table, do: @table

  @doc false
  # Created by `Samen.Replay.Monitor` (its owner) at start.
  @spec create_table() :: :ok
  def create_table do
    :ets.new(@table, [
      :named_table,
      :public,
      :set,
      write_concurrency: true,
      read_concurrency: true
    ])

    :ets.insert(@table, {:sessions, 0})
    :ok
  end

  @doc "Does the buffer table exist on this node?"
  @spec table_exists?() :: boolean()
  def table_exists?, do: :ets.whereis(@table) != :undefined

  @doc """
  Open a session for `pid`. Returns `{:ok, session_id}`, or `:full` when the node already holds
  `max_sessions` live sessions, or `:error` when capture is not running.
  """
  @spec open(pid(), map(), Samen.Replay.config()) :: {:ok, String.t()} | :full | :error
  def open(pid, meta, cfg) do
    if :ets.update_counter(@table, :sessions, {2, 1}) > cfg.max_sessions do
      :ets.update_counter(@table, :sessions, {2, -1})
      :full
    else
      id = Ecto.UUID.generate()

      :ets.insert(@table, [
        {{:meta, id}, pid, meta},
        {{:ctr, id}, 0, 0, 0, 0},
        {{:proc, pid}, id, System.monotonic_time(:millisecond), cfg.max_frames, cfg.max_bytes}
      ])

      {:ok, id}
    end
  rescue
    _ -> :error
  end

  @doc "The session id `pid` records, if any."
  @spec session(pid()) :: {:ok, String.t()} | :error
  def session(pid) do
    case :ets.lookup(@table, {:proc, pid}) do
      [{_, id, _, _, _}] -> {:ok, id}
      [] -> :error
    end
  rescue
    _ -> :error
  end

  @doc """
  Is `pid` recording AND still under its caps? Lets the recorder skip sanitizing a frame the
  buffer would drop (a truncated session costs one lookup per render, not a sanitize).
  """
  @spec accepting?(pid()) :: boolean()
  def accepting?(pid) do
    case :ets.lookup(@table, {:proc, pid}) do
      [{_, id, _, _, _}] -> match?([{_, _, _, _, 0}], :ets.lookup(@table, {:ctr, id}))
      [] -> false
    end
  rescue
    _ -> false
  end

  @doc """
  Append a frame for the session `pid` records. `interaction?` counts a user interaction (an
  event) — the persist decision. Returns `:ok`, `:truncated` (a cap was hit), or `:error`
  (no session / capture not running).
  """
  @spec record(pid(), atom(), map(), boolean()) :: :ok | :truncated | :error
  def record(pid, kind, payload, interaction? \\ false) do
    case :ets.lookup(@table, {:proc, pid}) do
      [{_, id, started, max_frames, max_bytes}] ->
        if interaction?, do: :ets.update_counter(@table, {:ctr, id}, {4, 1})
        write(id, started, max_frames, max_bytes, kind, payload)

      [] ->
        :error
    end
  rescue
    _ -> :error
  end

  defp write(id, started, max_frames, max_bytes, kind, payload) do
    [{_, _seq, _bytes, _interactions, truncated}] = :ets.lookup(@table, {:ctr, id})
    at = System.monotonic_time(:millisecond) - started

    if truncated > 0 do
      :truncated
    else
      size = :erlang.external_size(payload)
      [seq, bytes] = :ets.update_counter(@table, {:ctr, id}, [{2, 1}, {3, size}])

      cap =
        cond do
          seq > max_frames -> :max_frames
          bytes > max_bytes -> :max_bytes
          true -> nil
        end

      if cap do
        :ets.update_counter(@table, {:ctr, id}, {5, 1})
        :ets.insert(@table, {{:frame, id, seq}, {seq, at, :truncated, %{cap: cap}}})
        :truncated
      else
        :ets.insert(@table, {{:frame, id, seq}, {seq, at, kind, payload}})
        :ok
      end
    end
  end

  @doc """
  Stop recording for `pid`: its process row goes, so `record/4`, `accepting?/1` and
  `session/1` answer as for an unrecorded process. The session's meta, counters and frames
  stay for the monitor's `take/1`.
  """
  @spec stop(pid()) :: :ok
  def stop(pid) do
    :ets.delete(@table, {:proc, pid})
    :ok
  rescue
    _ -> :ok
  end

  @doc """
  Remove the session `id` from the buffer and return it:
  `{:ok, meta, frames_in_seq_order, counters}` or `:error`. Called by the monitor, once.
  """
  @spec take(String.t()) :: {:ok, map(), list(), map()} | :error
  def take(id) do
    case :ets.take(@table, {:meta, id}) do
      [{_, pid, meta}] ->
        :ets.delete(@table, {:proc, pid})
        [{_, seq, bytes, interactions, truncated}] = :ets.take(@table, {:ctr, id})

        frames =
          @table
          |> :ets.match_object({{:frame, id, :_}, :_})
          |> Enum.map(fn {key, frame} ->
            :ets.delete(@table, key)
            frame
          end)
          |> Enum.sort_by(&elem(&1, 0))

        :ets.update_counter(@table, :sessions, {2, -1})

        {:ok, meta, frames,
         %{
           frames: min(seq, length(frames)),
           bytes: bytes,
           interactions: interactions,
           truncated: truncated > 0
         }}

      [] ->
        :error
    end
  rescue
    _ -> :error
  end

  @doc "Ids of every session currently buffered (monitor recovery)."
  @spec sessions() :: [{String.t(), pid()}]
  def sessions do
    @table |> :ets.match({{:meta, :"$1"}, :"$2", :_}) |> Enum.map(fn [id, pid] -> {id, pid} end)
  rescue
    _ -> []
  end
end
