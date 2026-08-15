defmodule Samen.AI.Agent.Health do
  @moduledoc """
  The A5 operator-facing agent oversight API (ADR-047 §8/A5, §6) — the SaaS operator's
  per-tenant view over agent runs plus the operator half of the DURABLE
  per-{org, definition} kill (`Samen.AI.Agent.Kill`).

  Mirrors `Samen.Automation.Health`'s idiom exactly: an application-code RBAC gate
  (`may_view?/1` / `may_manage?/1` over a `Samen.OperatorPlane.Actor`) checked BEFORE
  every read/write, then `authorize?: false` — because the actor here is CROSS-ORG (an
  operator reaching a named tenant's runs), which `Samen.Policy.OrgScope` cannot express.
  The org id is always an explicit argument, never inferred, so every read is pinned to
  exactly one tenant.

  ## Two-plane rule: the operator sees the TURN LOG, never the TRANSCRIPT

  ADR-047 §7.3 is categorical for this surface — the operator plane renders **no
  transcript at all** (mask-by-omission, not mask-by-styling). This module therefore has
  no function that returns a transcript, resolved or masked: the run projection
  (`runs/3`) selects the bounded columns explicitly and DROPS `:transcript`, so an
  operator-plane caller cannot reach the vault-routed attribute even to mask it. The
  only text artifact a run holds stays inside the DEK envelope, reachable only on the
  tenant plane through `Samen.Api.PiiResolution` (`Samen.Web.AI.AgentReads`).

  Everything this module DOES return is token-only by allowlist (ADR-047 §6): ids,
  enums, counts, durations, bounded error kinds, arg key NAMES. There is no `%Masked{}`
  branch here because there is no PII column in reach — the `Samen.Automation.Health` /
  `Samen.Web.Operator.WebhookDlqLive` posture.
  """

  require Ash.Query

  alias Samen.AI.Agent.Breaker
  alias Samen.AI.Agent.Run
  alias Samen.AI.Agent.Turn
  alias Samen.OperatorPlane.Actor

  # The bounded run projection an operator may see. `:transcript` is deliberately absent
  # (see the moduledoc) — this list IS the two-plane rule for this surface.
  @run_fields [
    :id,
    :org_id,
    :agent,
    :state,
    :current_turn,
    :error_kind,
    :started_at,
    :next_turn_at,
    :cancel_requested_at,
    :tool_calls_used,
    :input_tokens_used,
    :output_tokens_used,
    :max_turns,
    :max_tool_calls,
    :origin,
    :depth,
    :inserted_at,
    :updated_at
  ]

  @turn_fields [
    :id,
    :run_id,
    :turn_index,
    :status,
    :tool_kind,
    :arg_keys,
    :error_kind,
    :input_tokens,
    :output_tokens,
    :duration_ms,
    :provider,
    :simulated,
    :meta,
    :inserted_at
  ]

  # ---------------------------------------------------------------------------
  # RBAC gates (the Samen.Automation.Health contract, verbatim in shape)
  # ---------------------------------------------------------------------------

  @doc "May this operator VIEW agent health (read-only)?"
  @spec may_view?(Actor.t() | term()) :: boolean()
  def may_view?(%Actor{operator_role: role}),
    do: role in [:operator_admin, :operator_support, :operator_readonly]

  def may_view?(_), do: false

  @doc "May this operator KILL / re-arm an agent definition (a write)? Readonly may NOT."
  @spec may_manage?(Actor.t() | term()) :: boolean()
  def may_manage?(%Actor{operator_role: role}),
    do: role in [:operator_admin, :operator_support]

  def may_manage?(_), do: false

  # ---------------------------------------------------------------------------
  # Reads
  # ---------------------------------------------------------------------------

  @doc """
  Per-DEFINITION aggregates for ONE tenant org: run counts by state, error-kind
  distribution, last failure, token/tool spend, and the durable kill state. Refuses
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
  The bounded run log for ONE tenant org (newest first). **No transcript** — see the
  moduledoc's two-plane rule.
  """
  @spec runs(Actor.t() | term(), String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def runs(operator, org_id, opts \\ []) do
    if may_view?(operator) do
      {:ok, list_runs(org_id, opts)}
    else
      {:error, :not_authorized}
    end
  end

  @doc """
  The bounded TURN log for one run — the operator's drill-down (ADR-047 §6: turn index,
  tool kind, arg key NAMES, status, bounded error kind, tokens, duration, provider,
  simulated). Org-pinned: a run id from another org returns `[]`, never rows.
  """
  @spec turns(Actor.t() | term(), String.t(), String.t(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def turns(operator, org_id, run_id, opts \\ []) do
    if may_view?(operator) do
      {:ok, list_turns(org_id, run_id, opts)}
    else
      {:error, :not_authorized}
    end
  end

  @doc "The durable kill rows for one org (token-only), newest first."
  @spec kills(Actor.t() | term(), String.t()) :: {:ok, [map()]} | {:error, term()}
  def kills(operator, org_id) do
    if may_view?(operator), do: {:ok, Breaker.kills(org_id)}, else: {:error, :not_authorized}
  end

  # ---------------------------------------------------------------------------
  # Writes — the durable per-definition kill (fail-closed, audited, never self-healing)
  # ---------------------------------------------------------------------------

  @doc """
  Throw the DURABLE per-{org, definition} kill. New runs for that definition in that org
  refuse `{:error, :killed}` and every in-flight run stops at its NEXT turn boundary.
  Refuses `{:error, :not_authorized}` for a readonly/non-operator actor.
  """
  @spec kill(Actor.t() | term(), String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def kill(operator, org_id, agent_name, opts \\ []) do
    if may_manage?(operator) do
      Breaker.kill_definition(
        org_id,
        agent_name,
        Keyword.get(opts, :reason, :operator),
        actor_id: operator_id(operator),
        org_id: org_id
      )
    else
      {:error, :not_authorized}
    end
  end

  @doc "Explicit operator re-arm of ONE `{org, definition}` — the only thing that clears a trip."
  @spec rearm(Actor.t() | term(), String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def rearm(operator, org_id, agent_name, opts \\ []) do
    if may_manage?(operator) do
      Breaker.rearm_definition(
        org_id,
        agent_name,
        Keyword.merge([actor_id: operator_id(operator), org_id: org_id], opts)
      )
    else
      {:error, :not_authorized}
    end
  end

  # ---------------------------------------------------------------------------

  defp operator_id(%Actor{id: id}) when is_binary(id), do: id
  defp operator_id(%{id: id}) when is_binary(id), do: id
  defp operator_id(_), do: nil

  defp build_summary(org_id, opts) do
    runs = list_runs(org_id, Keyword.put_new(opts, :limit, 500))
    kill_index = Map.new(Breaker.kills(org_id), fn k -> {k.agent, k} end)

    runs
    |> Enum.group_by(& &1.agent)
    |> Enum.map(fn {agent, agent_runs} ->
      kill = Map.get(kill_index, agent)

      %{
        agent: agent,
        total_runs: length(agent_runs),
        run_counts: count_by(agent_runs, & &1.state),
        error_kind_counts: count_by(Enum.reject(agent_runs, &is_nil(&1.error_kind)), & &1.error_kind),
        awaiting_approval: Enum.count(agent_runs, &(&1.state == :awaiting_approval)),
        tool_calls: Enum.reduce(agent_runs, 0, &(&1.tool_calls_used + &2)),
        tokens:
          Enum.reduce(agent_runs, 0, &(&1.input_tokens_used + &1.output_tokens_used + &2)),
        last_run_at: agent_runs |> Enum.map(& &1.inserted_at) |> latest(),
        last_failure_at:
          agent_runs
          |> Enum.filter(&(&1.state in [:failed, :budget_exhausted]))
          |> Enum.map(& &1.updated_at)
          |> latest(),
        killed: kill != nil and Breaker.active_kill?(kill),
        kill_reason: kill && kill.reason,
        killed_at: kill && kill.killed_at
      }
    end)
    |> Enum.sort_by(& &1.agent)
  end

  defp count_by(rows, fun) do
    rows |> Enum.group_by(fun) |> Map.new(fn {k, v} -> {to_string(k), length(v)} end)
  end

  defp latest([]), do: nil

  defp latest(datetimes) do
    datetimes
    |> Enum.reject(&is_nil/1)
    |> Enum.sort({:desc, DateTime})
    |> List.first()
  end

  # THE bounded projection: the explicit `Map.take/2` is what keeps `:transcript` (and
  # anything a future column adds) out of the operator plane BY CONSTRUCTION rather than
  # by the template happening not to render it. Sabotage 261 puts the transcript back
  # into this projection and the named operator-plane omission test flips.
  defp list_runs(org_id, opts) when is_binary(org_id) do
    limit = Keyword.get(opts, :limit, 50)

    Run
    |> Ash.Query.filter(org_id == ^org_id)
    |> maybe_filter_agent(Keyword.get(opts, :agent))
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.Query.limit(limit)
    |> Ash.Query.ensure_selected(@run_fields)
    |> Ash.read(authorize?: false)
    |> case do
      {:ok, rows} -> Enum.map(rows, &Map.take(&1, @run_fields))
      _ -> []
    end
  rescue
    _ -> []
  end

  defp list_runs(_org_id, _opts), do: []

  defp maybe_filter_agent(query, nil), do: query
  defp maybe_filter_agent(query, agent), do: Ash.Query.filter(query, agent == ^agent)

  defp list_turns(org_id, run_id, opts) when is_binary(org_id) and is_binary(run_id) do
    limit = Keyword.get(opts, :limit, 100)

    Turn
    |> Ash.Query.filter(org_id == ^org_id and run_id == ^run_id)
    |> Ash.Query.sort(turn_index: :asc)
    |> Ash.Query.limit(limit)
    |> Ash.Query.ensure_selected(@turn_fields)
    |> Ash.read(authorize?: false)
    |> case do
      {:ok, rows} -> Enum.map(rows, &Map.take(&1, @turn_fields))
      _ -> []
    end
  rescue
    _ -> []
  end

  defp list_turns(_org_id, _run_id, _opts), do: []
end
