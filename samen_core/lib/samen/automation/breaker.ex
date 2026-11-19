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

  ## Fail-safe, and said

  A missing/unwired Run log (`run_module` not configured) makes the breaker
  INERT (`check!/2` is a no-op) rather than raising — exactly
  `Samen.Automation.RunRecord`'s posture. The breaker runs AFTER the run finalized, so a count that
  cannot be read has nothing left to refuse: it never blocks or crashes the run, but it is not
  silent either — it is reported (`automation_breaker_count`) and the next run counts again.
  """

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
      nil ->
        :ok

      run_mod ->
        # Two different failures, two different names: a count that cannot be READ (`automation_breaker_count`, a read)
        # and a trip that could not be WRITTEN (`automation_breaker_trip`, a write: the workflow keeps running past its
        # limit). One wide `rescue` over both labelled the second as the first.
        with {:ok, count} <- count_runs(run_mod, wf),
             true <- count > limit() do
          trip(wf, count, opts)
        else
          _ -> :ok
        end
    end
  end

  defp count_runs(run_mod, wf) do
    since = DateTime.add(DateTime.utc_now(), -@window_seconds, :second)

    count =
      run_mod
      |> filter(workflow_id == ^wf.id)
      |> filter(inserted_at >= ^since)
      |> Ash.count!(authorize?: false)

    {:ok, count}
  rescue
    e ->
      Samen.Observability.Failure.report(:automation_breaker_count, wf.org_id, e)
      :error
  end

  defp trip(wf, count, opts) do
    if is_nil(wf.disabled_by_operator_at) do
      case wf
           |> Ash.Changeset.for_update(:operator_kill, %{reason: :rate_tripped}, authorize?: false)
           |> Ash.update(authorize?: false) do
        {:ok, _wf} -> audit_trip(wf, count, opts)
        {:error, reason} -> Samen.Observability.Failure.report_write(:automation_breaker_trip, wf.org_id, reason)
      end
    end

    :ok
  rescue
    e ->
      Samen.Observability.Failure.report_write(:automation_breaker_trip, wf.org_id, e)
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
    e ->
      Samen.Observability.Failure.report_write(:breaker_audit_trip, nil, e)
      :ok
  end
end
