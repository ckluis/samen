defmodule Samen.Automation.ScheduleAdvance do
  @moduledoc """
  The body of the `:dispatch_due` update action driven by the Workflow's AshOban
  `:schedule_scan` trigger (ADR-039 §4.1(2), §4.3). Per due workflow it:

    1. **Advances `next_fire_at`** to the next occurrence of the tenant's
       `schedule_cron`, computed with `Oban.Cron.Expression` (already in the tree — no
       new dep), so the same workflow is not re-scheduled until its next cron minute.
    2. **Enqueues one `DispatchWorker`** (trigger_kind `:schedule`) inside the update's
       transaction — the same in-txn insert discipline as event capture.

  The idempotency net is the run-level Oban uniqueness (`{workflow_id, event_id}`,
  §4.6 tier 1): even if the scan runs twice in a minute, the resulting run dedupes.
  This is a system maintenance action (bypass-authorized), streamed per-record by
  AshOban — it never reads across orgs.
  """
  use Ash.Resource.Change

  require Logger

  alias Samen.Automation.DispatchWorker

  @impl true
  def change(changeset, _opts, _context) do
    changeset
    |> advance()
    |> Ash.Changeset.after_action(fn cs, result ->
      org_id = resolve_org_id(cs, result)
      enqueue_dispatch(result, org_id)
      {:ok, result}
    end)
  end

  # org_id is a universal column not selected by default on the scan read — resolve it
  # from the changeset/data, else reload by id (same posture as EventCapture).
  defp resolve_org_id(changeset, result) do
    [Ash.Changeset.get_attribute(changeset, :org_id), Map.get(result, :org_id)]
    |> Enum.find(&usable?/1)
    |> case do
      nil -> reload_org_id(changeset.resource, Map.get(result, :id))
      val -> val
    end
  end

  defp reload_org_id(_resource, nil), do: nil

  defp reload_org_id(resource, id) do
    import Ash.Query

    resource
    |> filter(id == ^id)
    |> Ash.Query.ensure_selected([:org_id])
    |> Ash.read!(authorize?: false)
    |> case do
      [r | _] -> Map.get(r, :org_id)
      [] -> nil
    end
  rescue
    _ -> nil
  end

  defp usable?(%Ash.NotLoaded{}), do: false
  defp usable?(nil), do: false
  defp usable?(_), do: true

  defp advance(changeset) do
    cron = Ash.Changeset.get_data(changeset, :schedule_cron)

    case next_fire(cron) do
      nil -> changeset
      dt -> Ash.Changeset.force_change_attribute(changeset, :next_fire_at, dt)
    end
  end

  defp next_fire(cron) when is_binary(cron) and cron != "" do
    with {:ok, expr} <- Oban.Cron.Expression.parse(cron),
         %DateTime{} = dt <- Oban.Cron.Expression.next_at(expr, DateTime.utc_now()) do
      DateTime.truncate(dt, :second)
    else
      _ -> DateTime.utc_now() |> DateTime.add(60, :second) |> DateTime.truncate(:second)
    end
  end

  defp next_fire(_), do: nil

  defp enqueue_dispatch(wf, org_id) do
    envelope = %{
      "org_id" => to_string(org_id),
      "workflow_id" => to_string(wf.id),
      "resource_key" => wf.resource_key,
      "subject_ref" => "samen:workflow:#{wf.id}",
      "trigger_kind" => "schedule",
      "event" => "schedule",
      "changed" => [],
      "event_id" => Ecto.UUID.generate(),
      "depth" => 0,
      "chain" => []
    }

    case Oban.insert(DispatchWorker.new(envelope)) do
      {:ok, _job} -> :ok
      {:error, reason} -> Logger.warning("[Automation.ScheduleAdvance] enqueue failed: #{inspect(reason)}")
    end
  end
end
