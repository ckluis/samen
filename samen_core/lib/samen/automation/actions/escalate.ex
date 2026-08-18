defmodule Samen.Automation.Actions.Escalate do
  @moduledoc """
  ADR-039 §5.2 #6 — `escalate`: builds DIRECTLY on the T41 E5 primitive
  (`Samen.Automation.Escalate.open/2`) — NO stub phase (T40's `blocked_by` edge
  on T41 exists precisely so the criteria-satisfied-while-stubbed window never
  exists, per the T40 handoff plan-gate note). Opens (or idempotently advances)
  a `kind: "automation"` escalation deduped on
  `"wf:" <> workflow_id <> ":" <> subject_ref` — one escalation per workflow per
  subject (the `Samen.Automation.Escalate.open/2` dedupe-by-`{org_id, kind,
  dedupe_key}` contract, ADR-039 §7.2).

  `undo/3` resolves the opened escalation `:cancelled` — a MEANINGFUL
  compensation (the primitive's chain walk stops; ADR-037 §5.7).
  """

  @behaviour Samen.Automation.Action

  alias Samen.Automation.Context

  @impl true
  def kind, do: :escalate

  @impl true
  def validate(config, _resource_key) when is_map(config) do
    minutes = config["deadline_minutes"]
    chain = config["chain"]

    cond do
      not is_integer(minutes) or minutes < 0 ->
        {:error, :invalid_deadline_minutes}

      not (is_nil(chain) or is_list(chain)) ->
        {:error, :invalid_chain}

      true ->
        {:ok, %{"deadline_minutes" => minutes, "chain" => chain}}
    end
  end

  def validate(_config, _resource_key), do: {:error, :invalid_config}

  @impl true
  def run(config, %Context{} = ctx) do
    minutes = config["deadline_minutes"] || 0

    deadline_at =
      DateTime.utc_now() |> DateTime.add(minutes * 60, :second) |> DateTime.truncate(:second)

    attrs = %{
      org_id: ctx.org_id,
      subject_ref: ctx.subject_ref,
      kind: "automation",
      dedupe_key: "wf:" <> ctx.workflow_id <> ":" <> to_string(ctx.subject_ref),
      deadline_at: deadline_at,
      chain: config["chain"]
    }

    case Samen.Automation.Escalate.open(attrs) do
      {:ok, escalation} -> {:ok, %{kind: :escalate, escalation_id: to_string(escalation.id)}}
      {:error, :no_automation_module} -> {:error, :escalate_unwired}
      {:error, reason} -> {:error, error_kind(reason)}
    end
  end

  @impl true
  def undo(_config, %{escalation_id: escalation_id}, _ctx) when is_binary(escalation_id) do
    case Samen.Automation.Escalate.resolve(escalation_id, :cancelled) do
      {:ok, _escalation} -> :ok
      _other -> :ok
    end
  end

  def undo(_config, _meta, _ctx), do: :ok

  defp error_kind(reason) when is_atom(reason), do: reason
  defp error_kind(_), do: :escalate_failed
end
