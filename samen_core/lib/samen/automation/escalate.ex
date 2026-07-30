defmodule Samen.Automation.Escalate do
  @moduledoc """
  The E5 generic escalation primitive's public API (ADR-039 §7.2 — binding
  signatures; T40's `escalate` action builds directly on this). Host-wired seam,
  the `Notifications.Engine`/`Samen.Approvals` convention:

      config :samen_core, Samen.Automation.Escalate,
        escalation_module: Demo.AutomationScope.Escalation,
        repo: Demo.Repo

  Unwired ⇒ fail-closed `{:error, :no_automation_module}`.

  ## Client adoption (ADR-039 §7.4 — binding for T41)

  SLA-breach (`Samen.Scopes.Support.SlaBreachWorker`) and dunning
  (`Samen.Billing.Dunning`) are this primitive's first CLIENTS. Neither's domain
  logic changes: SLA breach keeps its scan + `breached` flip + `aud_event`; its
  ONLY bespoke attention path (the inline `Notifications.Engine.emit/1` call) is
  replaced by `open/2`. Dunning keeps its gate/watermark/mirror/entitlement logic
  verbatim, ADDITIONALLY opening/advancing (`reconcile/2`) and resolving
  (`recover/2`) an escalation alongside its existing best-effort lifecycle email —
  the escalation call is best-effort too (never re-decides, never aborts the main
  path, mirrors `Samen.Billing.Dunning`'s own posture).
  """

  require Ash.Query
  import Ash.Query

  @doc """
  Open (or advance) an escalation. **Idempotent-by-dedupe** (§7.2): an existing
  non-terminal escalation for the same `{org_id, kind, dedupe_key}` is advanced
  (deadline re-mirrored), never duplicated.

  `attrs`: `%{org_id: id, subject_ref: String.t(), kind: String.t(), dedupe_key:
  String.t(), deadline_at: DateTime.t(), chain: [step] | nil}` — `chain: nil` ⇒
  the default single-step org chain.
  """
  @spec open(map(), keyword()) :: {:ok, struct()} | {:error, term()}
  def open(attrs, opts \\ []) do
    with {:ok, {res, _repo}} <- wiring(opts) do
      org_id = fetch(attrs, :org_id)
      kind = fetch(attrs, :kind)
      dedupe_key = fetch(attrs, :dedupe_key)
      deadline_at = fetch(attrs, :deadline_at)

      cond do
        is_nil(org_id) or not is_binary(kind) or kind == "" ->
          {:error, :invalid_attrs}

        not is_binary(dedupe_key) or dedupe_key == "" ->
          {:error, :invalid_attrs}

        not match?(%DateTime{}, deadline_at) ->
          {:error, :invalid_attrs}

        true ->
          case existing_active(res, org_id, kind, dedupe_key) do
            {:ok, escalation} -> refresh(escalation, deadline_at)
            :none -> create(res, attrs, org_id, kind, dedupe_key, deadline_at)
          end
      end
    end
  end

  @doc """
  Resolve (or cancel) an escalation, ending the chain walk (§7.1: a
  resolved/cancelled/exhausted case never walks further steps). Accepts either
  the escalation id or the dedupe triple `{org_id, kind, dedupe_key}`.
  """
  @spec resolve(term() | {String.t(), String.t(), String.t()}, :resolved | :cancelled, keyword()) ::
          {:ok, struct()} | {:error, :not_found | term()}
  def resolve(ref, outcome, opts \\ []) when outcome in [:resolved, :cancelled] do
    with {:ok, {res, _repo}} <- wiring(opts),
         {:ok, escalation} <- fetch_escalation(res, ref) do
      action = if outcome == :resolved, do: :resolve, else: :cancel

      escalation
      |> Ash.Changeset.for_update(action, %{}, authorize?: false)
      |> Ash.update()
    end
  end

  # ---------------------------------------------------------------------------

  defp create(res, attrs, org_id, kind, dedupe_key, deadline_at) do
    create_attrs = %{
      org_id: org_id,
      kind: kind,
      dedupe_key: dedupe_key,
      subject_ref: fetch(attrs, :subject_ref),
      deadline_at: deadline_at,
      chain: fetch(attrs, :chain)
    }

    res
    |> Ash.Changeset.for_create(:open, create_attrs, authorize?: false)
    |> Ash.create()
  end

  defp refresh(escalation, deadline_at) do
    escalation
    |> Ash.Changeset.for_update(:refresh, %{deadline_at: deadline_at}, authorize?: false)
    |> Ash.update()
  end

  defp existing_active(res, org_id, kind, dedupe_key) do
    res
    |> filter(org_id == ^org_id and kind == ^kind and dedupe_key == ^dedupe_key)
    |> filter(state in [:open, :escalating])
    |> limit(1)
    |> Ash.read(authorize?: false)
    |> case do
      {:ok, [escalation]} -> {:ok, escalation}
      _other -> :none
    end
  end

  defp fetch_escalation(res, {org_id, kind, dedupe_key}) do
    res
    |> filter(org_id == ^org_id and kind == ^kind and dedupe_key == ^dedupe_key)
    |> limit(1)
    |> Ash.read(authorize?: false)
    |> case do
      {:ok, [escalation]} -> {:ok, escalation}
      {:ok, []} -> {:error, :not_found}
      {:error, _reason} -> {:error, :not_found}
    end
  end

  defp fetch_escalation(res, escalation_id) do
    case Ash.get(res, escalation_id, authorize?: false) do
      {:ok, escalation} -> {:ok, escalation}
      {:error, _reason} -> {:error, :not_found}
    end
  end

  defp fetch(map, key), do: Map.get(map, key) || Map.get(map, to_string(key))

  @spec wiring(keyword()) :: {:ok, {module(), module()}} | {:error, :no_automation_module}
  defp wiring(opts) do
    res = opt(opts, :escalation_module)
    repo = opt(opts, :repo) || res_repo(res)

    cond do
      is_nil(res) -> {:error, :no_automation_module}
      is_nil(repo) -> {:error, :no_automation_module}
      true -> {:ok, {res, repo}}
    end
  end

  defp res_repo(nil), do: nil

  defp res_repo(res) do
    AshPostgres.DataLayer.Info.repo(res)
  rescue
    _ -> nil
  end

  defp opt(opts, key) do
    Keyword.get(opts, key) || Keyword.get(config(), key)
  end

  defp config, do: Application.get_env(:samen_core, __MODULE__, [])
end
