defmodule Samen.WebTest.AgentFixture do
  @moduledoc """
  Agent-run fixtures for the A5 surface + masking tests (ADR-047).

  Rows are created through the KERNEL's own governed actions (`Samen.AI.Agent.Run`'s
  `:start` / `:begin` / terminal transitions), never by raw SQL, so the vault-routed
  `:transcript` really is routed on write — the domain column holds a `vt_*` token and
  the plaintext lives inside the DEK envelope. That is what makes the masking proofs
  non-vacuous: the surface has to resolve a genuine `%Samen.Masked{}` through
  `Samen.Api.PiiResolution`, exactly as it does in production.
  """

  alias Samen.AI.Agent.Run
  alias Samen.AI.Agent.Turn

  @doc """
  Create one agent run. Opts: `:agent`, `:owner_id`, `:goal`, `:lines`, `:pending`
  (the parked write proposal map), `:state` (`:queued | :running | :succeeded |
  :failed | :budget_exhausted | :cancelled | :awaiting_approval | :rejected | :expired`),
  `:error_kind`, `:current_turn`.
  """
  def run!(org_id, opts \\ []) do
    goal = Keyword.get(opts, :goal, "why is shipment 4471 late?")
    lines = Keyword.get(opts, :lines, [])
    pending = Keyword.get(opts, :pending)

    transcript =
      %{"goal" => goal, "lines" => lines}
      |> then(fn m -> if pending, do: Map.put(m, "pending", pending), else: m end)
      |> Jason.encode!()

    run =
      Run
      |> Ash.Changeset.for_create(:start, %{
        org_id: org_id,
        agent: Keyword.get(opts, :agent, "support_triage"),
        agent_module: "Samen.WebTest.AgentFixture.NoSuchAgent",
        owner_id: Keyword.get(opts, :owner_id, "u:" <> org_id),
        origin: "user:test",
        depth: 0,
        chain: [],
        transcript: transcript,
        next_turn_at: DateTime.utc_now(),
        max_turns: 8,
        max_tool_calls: 12,
        max_input_tokens: 60_000,
        max_output_tokens: 8_000,
        deadline_seconds: 600,
        # ADR-048 §6's context WATERMARK, resolved on every real run by
        # `Samen.AI.Agent.resolve_budgets/2`; the fixture mints rows directly, so it
        # states the same default the kernel would (70% of `max_input_tokens`).
        context_cutoff_tokens: 42_000
      })
      |> Ash.create!(authorize?: false)

    run
    |> advance(Keyword.get(opts, :current_turn, 0))
    |> transition(Keyword.get(opts, :state, :running), Keyword.get(opts, :error_kind))
    |> reload!()
  end

  @doc "Re-read a run with `org_id` + the vault-routed transcript selected."
  def reload!(run) do
    require Ash.Query

    Run
    |> Ash.Query.filter(id == ^run.id)
    |> Ash.Query.ensure_selected([:org_id, :transcript])
    |> Ash.read!(authorize?: false)
    |> hd()
  end

  @doc "Record one bounded turn row for `run` (token-only — ADR-047 §6)."
  def turn!(run, attrs \\ %{}) do
    org_id = run.org_id

    Turn
    |> Ash.Changeset.for_create(
      :record,
      Map.merge(
        %{
          org_id: org_id,
          run_id: run.id,
          turn_index: 1,
          status: :done,
          tool_kind: "fetch_record",
          arg_keys: ["id", "resource"],
          input_tokens: 10,
          output_tokens: 4,
          duration_ms: 7,
          provider: "scripted",
          simulated: true
        },
        attrs
      )
    )
    |> Ash.create!(authorize?: false)
  end

  defp advance(run, 0), do: run

  defp advance(run, turn) do
    run
    |> Ash.Changeset.for_update(:advance, %{current_turn: turn})
    |> Ash.update!(authorize?: false)
  end

  defp transition(run, :queued, _kind), do: run

  defp transition(run, state, kind) do
    run = update!(run, :begin, %{started_at: DateTime.utc_now(), next_turn_at: DateTime.utc_now()})

    case state do
      :running -> run
      :succeeded -> update!(run, :succeed, %{})
      :failed -> update!(run, :fail, %{error_kind: kind || "provider_error"})
      :budget_exhausted -> update!(run, :exhaust, %{error_kind: kind || "max_turns"})
      :cancelled -> update!(run, :cancel, %{})
      :awaiting_approval -> update!(run, :park, %{next_turn_at: DateTime.utc_now()})
      :rejected -> run |> update!(:park, %{next_turn_at: DateTime.utc_now()}) |> update!(:reject, %{})
      :expired -> run |> update!(:park, %{next_turn_at: DateTime.utc_now()}) |> update!(:expire_due, %{})
    end
  end

  defp update!(run, action, attrs) do
    run
    |> Ash.Changeset.for_update(action, attrs)
    |> Ash.update!(authorize?: false)
  end
end
