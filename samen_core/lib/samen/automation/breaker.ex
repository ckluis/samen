defmodule Samen.Automation.Breaker do
  @moduledoc """
  The E8 rate breaker (ADR-039 §4.7 guard 3; T42) — the third loop/rate
  protection, alongside T39's cycle refusal (`:loop`) and depth cap
  (`:depth_exceeded`). Called from `Samen.Automation.RunWorker` after a run
  finalizes: counts this workflow's runs over the trailing window (via the
  Run log itself — `Samen.Automation.Run`, so the breaker adds no second
  counting mechanism) and, past the threshold, auto-trips the OPERATOR
  kill-switch (`disabled_reason: :rate_tripped`) — the SAME columns/action
  `Samen.Automation.Health`'s human-invoked kill uses (`:operator_kill`), never
  a parallel mechanism.

  ## Re-arming (§4.7(3))

  "Re-arming is an explicit operator (or, for rate trips, tenant-owner) action —
  never automatic." This module only ever TRIPS; nothing here re-arms.

  ## Fail-safe

  A missing/unwired Run log (`run_module` not configured) makes the breaker
  INERT (`check!/2` is a no-op) rather than raising — exactly
  `Samen.Automation.RunRecord`'s posture. Observability failing open on the
  breaker's OWN counting never blocks or crashes a run.
  """

  require Logger
  require Ash.Query
  import Ash.Query

  alias Samen.Automation

  @default_limit 60
  @window_seconds 60

  @doc "The configured runs/workflow/minute threshold (config-tunable, default 60)."
  @spec limit() :: pos_integer()
  def limit, do: Application.get_env(:samen_core, :automation_rate_limit, @default_limit)

  @doc """
  Count this workflow's runs in the trailing window; past `limit/0`, trip the
  operator kill-switch (idempotent — a workflow already killed for any reason
  is left alone, never re-stamped) and audit the trip. Always returns `:ok`;
  never raises.
  """
  @spec check!(struct(), keyword()) :: :ok
  def check!(wf, opts \\ []) do
    case Automation.run_module(opts) do
      nil -> :ok
      run_mod -> maybe_trip(run_mod, wf, opts)
    end
  rescue
    e ->
      Logger.debug("[Automation.Breaker] check! failed: #{Exception.message(e)}")
      :ok
  end

  defp maybe_trip(run_mod, wf, opts) do
    since = DateTime.add(DateTime.utc_now(), -@window_seconds, :second)

    count =
      run_mod
      |> filter(workflow_id == ^wf.id)
      |> filter(inserted_at >= ^since)
      |> Ash.count!(authorize?: false)

    if count > limit() do
      trip(wf, count, opts)
    else
      :ok
    end
  end

  defp trip(wf, count, opts) do
    if is_nil(wf.disabled_by_operator_at) do
      case wf
           |> Ash.Changeset.for_update(:operator_kill, %{reason: :rate_tripped}, authorize?: false)
           |> Ash.update(authorize?: false) do
        {:ok, _wf} ->
          audit_trip(wf, count, opts)

        {:error, reason} ->
          Logger.warning("[Automation.Breaker] trip write failed for #{wf.id}: #{inspect(reason)}")
      end
    end

    :ok
  end

  defp audit_trip(wf, count, opts) do
    repo = Automation.repo(opts)

    if repo do
      Samen.AuditEvent.insert(repo, %{
        event_type: "system",
        subject_id: to_string(wf.id),
        actor_id: nil,
        correlation_id: wf.org_id,
        detail: "automation.workflow.rate_tripped count=#{count} window_s=#{@window_seconds} limit=#{limit()}"
      })
    end
  rescue
    _ -> :ok
  end
end
