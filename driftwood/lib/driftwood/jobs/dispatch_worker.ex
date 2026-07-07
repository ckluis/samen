defmodule Driftwood.Jobs.DispatchWorker do
  @moduledoc """
  The load/dispatch workflow as an Oban job (T2.1 conventions; design §1(d)).

  A dispatch request enqueues this worker. `perform/1` runs the FMCSA-gated
  `DispatchEvent.:dispatch` create action — so the SAME `Driftwood.Policy.FmcsaDispatchGate`
  legality gate that guards a synchronous dispatch also guards the async workflow.
  On success it writes the DispatchEvent row and (optionally) advances the load's
  status to "dispatched". On an FMCSA-gate refusal the action returns an
  `Ash.Error.Invalid` — the worker DISCARDS the job (a compliance refusal is not a
  transient error; retrying an expired-CDL driver will never succeed), logging the
  reason for the ops trail.

  Queue: `:default` (the T2.1 catch-all). `max_attempts: 3` — a genuine transient
  (DB blip) retries a couple of times; a compliance refusal is discarded immediately
  via `{:discard, reason}`.
  """
  use Oban.Worker, queue: :default, max_attempts: 3

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    driver_id = fetch!(args, "driver_id")
    load_id = fetch!(args, "load_id")
    org_id = fetch!(args, "org_id")

    actor = %{org_id: org_id, role: :member}

    Driftwood.Freight.DispatchEvent
    |> Ash.Changeset.for_create(
      :dispatch,
      %{
        driver_id: driver_id,
        load_id: load_id,
        status: :dispatched,
        dispatched_at: DateTime.utc_now() |> DateTime.truncate(:second)
      },
      actor: actor,
      authorize?: true
    )
    |> Ash.create()
    |> case do
      {:ok, dispatch} ->
        Logger.info("[DispatchWorker] dispatched driver=#{driver_id} load=#{load_id}")
        {:ok, dispatch}

      {:error, %Ash.Error.Invalid{} = err} ->
        # An FMCSA-gate refusal (or same-org-FK refusal) — NOT transient. Discard.
        reason = Exception.message(err)
        Logger.warning("[DispatchWorker] dispatch REFUSED driver=#{driver_id}: #{reason}")
        {:discard, reason}

      {:error, other} ->
        # A genuine transient (DB error, etc.) — let Oban retry.
        {:error, other}
    end
  end

  @doc """
  Enqueue a dispatch job for `driver_id` → `load_id` in `org_id`. The canonical
  entry point for the load/dispatch workflow.
  """
  def enqueue(driver_id, load_id, org_id) do
    %{driver_id: to_string(driver_id), load_id: to_string(load_id), org_id: to_string(org_id)}
    |> new()
    |> Oban.insert()
  end

  defp fetch!(args, key) do
    case Map.fetch(args, key) do
      {:ok, v} -> v
      :error -> raise ArgumentError, "DispatchWorker: missing required arg #{inspect(key)}"
    end
  end
end
