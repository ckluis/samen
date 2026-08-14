defmodule Samen.AI.Agent.Breaker do
  @moduledoc """
  The agent-plane circuit breakers + operator kill-switch (ADR-047 §6, batch A2 —
  the `Samen.Automation.Health`/`Breaker` shapes applied to agent runs).

  ## The host-level kill-switch (fail-closed)

  `killed?/0` is true when EITHER the static host config
  (`config :samen_core, Samen.AI.Agent, kill_switch: true` — the deploy-durable
  operator lever) OR the runtime switch (`kill/2`, node-lifetime state) is on. Switch
  on ⇒ `Samen.AI.Agent.run/4` / `start/4` refuse honestly (`{:error, :killed}`,
  nothing persisted) AND every in-flight run stops at its NEXT turn boundary — the
  loop re-checks `killed?/0` at every boundary, never only at run start (the
  `Automation.RunWorker` "already-queued half" lesson; sabotage 244's target).
  `rearm/1` is the ONLY thing that clears the runtime switch — trips never self-heal
  (§6: "re-arming is explicit-operator-only"); the config half clears only by config.

  ## Rate trip (§9#3 TAKEN: 60 runs/org/hour, host-configurable)

  Counted from the RUN LOG itself (`Samen.AI.Agent.Run` rows per org in the trailing
  hour — no second counter, the `Automation.Breaker` rule). Crossing the threshold
  trips the SAME kill action a human operator uses (`kill(:rate_tripped)`) —
  idempotently, audited — and the crossing run is refused `{:error, :rate_tripped}`.
  Refused runs are never persisted, so refusals do not feed the counter. The breaker
  assumes the budget ceilings it guards are SOFT by up to one turn (token budgets use
  `>` — the crossing turn completes and is billed); the run COUNT here is what trips,
  never the overshoot.

  > **Cross-tenant blast radius, named plainly (A3 fold of the A2 verifier finding).**
  > The rate COUNT is per-org, but the switch it throws is the HOST-LEVEL kill: **one
  > org crossing its own 60-runs/hour threshold stops agent runs for EVERY org on the
  > host** — in-flight runs terminate at their next turn boundary and new runs refuse
  > `{:error, :killed}` — until an operator explicitly re-arms (`rearm/1`; trips never
  > self-heal). This is the deliberate A2/A3 posture: fail-closed beats fail-open on a
  > brand-new spend-bearing AI surface, and a single host-level lever is auditable.
  > The residual is REAL and carried to **A5** alongside the durable
  > per-definition-kill column below: the operator surface ships a per-org /
  > per-definition trip so one noisy tenant no longer halts the fleet.

  ## Provider trip

  Consecutive normalized provider errors (`{:provider_error, _}` / `:not_configured`,
  already content-free per EG6) past `provider_trip_threshold/0` (default 5) PARK the
  agent definition — new runs for that agent refuse `{:error, :provider_tripped}` —
  rather than burning budget across every tenant during an outage. Fail-honest: the
  in-flight run's own error is surfaced unchanged; a success resets the streak;
  re-arming is explicit (`rearm/1` clears every parked definition).

  ## Fail-safe counting, fail-closed switching

  The rate COUNT is observability over the run log: a broken count degrades to "no
  trip" and never blocks or crashes a run (the `Automation.Breaker` rescue posture).
  The SWITCH itself is fail-closed: once on, everything refuses until an explicit
  re-arm. Kill/re-arm/trip are audited token-only via `Samen.AuditEvent` (best-effort,
  never load-bearing).

  ## Durability, stated honestly

  The runtime switch + provider-trip streaks live in `:persistent_term` — node-lifetime
  state, NOT restart-durable (a restart is itself an explicit operator action; the
  config `kill_switch:` half IS deploy-durable, and a rate condition that still holds
  after a restart re-trips on the next crossing run because the run log is the
  counter). A durable per-definition kill column is A5's operator-surface residual.
  """

  require Logger
  require Ash.Query

  alias Samen.AI.Agent.Run

  @kill_key {__MODULE__, :kill}
  @trip_key_prefix {__MODULE__, :provider_trip}

  @default_rate_limit_per_org_hour 60
  @rate_window_seconds 3600
  @default_provider_trip_threshold 5

  # ---------------------------------------------------------------------------
  # The kill-switch
  # ---------------------------------------------------------------------------

  @doc "Is the host-level agent kill-switch ON (config half OR runtime half)? Fail-closed."
  @spec killed?() :: boolean()
  def killed? do
    config_killed?() or :persistent_term.get(@kill_key, nil) != nil
  end

  @doc "The active runtime kill reason (`:operator | :rate_tripped | …`), or `nil`."
  @spec kill_reason() :: atom() | nil
  def kill_reason do
    case :persistent_term.get(@kill_key, nil) do
      %{reason: reason} -> reason
      nil -> if config_killed?(), do: :operator, else: nil
    end
  end

  @doc """
  Throw the host-level kill-switch (idempotent — the FIRST reason sticks, the
  `Automation.Breaker` trip discipline). Audited token-only. Opts: `:actor_id`,
  `:org_id` (audit attribution only).
  """
  @spec kill(atom(), keyword()) :: :ok
  def kill(reason, opts \\ []) when is_atom(reason) do
    case :persistent_term.get(@kill_key, nil) do
      nil ->
        :persistent_term.put(@kill_key, %{reason: reason, at: DateTime.utc_now()})
        audit("ai.agent.kill reason=#{reason}", opts)
        :ok

      _already ->
        :ok
    end
  end

  @doc """
  Re-arm: clear the runtime kill-switch AND every parked provider-trip definition.
  Explicit-operator-only — nothing else ever re-arms (§6). The config `kill_switch:`
  half is NOT cleared here (it is deploy-state; audited as still-on when present).
  """
  @spec rearm(keyword()) :: :ok
  def rearm(opts \\ []) do
    :persistent_term.erase(@kill_key)

    for {key, _} <- :persistent_term.get(), match?({@trip_key_prefix, _}, key) do
      :persistent_term.erase(key)
    end

    audit("ai.agent.rearm config_kill_still_on=#{config_killed?()}", opts)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Run-start checks (the one gate `run/4` and `start/4` call)
  # ---------------------------------------------------------------------------

  @doc """
  May a new run start for `org_id` / `agent_name`? Checked BEFORE anything persists.
  Returns `:ok` or a bounded refusal:

    * `{:error, :killed}` — the kill-switch is on (fail-closed);
    * `{:error, :provider_tripped}` — this agent definition is parked;
    * `{:error, :rate_tripped}` — this org crossed the runs-per-hour threshold; the
      crossing ALSO throws the kill-switch (reason `:rate_tripped`, idempotent).
  """
  @spec check_start(String.t(), String.t()) ::
          :ok | {:error, :killed | :provider_tripped | :rate_tripped}
  def check_start(org_id, agent_name) do
    cond do
      killed?() ->
        {:error, :killed}

      provider_tripped?(agent_name) ->
        {:error, :provider_tripped}

      rate_exceeded?(org_id) ->
        # The same operator kill action a human uses, reason :rate_tripped, idempotent,
        # audited (§6). Only ever trips; re-arming is explicit-operator-only.
        kill(:rate_tripped, org_id: org_id)
        {:error, :rate_tripped}

      true ->
        :ok
    end
  end

  @doc "The configured runs/org/hour threshold (§9#3 TAKEN: default 60; host-tunable)."
  @spec rate_limit_per_org_hour() :: pos_integer()
  def rate_limit_per_org_hour do
    case agent_config()[:rate_limit_per_org_hour] do
      n when is_integer(n) and n > 0 -> n
      _ -> @default_rate_limit_per_org_hour
    end
  end

  @doc "Consecutive provider errors that park an agent definition (default 5; host-tunable)."
  @spec provider_trip_threshold() :: pos_integer()
  def provider_trip_threshold do
    case agent_config()[:provider_trip_threshold] do
      n when is_integer(n) and n > 0 -> n
      _ -> @default_provider_trip_threshold
    end
  end

  @doc "Is this agent definition parked by the provider trip?"
  @spec provider_tripped?(String.t()) :: boolean()
  def provider_tripped?(agent_name) do
    match?(%{tripped: true}, :persistent_term.get(trip_key(agent_name), nil))
  end

  # ---------------------------------------------------------------------------
  # Provider-trip streak notes (called by the engine per turn outcome)
  # ---------------------------------------------------------------------------

  @doc "Note a NORMALIZED provider error for this agent; past the threshold, park it (audited)."
  @spec note_provider_error(String.t()) :: :ok
  def note_provider_error(agent_name) when is_binary(agent_name) do
    key = trip_key(agent_name)

    state =
      case :persistent_term.get(key, nil) do
        %{count: count} = state -> %{state | count: count + 1}
        nil -> %{count: 1, tripped: false}
      end

    state =
      if not state.tripped and state.count >= provider_trip_threshold() do
        audit("ai.agent.provider_tripped agent=#{agent_name} consecutive=#{state.count}", [])
        %{state | tripped: true}
      else
        state
      end

    :persistent_term.put(key, state)
    :ok
  end

  @doc "Note a provider success for this agent — resets the consecutive-error streak."
  @spec note_provider_ok(String.t()) :: :ok
  def note_provider_ok(agent_name) when is_binary(agent_name) do
    case :persistent_term.get(trip_key(agent_name), nil) do
      # A PARKED definition stays parked (re-arming is explicit-operator-only); an
      # un-tripped streak resets on success.
      %{tripped: true} -> :ok
      %{} -> :persistent_term.erase(trip_key(agent_name))
      nil -> :ok
    end

    :ok
  end

  @doc "Test/ops seam: clear ALL breaker state (runtime kill + every trip streak)."
  @spec reset() :: :ok
  def reset do
    :persistent_term.erase(@kill_key)

    for {key, _} <- :persistent_term.get(), match?({@trip_key_prefix, _}, key) do
      :persistent_term.erase(key)
    end

    :ok
  end

  # ---------------------------------------------------------------------------
  # Internal
  # ---------------------------------------------------------------------------

  defp trip_key(agent_name), do: {@trip_key_prefix, agent_name}

  defp config_killed? do
    agent_config()[:kill_switch] == true
  end

  defp agent_config, do: Application.get_env(:samen_core, Samen.AI.Agent, [])

  # Count this org's runs over the trailing window from the run log itself (no second
  # counter — the Automation.Breaker rule). Fail-safe: a broken COUNT degrades to "no
  # trip" and never blocks a run; the switch itself stays fail-closed.
  defp rate_exceeded?(org_id) do
    since = DateTime.add(DateTime.utc_now(), -@rate_window_seconds, :second)

    count =
      Run
      |> Ash.Query.filter(org_id == ^org_id)
      |> Ash.Query.filter(inserted_at >= ^since)
      |> Ash.count!(authorize?: false)

    count >= rate_limit_per_org_hour()
  rescue
    e ->
      Logger.debug("[Samen.AI.Agent.Breaker] rate count failed: #{Exception.message(e)}")
      false
  end

  # Token-only audit line (ids/enums/counts — the Automation.Breaker/Health shape).
  # Best-effort: observability never blocks or crashes the switch.
  defp audit(detail, opts) do
    repo = AshPostgres.DataLayer.Info.repo(Run, :mutate)

    if repo do
      Samen.AuditEvent.insert(repo, %{
        event_type: "system",
        subject_id: "samen:ai_agent:host",
        actor_id: opts[:actor_id],
        correlation_id: opts[:org_id],
        detail: detail
      })
    end

    :ok
  rescue
    _ -> :ok
  end
end
