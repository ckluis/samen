defmodule Samen.Automation.Health do
  @moduledoc """
  The E8 operator-facing API (ADR-039 §8.3/§8.4; T42) — the SaaS operator's
  cross-tenant view over Automation health + the operator half of the
  two-switch kill. Mirrors `Samen.OperatorPlane`'s exact idiom: an
  application-code RBAC gate (`may_view?/1` / `may_manage?/1`) checked BEFORE
  every read/write, then `authorize?: false` — because the real actor here is
  CROSS-ORG (the operator reaching ANY tenant's workflow by id), which a plain
  `Samen.Policy.OrgScope` policy cannot express. `Automation.Run`'s own
  policies bypass writes entirely (`Samen.Scopes.Automation.Blueprint`) — THIS
  module is the enforcement point, exactly like `Samen.OperatorPlane` is for
  the operator CRM.

  ## Token-blind by construction (INV-1/INV-2)

  Every read here comes from `Automation.Workflow` (bounded ids/enums/jsonb
  condition+action CONFIGS, never subject values) and `Automation.Run`
  (bounded ids/enums/timestamps/bounded outcome jsonb) — there is no `%Masked{}`
  branch and no reveal path because there is no PII column to reach in the
  first place (the same posture `Samen.Web.Operator.WebhookDlqLive` documents
  for the webhook DLQ).

  ## Host wiring

  Resolves `workflow_module`/`run_module`/`repo` from
  `config :samen_core, Samen.Automation, ...` (opts override) — the same
  seam `Samen.Automation.RunWorker`/`DispatchWorker` already use, so the
  operator surface and the engine always agree on which host resources they
  mean.
  """

  require Ash.Query
  import Ash.Query

  alias Samen.Automation
  alias Samen.OperatorPlane.Actor

  # ---------------------------------------------------------------------------
  # RBAC gates
  # ---------------------------------------------------------------------------

  @doc "May this operator VIEW automation health (read-only)?"
  @spec may_view?(Actor.t() | term()) :: boolean()
  def may_view?(%Actor{operator_role: role}),
    do: role in [:operator_admin, :operator_support, :operator_readonly]

  def may_view?(_), do: false

  @doc "May this operator KILL / re-arm a workflow (a write)? Readonly may NOT."
  @spec may_manage?(Actor.t() | term()) :: boolean()
  def may_manage?(%Actor{operator_role: role}),
    do: role in [:operator_admin, :operator_support]

  def may_manage?(_), do: false

  # ---------------------------------------------------------------------------
  # Reads
  # ---------------------------------------------------------------------------

  @doc """
  Per-workflow health aggregates for ONE tenant org (ADR-039 §8.3): run counts
  by state, error-kind distribution, last failure, trip status. Refuses
  `{:error, :not_authorized}` for a non-viewing actor.
  """
  @spec summary(Actor.t() | term(), String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def summary(operator, org_id, opts \\ []) do
    if may_view?(operator) do
      {:ok, build_summary(org_id, opts)}
    else
      {:error, :not_authorized}
    end
  end

  @doc """
  Recent Run rows for ONE tenant org, optionally scoped to one workflow
  (`opts[:workflow_id]`), newest first, bounded by `opts[:limit]` (default 100).
  Refuses `{:error, :not_authorized}` for a non-viewing actor.
  """
  @spec runs(Actor.t() | term(), String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def runs(operator, org_id, opts \\ []) do
    if may_view?(operator) do
      {:ok, list_runs(org_id, opts)}
    else
      {:error, :not_authorized}
    end
  end

  # ---------------------------------------------------------------------------
  # Writes — the operator kill-switch (ADR-039 §8.4)
  # ---------------------------------------------------------------------------

  @doc """
  Kill a workflow (`disabled_reason: :operator`) — idempotent, audited
  (`Samen.AuditEvent`, org-partitioned, actor-attributed). Refuses
  `{:error, :not_authorized}` for an actor that may not manage.
  """
  @spec kill(Actor.t() | term(), String.t(), keyword()) :: {:ok, struct()} | {:error, term()}
  def kill(operator, workflow_id, opts \\ []) do
    if may_manage?(operator) do
      switch(:operator_kill, %{reason: :operator}, operator, workflow_id, opts)
    else
      {:error, :not_authorized}
    end
  end

  @doc """
  Re-arm a workflow (clears both kill columns) — idempotent, audited. Refuses
  `{:error, :not_authorized}` for an actor that may not manage.
  """
  @spec rearm(Actor.t() | term(), String.t(), keyword()) :: {:ok, struct()} | {:error, term()}
  def rearm(operator, workflow_id, opts \\ []) do
    if may_manage?(operator) do
      switch(:operator_rearm, %{}, operator, workflow_id, opts)
    else
      {:error, :not_authorized}
    end
  end

  # ---------------------------------------------------------------------------
  # Internal
  # ---------------------------------------------------------------------------

  defp switch(action, args, operator, workflow_id, opts) do
    case Automation.workflow_module(opts) do
      nil ->
        {:error, :no_automation_module}

      wf_mod ->
        with {:ok, wf} <- fetch_workflow(wf_mod, workflow_id),
             {:ok, updated} <-
               wf
               |> Ash.Changeset.for_update(action, args, authorize?: false)
               |> Ash.update(authorize?: false) do
          # Ash's update result does not carry forward an attribute that was
          # merely SELECTED (not written) on the pre-update struct — capture
          # org_id from `wf` (explicitly ensure_selected in `fetch_workflow/2`)
          # rather than trusting `updated.org_id`.
          audit_switch(action, updated, wf.org_id, operator, opts)
          {:ok, updated}
        end
    end
  end

  # `Ash.get/3` does not accept a pre-built query, and `org_id` (like every
  # cross-org operator-plane lookup here) is not guaranteed selected by the
  # resource's default read — ensure_selected it explicitly (the
  # `RunWorker.load_workflow/2` precedent) so the audit's `correlation_id`
  # (and the caller's `{:ok, updated}` return) always carry it.
  defp fetch_workflow(wf_mod, workflow_id) do
    wf_mod
    |> filter(id == ^workflow_id)
    |> Ash.Query.ensure_selected([:org_id])
    |> Ash.read!(authorize?: false)
    |> case do
      [wf | _] -> {:ok, wf}
      [] -> {:error, :not_found}
    end
  rescue
    e -> {:error, e}
  end

  defp audit_switch(action, wf, org_id, operator, opts) do
    repo = Automation.repo(opts)

    if repo do
      Samen.AuditEvent.insert(repo, %{
        event_type: "system",
        subject_id: to_string(wf.id),
        actor_id: operator_id(operator),
        correlation_id: org_id,
        detail: "automation.workflow.#{action} killed=#{not is_nil(wf.disabled_by_operator_at)}"
      })
    end

    :ok
  rescue
    _ -> :ok
  end

  defp operator_id(%Actor{id: id}), do: id
  defp operator_id(%{id: id}), do: id
  defp operator_id(_), do: nil

  defp build_summary(org_id, opts) do
    with wf_mod when not is_nil(wf_mod) <- Automation.workflow_module(opts),
         run_mod when not is_nil(run_mod) <- Automation.run_module(opts) do
      wf_mod
      |> safe_read_by_org(org_id)
      |> Enum.map(&workflow_health(&1, run_mod, org_id))
    else
      _ -> []
    end
  end

  defp workflow_health(wf, run_mod, org_id) do
    runs = safe_runs_for_workflow(run_mod, org_id, wf.id, 500)

    by_state =
      runs
      |> Enum.map(& &1.state)
      |> Enum.frequencies()

    by_error_kind =
      runs
      |> Enum.map(& &1.error_kind)
      |> Enum.reject(&is_nil/1)
      |> Enum.frequencies()

    last_failure =
      runs
      |> Enum.filter(&(&1.state == :failed))
      |> Enum.max_by(& &1.finished_at, fn a, b -> compare_dt(a, b) end, fn -> nil end)

    %{
      workflow_id: wf.id,
      name: wf.name,
      status: wf.status,
      trigger_kind: wf.trigger_kind,
      killed: not is_nil(wf.disabled_by_operator_at),
      disabled_reason: wf.disabled_reason,
      disabled_by_operator_at: wf.disabled_by_operator_at,
      total_runs: length(runs),
      run_counts: by_state,
      error_kind_counts: by_error_kind,
      last_failure_at: last_failure && last_failure.finished_at
    }
  end

  defp compare_dt(%DateTime{} = a, %DateTime{} = b), do: DateTime.compare(a, b) != :lt
  defp compare_dt(nil, _), do: false
  defp compare_dt(_a, nil), do: true

  defp list_runs(org_id, opts) do
    limit = Keyword.get(opts, :limit, 100)
    workflow_id = Keyword.get(opts, :workflow_id)

    case Automation.run_module(opts) do
      nil ->
        []

      run_mod ->
        run_mod
        |> filter(org_id == ^org_id)
        |> maybe_filter_workflow(workflow_id)
        |> Ash.Query.sort(inserted_at: :desc)
        |> Ash.Query.limit(limit)
        |> Ash.read!(authorize?: false)
    end
  rescue
    _ -> []
  end

  defp maybe_filter_workflow(query, nil), do: query
  defp maybe_filter_workflow(query, workflow_id), do: filter(query, workflow_id == ^workflow_id)

  defp safe_runs_for_workflow(run_mod, org_id, workflow_id, limit) do
    run_mod
    |> filter(org_id == ^org_id)
    |> filter(workflow_id == ^workflow_id)
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.Query.limit(limit)
    |> Ash.read!(authorize?: false)
  rescue
    _ -> []
  end

  defp safe_read_by_org(resource, org_id) do
    resource
    |> filter(org_id == ^org_id)
    |> Ash.read!(authorize?: false)
  rescue
    _ -> []
  end
end
