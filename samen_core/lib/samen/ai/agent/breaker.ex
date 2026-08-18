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

  > **The cross-tenant blast radius is CLOSED at A5.** A2/A3 counted the rate per org
  > but threw the HOST-LEVEL kill, so one org crossing its own 60-runs/hour threshold
  > stopped agent runs for EVERY org on the host until a human re-armed. A5 narrows the
  > trip to exactly the offending `{org, agent definition}`: `check_start/2` writes a
  > durable `Samen.AI.Agent.Kill` row (`kill_definition/4`) instead of throwing the host
  > switch, so a noisy tenant no longer halts the fleet. **Nothing automatic touches the
  > host-level switch any more** — it is the operator's explicit global emergency stop
  > and nothing else. Fail-closed is preserved in the narrowed scope: the tripped
  > tenant's definition refuses new runs AND stops its in-flight runs at their next turn
  > boundary, and only an explicit operator re-arm clears it.

  ## The durable per-definition kill (A5 — `Samen.AI.Agent.Kill`)

  `kill_definition/4` / `rearm_definition/3` write a real table row per
  `{org_id, agent}` — durable across a restart, unlike the node-lifetime
  `:persistent_term` switch A2 shipped, and readable by the operator surface as STATE
  rather than reconstructed from an audit log. `killed?/2` is the composite check the
  loop and `check_start/2` both use: host switch OR this org's definition row. A row
  read that FAILS is treated as KILLED (fail-closed) — a kill switch that cannot be
  read must never be assumed off. Trips never self-heal; `rearm_definition/3` is the
  only thing that clears one, and the row retains its own history.

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

  The HOST-level runtime switch + the provider-trip streaks still live in
  `:persistent_term` — node-lifetime state, NOT restart-durable. That is deliberate for
  both: the host switch is a global operator lever (its deploy-durable half is the
  config `kill_switch:` key), and a provider trip is a transient-outage park that SHOULD
  re-evaluate after a restart rather than outlive the outage. The **per-definition kill
  is durable** (`Samen.AI.Agent.Kill`, above) because it is the one that carries a
  tenant-visible policy decision — a rate trip or an operator's targeted stop — which
  must not be silently cleared by a redeploy. A5 closes the A2/A3 residual exactly
  there; the two node-lifetime halves are named, not hidden.
  """

  require Logger
  require Ash.Query

  alias Samen.AI.Agent.Kill
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
      killed?(org_id, agent_name) ->
        {:error, :killed}

      provider_tripped?(agent_name) ->
        {:error, :provider_tripped}

      rate_exceeded?(org_id) ->
        # A5: the same kill action a human operator uses — but the PER-DEFINITION one,
        # reason "rate_tripped", idempotent (an upsert), durable, audited. A2/A3 threw
        # the HOST switch here, which stopped every other tenant's agents too; that
        # cross-tenant blast radius is gone. Only ever trips; re-arming is
        # explicit-operator-only.
        kill_definition(org_id, agent_name, :rate_tripped, org_id: org_id)
        {:error, :rate_tripped}

      true ->
        :ok
    end
  end

  # ---------------------------------------------------------------------------
  # The DURABLE per-{org, definition} kill (A5 — the A2/A3 blast-radius residual)
  # ---------------------------------------------------------------------------

  @doc """
  The composite kill check for one `{org_id, agent_name}`: the HOST-level switch (the
  operator's explicit global stop) OR this org's durable per-definition row. This is
  what `check_start/2` and the loop's per-turn re-check both consult — fail-closed on
  either half.
  """
  @spec killed?(String.t() | nil, String.t() | nil) :: boolean()
  def killed?(org_id, agent_name) do
    killed?() or definition_killed?(org_id, agent_name)
  end

  @doc """
  Is `{org_id, agent_name}` durably killed? A row counts as ACTIVE while it has no
  `rearmed_at`, or its `killed_at` is at/after the `rearmed_at` (a re-trip after a
  re-arm).

  **Fail-CLOSED on a read failure**: an unreachable/unmigrated kill table answers
  `true`. A kill switch whose state cannot be read must never be assumed off — the
  opposite of the rate COUNT, which is observability and degrades to "no trip".
  """
  @spec definition_killed?(String.t() | nil, String.t() | nil) :: boolean()
  def definition_killed?(org_id, agent_name)
      when is_binary(org_id) and is_binary(agent_name) do
    Kill
    |> Ash.Query.filter(org_id == ^org_id and agent == ^agent_name)
    |> Ash.Query.limit(1)
    |> Ash.read(authorize?: false)
    |> case do
      {:ok, [row]} -> active_kill?(row)
      {:ok, []} -> false
      {:error, _} -> true
    end
  rescue
    e ->
      Logger.debug("[Samen.AI.Agent.Breaker] kill read failed: #{Exception.message(e)}")
      true
  end

  def definition_killed?(_org_id, _agent_name), do: false

  @doc "Is this kill ROW currently active (never re-armed, or re-tripped after a re-arm)?"
  @spec active_kill?(map()) :: boolean()
  def active_kill?(%{killed_at: %DateTime{} = killed_at, rearmed_at: rearmed_at}) do
    case rearmed_at do
      %DateTime{} = rearmed -> DateTime.compare(killed_at, rearmed) != :lt
      _ -> true
    end
  end

  def active_kill?(_row), do: false

  @doc """
  Throw the DURABLE per-definition kill for `{org_id, agent_name}`. Idempotent (an
  upsert on the `{org_id, agent}` identity — a repeated trip refreshes the row rather
  than piling up), audited token-only. `reason` is bounded to the closed set the
  resource constrains (`:operator | :rate_tripped | :provider_tripped`); anything else
  degrades to `:operator` rather than rejecting the trip — a kill must never fail
  because its label was unexpected.

  Opts: `:actor_id` (the deciding operator, recorded on the row + the audit line),
  `:org_id` (audit correlation).
  """
  @spec kill_definition(String.t(), String.t(), atom(), keyword()) :: :ok | {:error, term()}
  def kill_definition(org_id, agent_name, reason \\ :operator, opts \\ [])

  def kill_definition(org_id, agent_name, reason, opts)
      when is_binary(org_id) and is_binary(agent_name) do
    reason = bounded_reason(reason)
    actor_id = opts[:actor_id]

    Kill
    |> Ash.Changeset.for_create(:trip, %{
      org_id: org_id,
      agent: agent_name,
      reason: reason,
      killed_at: DateTime.utc_now(),
      killed_by: actor_id
    })
    |> Ash.create(authorize?: false)
    |> case do
      {:ok, _row} ->
        audit(
          "ai.agent.kill_definition agent=#{agent_name} reason=#{reason}",
          opts
          |> Keyword.put_new(:org_id, org_id)
          |> Keyword.put(:subject_id, definition_subject_id(org_id, agent_name))
        )

        :ok

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  def kill_definition(_org_id, _agent_name, _reason, _opts), do: {:error, :invalid_kill}

  @doc """
  Explicit operator re-arm of ONE `{org_id, agent_name}` (trips never self-heal, §6).
  A definition that was never killed is a no-op `:ok` — re-arming is idempotent.
  """
  @spec rearm_definition(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def rearm_definition(org_id, agent_name, opts \\ [])

  def rearm_definition(org_id, agent_name, opts)
      when is_binary(org_id) and is_binary(agent_name) do
    Kill
    |> Ash.Query.filter(org_id == ^org_id and agent == ^agent_name)
    |> Ash.Query.limit(1)
    |> Ash.read(authorize?: false)
    |> case do
      {:ok, [row]} ->
        row
        |> Ash.Changeset.for_update(:rearm, %{
          rearmed_at: DateTime.utc_now(),
          rearmed_by: opts[:actor_id]
        })
        |> Ash.update!(authorize?: false)

        audit(
          "ai.agent.rearm_definition agent=#{agent_name}",
          opts
          |> Keyword.put_new(:org_id, org_id)
          |> Keyword.put(:subject_id, definition_subject_id(org_id, agent_name))
        )

        :ok

      {:ok, []} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  def rearm_definition(_org_id, _agent_name, _opts), do: {:error, :invalid_kill}

  @doc """
  Every durable kill row for one org (the operator surface's read; token-only), or
  `{:error, :unavailable}` when the kill table cannot be read at all.

  A6 (the A5 verifier's R-A5-4): the GATE was already fail-CLOSED on an unreadable kill
  row (`definition_killed?/2` answers `true`), but the DISPLAY collapsed the same failure
  to `[]` — so the operator surface rendered a definition as `active` while every run of
  it was being refused `:killed`. That is the fail-honest contract inverted (ADR-014/024/
  026: a read that could not happen never reports an empty success). This is the honest
  read; `kills/1` keeps the lossy `[]` shape for callers that only aggregate.
  """
  @spec kills_status(String.t()) :: {:ok, [map()]} | {:error, :unavailable}
  def kills_status(org_id) when is_binary(org_id) do
    Kill
    |> Ash.Query.filter(org_id == ^org_id)
    |> Ash.Query.sort(killed_at: :desc)
    |> Ash.Query.limit(200)
    |> Ash.read(authorize?: false)
    |> case do
      {:ok, rows} -> {:ok, rows}
      _ -> {:error, :unavailable}
    end
  rescue
    _ -> {:error, :unavailable}
  end

  def kills_status(_org_id), do: {:error, :unavailable}

  @doc "Every durable kill row for one org (token-only). `[]` also means 'unreadable' —
  use `kills_status/1` when the difference matters (it does on any DISPLAY surface)."
  @spec kills(String.t()) :: [map()]
  def kills(org_id) do
    case kills_status(org_id) do
      {:ok, rows} -> rows
      _ -> []
    end
  end

  defp bounded_reason(reason) when reason in [:operator, :rate_tripped, :provider_tripped],
    do: to_string(reason)

  defp bounded_reason(reason) when reason in ["operator", "rate_tripped", "provider_tripped"],
    do: reason

  defp bounded_reason(_reason), do: "operator"

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

  # The audit SUBJECT of a per-{org, definition} kill is that definition, not the host
  # (A6; the A5 verifier's R-A5-5 minor). A2/A5 filed every breaker line against the one
  # host subject `"samen:ai_agent:host"`, so a targeted tenant kill and the global
  # emergency stop were indistinguishable by subject — and a per-definition kill history
  # could only be reconstructed by parsing `detail`. Token-only by construction: an org
  # uuid and the bounded definition NAME, both already on the row.
  defp definition_subject_id(org_id, agent_name),
    do: "samen:ai_agent:#{org_id}:#{agent_name}"

  # Token-only audit line (ids/enums/counts — the Automation.Breaker/Health shape).
  # Best-effort: observability never blocks or crashes the switch. `:subject_id` defaults
  # to the HOST switch's subject — which is correct for `kill/2`/`rearm/1` (they ARE the
  # host lever) and overridden by the per-definition callers above.
  defp audit(detail, opts) do
    repo = AshPostgres.DataLayer.Info.repo(Run, :mutate)

    if repo do
      Samen.AuditEvent.insert(repo, %{
        event_type: "system",
        subject_id: Keyword.get(opts, :subject_id) || "samen:ai_agent:host",
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
