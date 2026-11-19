defmodule Samen.WebTest.OwnLog do
  @moduledoc """
  Capture the log lines emitted BY THE CALLING PROCESS ONLY.

  `ExUnit.CaptureLog.capture_log/1` captures every log line the node emits while it runs, so in an `async: true`
  suite a line from another test's process (a different test module running at the same time) leaks into the capture:
  an assertion that "this call logged nothing" then fails intermittently on someone else's log. Logger stamps each
  event with the emitting `pid`; this installs a `:logger` handler that keeps only events whose `pid` is the caller's.

      {result, log} = Samen.WebTest.OwnLog.capture(fn -> render_component(...) end)

  Only valid for code that logs from the calling process itself (a function call, `render_component/2`); a log
  emitted from a process the code spawns is not seen. Use `capture_log` for that.
  """

  @doc "Run `fun`; return `{result, log}` where `log` holds only the lines logged by the calling process."
  @spec capture((-> result)) :: {result, String.t()} when result: term()
  def capture(fun) when is_function(fun, 0) do
    ref = make_ref()
    id = :"own_log_#{System.unique_integer([:positive])}"
    me = self()
    collector = spawn_link(fn -> collect(me, ref, []) end)

    :ok =
      :logger.add_handler(id, __MODULE__.Handler, %{level: :all, config: %{pid: me, collector: collector}})

    try do
      fun.()
    else
      result -> {result, flush(collector, ref)}
    after
      :logger.remove_handler(id)
    end
  end

  defp flush(collector, ref) do
    send(collector, {:flush, ref})

    receive do
      {^ref, lines} -> lines |> Enum.reverse() |> Enum.join("\n")
    after
      5_000 -> raise "OwnLog collector did not answer"
    end
  end

  defp collect(owner, ref, acc) do
    receive do
      {:line, line} -> collect(owner, ref, [line | acc])
      {:flush, ^ref} -> send(owner, {ref, acc})
    end
  end

  defmodule Handler do
    @moduledoc false

    # `:logger` handler callback: runs in the EMITTING process, so `self()` is the process that logged.
    def log(%{meta: meta} = event, %{config: %{pid: pid, collector: collector}}) do
      if Map.get(meta, :pid, self()) == pid, do: send(collector, {:line, format(event)})
      :ok
    end

    defp format(%{msg: {:string, chardata}}), do: IO.chardata_to_string(chardata)
    defp format(%{msg: {:report, report}}), do: inspect(report)

    defp format(%{msg: {format, args}}) do
      format |> :io_lib.format(args) |> IO.chardata_to_string()
    end
  end
end
