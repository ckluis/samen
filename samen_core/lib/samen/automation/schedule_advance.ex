defmodule Samen.Automation.ScheduleAdvance do
  @moduledoc """
  The body of the `:dispatch_due` update action driven by the Workflow's AshOban
  `:schedule_scan` trigger (ADR-039 §4.1(2), §4.3). Per due workflow it:

    1. **Advances `next_fire_at`** to the next occurrence of the tenant's
       `schedule_cron`, computed with `Oban.Cron.Expression` (already in the tree — no
       new dep), so the same workflow is not re-scheduled until its next cron minute.
    2. **Enqueues one `DispatchWorker`** (trigger_kind `:schedule`) inside the update's
       transaction — the same in-txn insert discipline as event capture.

  ## Idempotency (ADR-039 §4.1, §4.6)

  Two scans can read the same due workflow. The update is a compare-and-set on the
  `next_fire_at` the scan read: it matches no row once another scan has advanced it, so only
  one scan advances the workflow and enqueues its dispatch; the other gets a stale-record
  error and enqueues nothing. The dispatch's `event_id` is also derived from
  `(workflow id, the fire time it was read at)`, so even a dispatch enqueued twice for one
  fire time is one run (Oban uniqueness on `{workflow_id, event_id}` and the Run's
  `dispatch_key`). The next fire time has a different `event_id`.

  This is a system maintenance action (bypass-authorized), streamed per-record by
  AshOban — it never reads across orgs.
  """
  use Ash.Resource.Change

  require Logger

  alias Samen.Automation.DispatchWorker

  @impl true
  def change(changeset, _opts, _context) do
    fire_at = fire_at(changeset)

    changeset
    |> guard_fire_at(fire_at)
    |> advance()
    |> Ash.Changeset.after_action(fn cs, result ->
      case resolve_org_id(cs, result) do
        nil ->
          # No org to dispatch under (the reload failed and was reported): a dispatch with a blank org would be
          # rejected downstream and leave no Run row at all. Returning an error rolls the whole update back, so
          # `next_fire_at` is NOT advanced and the scan retries this fire (it is never silently lost).
          Samen.Observability.Failure.report_write(:schedule_advance_enqueue_skipped, nil, :no_org)
          {:error, :org_unresolved}

        org_id ->
          enqueue_dispatch(result, org_id, fire_at)
          {:ok, result}
      end
    end)
  end

  # The `next_fire_at` this scan read (the scan's `where` selects it; a record that arrives without it is reloaded).
  defp fire_at(changeset) do
    case Ash.Changeset.get_data(changeset, :next_fire_at) do
      %DateTime{} = at -> at
      nil -> nil
      _not_loaded -> reload_fire_at(changeset.resource, Ash.Changeset.get_data(changeset, :id))
    end
  end

  defp reload_fire_at(_resource, nil), do: nil

  defp reload_fire_at(resource, id) do
    import Ash.Query

    resource
    |> filter(id == ^id)
    |> Ash.Query.ensure_selected([:next_fire_at])
    |> Ash.read!(authorize?: false)
    |> case do
      [r | _] -> Map.get(r, :next_fire_at)
      [] -> nil
    end
  rescue
    e ->
      Samen.Observability.Failure.report(:schedule_advance_reload_fire_at, nil, e)
      nil
  end

  # The compare-and-set: the update applies only while `next_fire_at` is still the value the scan read.
  defp guard_fire_at(changeset, %DateTime{} = fire_at),
    do: Ash.Changeset.filter(changeset, Ash.Expr.expr(next_fire_at == ^fire_at))

  defp guard_fire_at(changeset, _no_fire_at), do: changeset

  @doc false
  # Deterministic per (workflow, fire time): the same fire time is always the same event.
  @spec event_id(term(), DateTime.t() | nil) :: String.t()
  def event_id(workflow_id, fire_at) do
    stamp = if match?(%DateTime{}, fire_at), do: DateTime.to_iso8601(fire_at), else: "none"
    :crypto.hash(:sha256, "schedule:#{workflow_id}:#{stamp}") |> Base.encode16(case: :lower)
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
    e ->
      Samen.Observability.Failure.report(:schedule_advance_reload_org, nil, e)
      nil
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

  defp enqueue_dispatch(wf, org_id, fire_at) do
    envelope = %{
      "org_id" => to_string(org_id),
      "workflow_id" => to_string(wf.id),
      "resource_key" => wf.resource_key,
      "subject_ref" => "samen:workflow:#{wf.id}",
      "trigger_kind" => "schedule",
      "event" => "schedule",
      "changed" => [],
      "event_id" => event_id(wf.id, fire_at),
      "depth" => 0,
      "chain" => []
    }

    case Oban.insert(DispatchWorker.new(envelope)) do
      {:ok, _job} -> :ok
      {:error, reason} -> Logger.warning("[Automation.ScheduleAdvance] enqueue failed: #{inspect(reason)}")
    end
  end
end
