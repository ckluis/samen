defmodule Samen.Automation.RunRecord do
  @moduledoc """
  The `Automation.Run` row lifecycle (ADR-039 §8.1/§4.6 tier 2; T42). The ONLY
  writer of Run rows — called from `Samen.Automation.RunWorker`,
  `Samen.Automation.DispatchWorker` (the no-enqueue skips, §4.7 guards 1-2), and
  `Samen.Automation.Breaker` (the rate-trip skip, §4.7 guard 3). Every write runs
  `authorize?: false` — Run's own policies bypass create/update entirely
  (`Automation.Scopes.Blueprint.define_run/5`), so this module IS the write
  chokepoint by convention, not by a policy the resource itself enforces.

  ## Fail-safe, never fail-loud (mirrors ADR-039 §5.1's action-failure isolation)

  A run's OBSERVABILITY must never be able to crash or block its EXECUTION. Every
  function here is total: an unwired `run_module` (host hasn't configured T42
  yet), a transient DB error, or a rejected transition (e.g. finalizing an
  already-terminal row on an Oban retry) all degrade to `nil` / a no-op rather
  than raising — the pipeline keeps running with or without a Run row.

  ## Tier-2 dedupe (ADR-039 §4.6)

  `dispatch_key/2` = `sha256(workflow_id <> ":" <> event_id)`, unique-indexed on
  `Automation.Run`. `open!/2` upserts on that identity (the resource's `:record`
  action is `upsert?(true)`) — a concurrent duplicate dispatch (Oban's own tier-1
  unique can still race under retry/redelivery) lands on the SAME row instead of
  violating the index or creating a second log entry for one logical run.
  """

  require Logger
  require Ash.Query
  import Ash.Query

  alias Samen.Automation

  @doc "The tier-2 dedupe key (ADR-039 §4.6): sha256(workflow_id <> event_id), hex."
  @spec dispatch_key(String.t() | nil, String.t() | nil) :: String.t()
  def dispatch_key(workflow_id, event_id) do
    :crypto.hash(:sha256, "#{workflow_id}:#{event_id}")
    |> Base.encode16(case: :lower)
  end

  @doc """
  Open (find-or-create, upsert on `dispatch_key`) the Run row for a workflow
  about to execute. `args` is the dispatch envelope (org_id, event_id,
  trigger_kind, subject_ref, depth, ...). Returns the Run row, or `nil` if the
  engine is unwired or the write failed (never raises).
  """
  @spec open!(map(), map(), keyword()) :: struct() | nil
  def open!(wf, args, opts \\ []) do
    case Automation.run_module(opts) do
      nil ->
        nil

      run_mod ->
        do_open(run_mod, wf, args, opts)
    end
  end

  defp do_open(run_mod, wf, args, _opts) do
    key = dispatch_key(to_string(wf.id), args["event_id"])
    # The envelope's own org_id (ADR-039 §4.2, always present) — preferred
    # over `wf.org_id`, which is not guaranteed selected on every caller's
    # struct (only `RunWorker.load_workflow/2` explicitly ensures it).
    org_id = args["org_id"] || safe_org_id(wf)

    run_mod
    |> Ash.Changeset.for_create(
      :record,
      %{
        org_id: org_id,
        workflow_id: wf.id,
        dispatch_key: key,
        trigger_kind: trigger_atom(args["trigger_kind"]),
        subject_ref: args["subject_ref"],
        depth: args["depth"] || 0
      },
      authorize?: false
    )
    |> Ash.create(authorize?: false)
    |> case do
      {:ok, run} -> run
      {:error, _reason} -> find_by_key(run_mod, org_id, key)
    end
  rescue
    e ->
      Logger.debug("[Automation.RunRecord] open! failed: #{Exception.message(e)}")
      nil
  end

  defp safe_org_id(%{org_id: org_id}) when is_binary(org_id), do: org_id
  defp safe_org_id(_), do: nil

  defp find_by_key(run_mod, org_id, key) do
    run_mod
    |> filter(org_id == ^org_id)
    |> filter(dispatch_key == ^key)
    |> Ash.read!(authorize?: false)
    |> List.first()
  rescue
    _ -> nil
  end

  @doc "Transition an opened run :queued -> :running, stamping `started_at`. No-op on `nil`."
  @spec mark_running!(struct() | nil) :: struct() | nil
  def mark_running!(nil), do: nil

  def mark_running!(run) do
    run
    |> Ash.Changeset.for_update(:start, %{}, authorize?: false)
    |> Ash.update(authorize?: false)
    |> case do
      {:ok, run} -> run
      {:error, _reason} -> run
    end
  rescue
    _ -> run
  end

  @doc """
  Finalize a run `:skipped` with a bounded reason (ADR-039 §8.1 reason set).
  No-op on `nil` (unwired engine).
  """
  @spec skip!(struct() | nil, atom()) :: :ok
  def skip!(nil, _reason), do: :ok

  def skip!(run, reason) do
    finalize(run, :skipped, [], reason)
  end

  @doc "Finalize a run `:succeeded` with the ordered per-action outcome list."
  @spec succeed!(struct() | nil, [map()]) :: :ok
  def succeed!(nil, _outcomes), do: :ok

  def succeed!(run, outcomes) do
    finalize(run, :succeeded, bounded_outcomes(outcomes), nil)
  end

  @doc """
  Finalize a run `:failed` with the outcome list gathered so far + the failing
  action's bounded `error_kind` (falls back to `:action_failed` when the
  underlying Reactor error shape can't be introspected — `Compile.run/2`
  deliberately does not commit to one shape, ADR-039 §5.1).
  """
  @spec fail!(struct() | nil, [map()], atom()) :: :ok
  def fail!(nil, _outcomes, _error_kind), do: :ok

  def fail!(run, outcomes, error_kind) do
    finalize(run, :failed, bounded_outcomes(outcomes), error_kind || :action_failed)
  end

  defp finalize(run, to, outcome, error_kind) do
    run
    |> Ash.Changeset.for_update(
      :finalize,
      %{to: to, outcome: outcome, error_kind: safe_error_kind(error_kind)},
      authorize?: false
    )
    |> Ash.update(authorize?: false)
    |> case do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.debug("[Automation.RunRecord] finalize(#{to}) failed: #{inspect(reason)}")
        :ok
    end
  rescue
    e ->
      Logger.debug("[Automation.RunRecord] finalize(#{to}) failed: #{Exception.message(e)}")
      :ok
  end

  # Mirrors the Run resource's `error_kind` closed `one_of` set exactly
  # (`Samen.Scopes.Automation.Blueprint.define_run/5`) — an unrecognized atom
  # (e.g. a host-registered custom action's own error_kind, ADR-039 §5.1's
  # host-extendable registry) degrades to `:action_failed` rather than
  # rejecting the whole finalize write.
  @known_error_kinds MapSet.new(~w(
    conditions_unmet invalid_conditions killed loop depth_exceeded rate_tripped
    owner_unavailable action_failed internal_error raised unknown_action_kind
    adapter_unconfigured escalate_unwired https_required invalid_assigns
    invalid_at_attribute invalid_attribute invalid_attrs invalid_chain
    invalid_config invalid_deadline_minutes invalid_event_type invalid_include
    invalid_offset_minutes invalid_recipient invalid_schedule invalid_scheme
    invalid_tag invalid_template_key invalid_to invalid_url invalid_user_id
    missing_resource_key missing_schedule no_automation_module no_recipient
    no_subject_record no_tag_surface no_webhook_secret not_found nxdomain
    reminder_unwired ssrf_blocked suppressed unauthorized unknown_resource
    write_failed
  )a)

  defp safe_error_kind(nil), do: nil
  defp safe_error_kind(k) when is_atom(k) do
    if MapSet.member?(@known_error_kinds, k), do: k, else: :action_failed
  end

  defp safe_error_kind(_), do: :action_failed

  # Outcomes must stay bounded (ids/enums/numbers only, ADR-039 §5.1) — the
  # PERSISTENCE boundary, so this is default-DENY (an explicit key ALLOWLIST),
  # not a blocklist. `Compile.run/2` deliberately does not commit to one error
  # shape (see RunWorker's failure extraction) — a caller could hand this a
  # list containing a raw Reactor/Exception STRUCT rather than the plain map
  # `ActionStep` normally produces. A struct is technically `is_map?/1` true,
  # so `plain_map?/1` additionally refuses anything carrying `__struct__` —
  # only a bare map survives, and only its known-bounded keys are kept. Never
  # `inspect/1` or `Exception.message/1` an unknown value into this column;
  # that is exactly the freeform-text leak `ActionStep.bounded/1` already
  # guards against for the success path (`meta`) — this is the same guard for
  # every OTHER path that can reach the log.
  @allowed_outcome_keys ~w(index kind status error_kind meta duration_ms)a
  @allowed_outcome_keys_str Enum.map(@allowed_outcome_keys, &Atom.to_string/1)

  defp bounded_outcomes(outcomes) when is_list(outcomes) do
    outcomes
    |> Enum.filter(&plain_map?/1)
    |> Enum.map(&Map.take(&1, @allowed_outcome_keys ++ @allowed_outcome_keys_str))
  end

  defp bounded_outcomes(_), do: []

  defp plain_map?(%{__struct__: _}), do: false
  defp plain_map?(m) when is_map(m), do: true
  defp plain_map?(_), do: false

  defp trigger_atom(k) when k in ["resource_event", "schedule", "manual"], do: String.to_existing_atom(k)
  defp trigger_atom(k) when is_atom(k), do: k
  defp trigger_atom(_), do: :resource_event
end
