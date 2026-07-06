defmodule Samen.WideEvent.Sinks.File do
  @moduledoc """
  File wide-event sink: append one JSON line per event to a JSONL file, with
  **TTL pruning** on each write (doc §runs 4b "the sink is retained under a
  stated TTL").

  Each line is `{"emitted_at": <unix_seconds>, "event": {...}}`. On every write
  the adapter prunes lines whose `emitted_at` is older than
  `retention.ttl_seconds` — a deterministic, background-free prune suitable for
  dev/CI. (Production wide-event retention is the OTLP backend's job; this adapter
  is a local file sink for inspection + the TTL red-path test.)

  Attach with `attach/1`; the file path comes from
  `config :samen_core, :wide_event_file, path: "..."` or the `:path` option.
  """

  @behaviour Samen.WideEvent.Sink

  alias Samen.WideEvent
  alias Samen.WideEvent.Retention

  @handler_id {__MODULE__, :handler}

  @impl Samen.WideEvent.Sink
  def name, do: :file

  @doc "Attach the telemetry handler routing wide events to a JSONL file."
  @spec attach(keyword()) :: :ok | {:error, :already_exists}
  def attach(opts \\ []) do
    path = Keyword.get(opts, :path) || configured_path()
    retention = Keyword.get(opts, :retention, Retention.load())
    File.mkdir_p!(Path.dirname(path))

    :telemetry.attach(
      @handler_id,
      WideEvent.telemetry_event(),
      &__MODULE__.__handle__/4,
      %{path: path, retention: retention}
    )
  end

  @doc "Detach the telemetry handler."
  @spec detach() :: :ok | {:error, :not_found}
  def detach, do: :telemetry.detach(@handler_id)

  @doc false
  def __handle__(_event, measurements, metadata, %{path: path, retention: retention}) do
    ev = struct(WideEvent, Map.merge(measurements, metadata))
    handle_event(ev, retention, path)
  end

  @impl Samen.WideEvent.Sink
  def handle_event(%WideEvent{} = ev, %Retention{} = retention),
    do: handle_event(ev, retention, configured_path())

  @doc "Append `ev` to `path`, then prune lines older than the TTL."
  @spec handle_event(WideEvent.t(), Retention.t(), String.t()) :: :ok
  def handle_event(%WideEvent{} = ev, %Retention{} = retention, path) do
    now = System.system_time(:second)
    line = encode(ev, now)
    File.write!(path, line <> "\n", [:append])
    prune(path, retention, now)
    :ok
  end

  @doc """
  Read back the events currently in the file (post-prune), oldest-first.

  Returns a list of `%{emitted_at: unix, event: %WideEvent{}}` maps.
  """
  @spec read(String.t()) :: [map()]
  def read(path) do
    case File.read(path) do
      {:ok, contents} ->
        contents
        |> String.split("\n", trim: true)
        |> Enum.map(&decode/1)

      {:error, :enoent} ->
        []
    end
  end

  @doc """
  Prune lines older than `retention.ttl_seconds` relative to `now`. Rewrites the
  file with only the surviving lines. Returns the number of pruned lines.
  """
  @spec prune(String.t(), Retention.t(), integer()) :: non_neg_integer()
  def prune(path, %Retention{ttl_seconds: ttl}, now) do
    case File.read(path) do
      {:ok, contents} ->
        lines = String.split(contents, "\n", trim: true)
        cutoff = now - ttl

        {kept, pruned} =
          Enum.split_with(lines, fn line ->
            case Jason.decode(line) do
              {:ok, %{"emitted_at" => t}} -> t >= cutoff
              _ -> true
            end
          end)

        if pruned != [] do
          File.write!(path, Enum.join(kept, "\n") <> (if kept == [], do: "", else: "\n"))
        end

        length(pruned)

      {:error, :enoent} ->
        0
    end
  end

  # --- encode / decode -------------------------------------------------------

  defp encode(%WideEvent{} = ev, emitted_at) do
    payload = ev |> Map.from_struct() |> Enum.reject(fn {_k, v} -> is_nil(v) end) |> Map.new()
    Jason.encode!(%{emitted_at: emitted_at, event: payload})
  end

  defp decode(line) do
    %{"emitted_at" => t, "event" => ev} = Jason.decode!(line)
    %{emitted_at: t, event: struct(WideEvent, atomize(ev))}
  end

  defp atomize(map) do
    Map.new(map, fn {k, v} -> {String.to_existing_atom(k), atomize_value(k, v)} end)
  end

  # :action / :op are enum atoms in the struct; re-atomize them on read.
  defp atomize_value(k, v) when k in ["action", "op"] and is_binary(v),
    do: String.to_existing_atom(v)

  defp atomize_value(_k, v), do: v

  defp configured_path do
    :samen_core
    |> Application.get_env(:wide_event_file, [])
    |> Keyword.get(:path, Path.join(System.tmp_dir!(), "samen_wide_events.jsonl"))
  end
end
