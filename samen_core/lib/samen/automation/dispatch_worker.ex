defmodule Samen.Automation.DispatchWorker do
  @moduledoc """
  E1 dispatch (ADR-039 §3.3, §4.3) — the fan-out job. Given a trigger envelope, it
  finds the active workflows that match and enqueues one `Samen.Automation.RunWorker`
  per match (Oban-unique on `{workflow_id, event_id}`, the §4.6 tier-1 dedupe: a
  retried DispatchWorker cannot double-enqueue a run).

  Queue `:automation`, `max_attempts 1` — the next event/scan is the retry, not this
  job (ADR-039 §4.3). Enqueued from three sources with the same envelope shape:
  resource-event capture (§4.2), the schedule scan (§4.1), and manual "Run now" (§4.1).

  ## Kill-switch (first of two checks — ADR-039 §8.4)

  Dispatch enqueues NO run for a workflow that is not `status == :active` or has
  `disabled_by_operator_at` set (both switches). This is the "no new runs enqueued"
  half; `RunWorker` re-checks at run start (the already-queued half).

  ## Loop + depth guards (ADR-039 §4.7 guards 1-2)

  A candidate workflow whose id already appears in the envelope `chain` is skipped
  (`:loop` — a workflow can never re-fire itself transitively); an envelope past the
  `automation_max_depth` cap is skipped (`:depth_exceeded`). T39 records these as
  no-enqueue skips; T42 makes them visible Run rows.
  """
  use Oban.Worker, queue: :automation, max_attempts: 1

  require Logger
  import Ash.Query

  alias Samen.Automation
  alias Samen.Automation.{RunRecord, RunWorker}

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    case Automation.workflow_module() do
      nil -> :ok
      workflow_mod -> dispatch(workflow_mod, args)
    end
  end

  defp dispatch(workflow_mod, args) do
    trigger_kind = args["trigger_kind"] || "resource_event"

    workflow_mod
    |> matching_workflows(args, trigger_kind)
    |> Enum.each(fn wf -> maybe_enqueue_run(wf, args) end)

    :ok
  rescue
    e ->
      Logger.warning("[Automation.DispatchWorker] dispatch raised: #{Exception.message(e)}")
      {:error, e}
  end

  # resource_event: match the org's active workflows for this resource_key + event.
  defp matching_workflows(mod, args, "resource_event") do
    mod
    |> filter(org_id == ^args["org_id"])
    |> filter(resource_key == ^args["resource_key"])
    |> filter(trigger_kind == :resource_event)
    |> filter(event == ^event_atom(args["event"]))
    |> filter(status == :active)
    |> filter(is_nil(disabled_by_operator_at))
    |> Ash.read!(authorize?: false)
  end

  # schedule / manual: the envelope names the single workflow directly; still honor
  # the kill-switch at dispatch.
  defp matching_workflows(mod, args, _schedule_or_manual) do
    case args["workflow_id"] do
      nil ->
        []

      wid ->
        mod
        |> filter(id == ^wid)
        |> filter(status == :active)
        |> filter(is_nil(disabled_by_operator_at))
        |> Ash.read!(authorize?: false)
    end
  end

  defp maybe_enqueue_run(wf, args) do
    chain = List.wrap(args["chain"] || [])
    depth = args["depth"] || 0

    cond do
      to_string(wf.id) in Enum.map(chain, &to_string/1) ->
        # :loop — a workflow cannot re-fire itself transitively. No RunWorker
        # job is ever enqueued for this guard, so record the skip directly
        # (ADR-039 §8.1 "T39 records these as no-enqueue skips; T42 makes them
        # visible Run rows").
        record_no_enqueue_skip(wf, args, :loop)

      depth > Automation.max_depth() ->
        # :depth_exceeded — bounded cascades only.
        record_no_enqueue_skip(wf, args, :depth_exceeded)

      true ->
        run_args =
          args
          |> Map.put("workflow_id", to_string(wf.id))
          |> Map.put_new("event_id", Ecto.UUID.generate())

        case Oban.insert(RunWorker.new(run_args)) do
          {:ok, _job} -> :ok
          {:error, reason} -> Logger.warning("[Automation.DispatchWorker] run enqueue failed: #{inspect(reason)}")
        end
    end
  end

  # No RunWorker job exists for these guards (the loop/depth cap fires BEFORE
  # enqueue) — write the terminal Run row directly. `event_id` defaults exactly
  # like the enqueue path so the dispatch_key is stable/reproducible.
  defp record_no_enqueue_skip(wf, args, reason) do
    args = Map.put_new(args, "event_id", Ecto.UUID.generate())
    run = RunRecord.open!(wf, args)
    RunRecord.skip!(run, reason)
    :ok
  end

  defp event_atom("created"), do: :created
  defp event_atom("updated"), do: :updated
  defp event_atom("destroyed"), do: :destroyed
  defp event_atom(e) when is_atom(e), do: e

  defp event_atom(other) do
    String.to_existing_atom(other)
  rescue
    ArgumentError -> :created
  end
end
