defmodule LeaseTestAgents do
  @moduledoc false

  defmodule Probe do
    @moduledoc false
    use Samen.AI.Agent,
      name: "lease.probe",
      goal_prompt: "Work the goal step by step. Reply FINAL: <answer> when done."
  end
end

defmodule LeaseProbeProvider do
  @moduledoc """
  The scripted double, plus a probe taken at the START of every provider call (before the
  scripted entry runs): the call budget the loop handed the adapter, and how far in the future
  the run's `next_turn_at` lease lies at that moment. Delegation only — it mints nothing.
  """
  @behaviour Samen.AI.Provider

  require Ash.Query

  @impl true
  def complete(%Samen.AI.MaskedPayload{} = payload, config) do
    org_id = :persistent_term.get({__MODULE__, :org})

    [run] =
      Samen.AI.Agent.Run
      |> Ash.Query.filter(org_id == ^org_id and state == :running)
      |> Ash.read!(authorize?: false)

    lease_left_ms = DateTime.diff(run.next_turn_at, DateTime.utc_now(), :millisecond)
    record({Map.get(config, :call_budget_ms), lease_left_ms, payload.system})
    Samen.AI.Provider.Scripted.complete(payload, config)
  end

  @impl true
  def embed(%Samen.AI.MaskedPayload{} = payload, config),
    do: Samen.AI.Provider.Scripted.embed(payload, config)

  @impl true
  def simulated?, do: true

  def probes, do: :persistent_term.get({__MODULE__, :probes}, []) |> Enum.reverse()

  def reset do
    :persistent_term.erase({__MODULE__, :probes})
    :persistent_term.erase({__MODULE__, :org})
  end

  defp record(probe) do
    key = {__MODULE__, :probes}
    :persistent_term.put(key, [probe | :persistent_term.get(key, [])])
  end
end

defmodule BudgetCaptureProvider do
  @moduledoc false
  @behaviour Samen.AI.Provider

  @impl true
  def complete(%Samen.AI.MaskedPayload{}, config) do
    send(self(), {:config, config})
    {:error, :not_configured}
  end

  @impl true
  def embed(%Samen.AI.MaskedPayload{}, _config), do: {:error, :not_implemented}
end

defmodule Samen.AI.AgentProviderLeaseTest do
  @moduledoc """
  ADR-047 §5.2a (2026-11-13 review, S2): a turn that is still inside its provider call can
  never be re-selected by the in-flight watchdog and called a second time.

  The `:agent_turn_due` scan selects a `:queued`/`:running` run whose `next_turn_at <= now()`.
  The loop re-stamps that lease to now + the watchdog before EVERY provider call a turn makes,
  and hands the adapter a budget for the call (retries and waits included) of half the
  watchdog. So at the start of every call the lease must lie further in the future than the
  call can last.

  The scenario is the one turn that makes FOUR provider calls (the D-05 ARM 2 shape in
  `agent_durability_test.exs`): turn 3's pre-turn summarize (refused), its first attempt
  (overflows), the ADR-048 Level-2 summarize, and the Level-2 retry. Each of the first three
  BACKDATES the lease to one second from now as it runs — modelling a call that used up the
  whole window — so the next call's lease is fresh only if the loop renewed it. No real time
  passes; the adapter half (the budget holding across retries and sleeps under an injected
  clock) is `samen_anthropic/test/provider_test.exs`.
  """
  use ExUnit.Case, async: false
  use Samen.AgentCase

  alias LeaseTestAgents.Probe
  alias Samen.AI.Agent
  alias Samen.AI.Agent.{Breaker, Run}
  alias Samen.AI.Provider.Scripted
  alias SamenCore.TestRepo

  require Ash.Query

  @bulk String.duplicate("shipment manifest line. ", 100)
  @short "acknowledged"
  @summary "Summary: the depot received seventeen crates on Tuesday."

  setup do
    Samen.TestSandbox.shared!(TestRepo)
    Scripted.reset()
    Breaker.reset()
    LeaseProbeProvider.reset()

    on_exit(fn ->
      Scripted.reset()
      Breaker.reset()
      LeaseProbeProvider.reset()
    end)

    :ok
  end

  # Runs inside the call (the scripted entry is evaluated at call time): the lease is set to
  # expire one second from now, as if this call had taken the whole watchdog window.
  defp backdating(org_id, entry) do
    fn ->
      [run] =
        Run
        |> Ash.Query.filter(org_id == ^org_id and state == :running)
        |> Ash.read!(authorize?: false)

      run
      |> Ash.Changeset.for_update(:advance, %{next_turn_at: DateTime.add(DateTime.utc_now(), 1)})
      |> Ash.update!(authorize?: false)

      entry
    end
  end

  test "Samen.AI.complete/4 hands the call budget to the adapter, and a caller can only tighten a host's" do
    s = %Samen.Scope{
      actor: %{id: "u:x", org_id: Ash.UUID.generate(), role: :member, plane: :tenant}
    }

    for {host, opt, expected} <- [
          {%{}, 5_000, 5_000},
          {%{call_budget_ms: 1_000}, 5_000, 1_000},
          {%{call_budget_ms: 10_000}, 5_000, 5_000},
          {%{call_budget_ms: 10_000}, nil, 10_000},
          {%{call_budget_ms: 10_000}, -1, 10_000},
          {%{}, nil, nil}
        ] do
      opts = if opt, do: [call_budget_ms: opt], else: []
      Samen.AI.complete(s, ["x"], %{}, [{:provider, {BudgetCaptureProvider, host}} | opts])
      assert_received {:config, config}
      assert Map.get(config, :call_budget_ms) == expected, inspect({host, opt})
    end
  end

  test "before EVERY provider call of a turn the lease outlasts the call's budget, and the budget is below the watchdog" do
    org_id = Ash.UUID.generate()
    s = %Samen.Scope{actor: %{id: "u:#{org_id}", org_id: org_id, role: :member, plane: :tenant}}
    :persistent_term.put({LeaseProbeProvider, :org}, org_id)

    script([
      {:continue, @bulk},
      {:continue, @short},
      # turn 3: pre-turn summarize (refused), attempt 1 (overflow), Level-2 summarize, retry
      backdating(org_id, {:error, :provider_error}),
      backdating(org_id, {:error, :context_overflow}),
      backdating(org_id, {:continue, @summary}),
      {:continue, @summary},
      {:continue, @short}
    ])

    Agent.run(Probe, s, "goal",
      provider: {LeaseProbeProvider, %{}},
      budgets: [max_turns: 4, context_cutoff_tokens: 200]
    )

    probes = LeaseProbeProvider.probes()
    budget = Agent.provider_call_budget_ms()

    # The scenario really is four calls in ONE turn, two of them summarizer calls (else the
    # backdates below would be re-armed by a commit and prove nothing).
    assert length(probes) == 7
    turn3 = Enum.slice(probes, 2, 4)

    assert Enum.map(turn3, fn {_b, _l, system} -> system == [Agent.summarizer_prompt()] end) ==
             [true, false, true, false]

    # The budget is derived from the watchdog and leaves it a margin.
    assert budget == div(Agent.inflight_watchdog_seconds() * 1000, 2)
    assert budget < Agent.inflight_watchdog_seconds() * 1000

    for {{call_budget, lease_left_ms, _system}, n} <- Enum.with_index(probes, 1) do
      assert call_budget == budget, "call #{n} reached the adapter without the call budget"

      # THE property: for the whole of a call that ends within `budget`, `next_turn_at` is
      # still in the future, so the due-scan cannot select the run and re-call the provider.
      assert lease_left_ms > budget,
             "call #{n} started with the lease #{lease_left_ms} ms from expiry, under its " <>
               "#{budget} ms budget: the watchdog could re-pick this turn mid-call"
    end
  end
end
