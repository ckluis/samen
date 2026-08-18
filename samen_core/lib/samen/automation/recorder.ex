defmodule Samen.Automation.Recorder do
  @moduledoc """
  The E8 Reactor middleware (ADR-039 §8.1) — step timings captured "without
  action code knowing about the log". `Samen.Automation.Compile` attaches this
  to every built reactor; it annotates each per-action outcome with
  `duration_ms` before the outcome list reaches `Samen.Automation.RunRecord`.

  ## Why the process dictionary, not the Reactor `context`

  `Reactor.Middleware.event/3` is a read-only observer callback (`:: :ok`) — it
  cannot thread state back into the reactor's `context` for a later callback to
  read. `Samen.Automation.Compile.run/2` always runs synchronously
  (`async?: false` at both the reactor and every step, ADR-039 §5.1's "one
  Reactor step = one automation action" over a strictly ordered chain), so every
  middleware callback for one run fires in the SAME process — the process
  dictionary is a safe, private, per-run scratch space here (never read by
  action code, never persisted itself).

  ## What it does NOT do

  It never inspects an action's arguments or result VALUES — only step
  `name`/timestamps. The per-action outcome map itself (kind/status/error_kind/
  meta) is entirely `Samen.Automation.ActionStep`'s concern; this middleware
  only adds `duration_ms` by index-matching on `complete/2`.
  """
  use Reactor.Middleware

  @pdict_key :samen_automation_recorder_timings

  @impl true
  def init(context) do
    Process.put(@pdict_key, %{})
    {:ok, context}
  end

  @impl true
  def event({:run_start, _args}, %{name: name}, _context) do
    stamp(name, :start)
    :ok
  end

  def event({:run_complete, _result}, %{name: name}, _context) do
    stamp(name, :stop)
    :ok
  end

  def event({:run_error, _error}, %{name: name}, _context) do
    stamp(name, :stop)
    :ok
  end

  def event(_other_event, _step, _context), do: :ok

  @impl true
  def complete(result, _context) when is_list(result) do
    timings = Process.get(@pdict_key, %{})

    annotated =
      Enum.map(result, fn
        %{index: index} = outcome ->
          Map.put(outcome, :duration_ms, step_duration_ms(timings, :"action_#{index}"))

        other ->
          other
      end)

    {:ok, annotated}
  end

  def complete(result, _context), do: {:ok, result}

  # ---------------------------------------------------------------------------

  defp stamp(name, key) do
    timings = Process.get(@pdict_key, %{})
    step = Map.get(timings, name, %{})
    Process.put(@pdict_key, Map.put(timings, name, Map.put(step, key, System.monotonic_time(:millisecond))))
  end

  defp step_duration_ms(timings, name) do
    case Map.get(timings, name) do
      %{start: start, stop: stop} -> max(stop - start, 0)
      _ -> nil
    end
  end
end
