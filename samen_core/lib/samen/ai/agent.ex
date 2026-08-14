defmodule Samen.AI.Agent do
  @moduledoc """
  `Samen.AI.Agent` — the first-party multi-turn agent loop over `Samen.AI.complete/4`
  (ADR-047 §3/§4/§6, batch A1: the loop core, keyless and tool-free).

  ## What A1 ships (and what it deliberately does not)

  A run executes **synchronously in the calling process**, turn by turn, against a durable
  `Samen.AI.Agent.Run` cursor + bounded `Samen.AI.Agent.Turn` log rows. Each turn calls
  `Samen.AI.complete/4` with the accumulated transcript threaded as `:history`, so
  `Samen.AI.Chokepoint`'s §3.2a per-turn re-scrub and the step-3/4 fail-closed allowlist
  scrub run over EVERY prior line on EVERY turn — engaged from the first batch, even though
  A1 is keyless and tool-free. Durability across restarts (Oban worker + never-nil
  `next_turn_at` watchdog + turn-row replay idempotency) is **A2**; the tool surface is
  **A3** (a definition declaring `tools:` is refused honestly at run start —
  `{:error, :tools_not_supported, run}` — never silently ignored); propose-then-approve
  writes are **A4**.

  ## INV-7 on the agent path (ADR-047 §4.3/§4.4; operator decision §9#2 TAKEN)

  **Agent runs are masked-only, categorically.** Every `complete/4` call this loop makes
  passes `grant_egress?: false` — appended LAST in `egress_opts/2` so no caller option can
  override it — because the transcript persists (A2) and INV-7 §7.2 forbids grant plaintext
  in any persisted egress. The loop never emits a `{:grant_span, …}` tag: history entries
  are exactly the prior turns' rendered assistant binaries (RP-AG-3's asserted property).
  A `vt_*` token in any accumulated line refuses `{:error, :pii_egress_refused}` at the
  chokepoint — fail-closed, run terminal `:failed`, nothing egressed.

  ## Fail-honest budgets (ADR-047 §6; §9#3 TAKEN — the floor is NON-configurable)

  Five budgets per run — `max_turns`, `max_tool_calls`, `max_input_tokens`,
  `max_output_tokens` (summed from `%Samen.AI.Completion{}.usage`), `deadline_seconds` —
  resolved defaults < host config (`config :samen_core, Samen.AI.Agent, budgets: [...]`) <
  agent definition < per-run opts, every value a positive integer. All five are checked at
  EVERY turn boundary (`over_budget/2`), alongside the durable cancel flag. Exhaustion is
  a terminal `:budget_exhausted` state with a bounded `error_kind` and the result
  `{:error, :budget_exhausted, run}` — **the last assistant turn is NEVER promoted to an
  answer** (RP-AG-6; sabotage 240 keeps this refutable). The honesty floor itself — the
  values are configurable, the never-a-partial-answer semantics are not.

  ## Terminal states (goal-met / budget-exhausted / cancelled / error)

  Dynamic next-step selection, A1 form: each completion either continues (its text joins
  the history) or finishes via the bounded `FINAL:` envelope (`parse_next/1`; the richer
  tool-call envelope grammar is A3's, per ADR-047 §10). `cancel/2` is durable
  (`cancel_requested_at` on the run row) and re-checked at EVERY turn boundary — never
  only at run start (RP-AG-8; sabotage 241) — so a cancel between turn N and N+1 stops
  turn N+1; the in-flight turn completes and is recorded honestly ("stopping after the
  current step").

  ## Token-only observability (EG6, ADR-047 §6)

  The run row, the turn rows, and the one terminal `Logger` line carry ids, enums, counts,
  and durations only — no prompt text, no completion text, ever. `safe_error_kind/1` is
  the closed-enum degrade (the `RunRecord.bounded_outcomes/1` posture): an unknown reason
  becomes `:unknown`, never an `inspect`.

  ## Defining an agent

      defmodule MyApp.TriageAgent do
        use Samen.AI.Agent,
          name: "support_triage",
          goal_prompt: "Work the goal step by step. Reply FINAL: <answer> when done.",
          budgets: [max_turns: 4]
      end

      {:ok, %{answer: answer, run: run}} =
        Samen.AI.Agent.run(MyApp.TriageAgent, scope, "Why is shipment 4471 late?")

  The `use` macro validates the definition at compile time (name shape, `vt_`-free goal
  prompt — the EG5 authored-artifact posture, budget shape) and defines `definition/0`.
  """

  alias Samen.AI.Agent.Run
  alias Samen.AI.Agent.Turn
  alias Samen.AI.Completion

  @doc "The compile-time-validated agent definition (defined by `use Samen.AI.Agent`)."
  @callback definition() :: %{
              required(:name) => String.t(),
              required(:goal_prompt) => String.t(),
              required(:tools) => [String.t()],
              required(:budgets) => keyword()
            }

  # ADR-047 §9#3 TAKEN (ratified 2026-08-14): the default budget posture. Values are
  # host/definition/run configurable; the fail-honest floor is not.
  @default_budgets [
    max_turns: 8,
    max_tool_calls: 12,
    max_input_tokens: 60_000,
    max_output_tokens: 8_000,
    deadline_seconds: 600
  ]
  @budget_keys Keyword.keys(@default_budgets)

  # The bounded error-kind enum (closed — anything else degrades to :unknown, never an
  # inspect and never a rejected finalize).
  @error_kinds [
    :max_turns,
    :max_tool_calls,
    :max_input_tokens,
    :max_output_tokens,
    :deadline,
    :cancelled,
    :provider_error,
    :pii_egress_refused,
    :invalid_grounding_shape,
    :not_configured,
    :not_implemented,
    :tools_not_supported,
    :unknown
  ]

  # The A2 in-flight watchdog horizon (ADR-047 §4.1): while a turn executes, the durable
  # cursor stays selectable-by-due-scan at now + this many seconds.
  @inflight_watchdog_seconds 600

  @final_marker "FINAL:"
  @name_pattern ~r/\A[a-z0-9][a-z0-9_.\-]*\z/

  defmacro __using__(opts) do
    definition = validate_definition!(opts, __CALLER__)

    quote do
      @behaviour Samen.AI.Agent

      @samen_agent_definition unquote(Macro.escape(definition))

      @impl Samen.AI.Agent
      def definition, do: @samen_agent_definition
    end
  end

  # ------------------------------------------------------------------------------------
  # Public API

  @doc """
  Execute an agent run for `goal` (user free text) in the calling actor's `scope`,
  synchronously to a terminal state. Returns:

    * `{:ok, %{answer: answer, run: run, turns: n}}` — goal met (the model emitted the
      `FINAL:` envelope within budget);
    * `{:error, :budget_exhausted, run}` — a budget was exhausted; the run is terminal
      `:budget_exhausted` and NO partial answer is returned (the fail-honest floor);
    * `{:error, :cancelled, run}` — a durable cancel was honored at a turn boundary;
    * `{:error, reason, run}` — a provider/chokepoint error (bounded, EG6-normalized:
      `:not_configured`, `:pii_egress_refused`, `{:provider_error, provider}`, …); the
      run is terminal `:failed` with a bounded `error_kind`;
    * `{:error, reason}` — the run could not start (`:org_scope_required`,
      `:invalid_goal`, `:invalid_budgets`).

  ## Options

    * `:budgets` — per-run budget overrides (positive integers; see moduledoc precedence)
    * `:provider` — `{module, config}` provider override, threaded to `Samen.AI.complete/4`
      (tests inject `Samen.AI.Provider.Scripted` here)
    * `:origin` — a bounded provenance ref (defaults to `"user:<actor id>"`)

  `:grant_egress?` and `:history` are NOT caller options: the loop owns both
  (`egress_opts/2` — §4.4 masked-only, categorically).
  """
  @spec run(module(), Samen.Scope.t(), String.t(), keyword()) ::
          {:ok, %{answer: String.t(), run: Ash.Resource.record(), turns: non_neg_integer()}}
          | {:error, term(), Ash.Resource.record()}
          | {:error, term()}
  def run(agent_mod, scope, goal, opts \\ [])

  def run(agent_mod, %Samen.Scope{} = scope, goal, opts)
      when is_atom(agent_mod) and is_list(opts) do
    definition = agent_mod.definition()

    with {:ok, org_id} <- scope_org(scope),
         :ok <- validate_goal(goal),
         {:ok, budgets} <- resolve_budgets(definition, opts) do
      run =
        Run
        |> Ash.Changeset.for_create(
          :start,
          Map.merge(
            %{
              org_id: org_id,
              agent: definition.name,
              origin: Keyword.get(opts, :origin, default_origin(scope)),
              depth: 0,
              chain: []
            },
            Map.new(budgets)
          )
        )
        |> Ash.create!(authorize?: false)

      # A1 boundary, fail-honest: the tool surface is A3. A definition that declares tools
      # must be REFUSED, never silently run tool-less as if its tools had been offered.
      if definition.tools != [] do
        {:error, :tools_not_supported, terminal!(run, :fail, :tools_not_supported)}
      else
        run = begin!(run)
        loop(run, scope, definition, goal, [], opts)
      end
    end
  end

  def run(_agent_mod, _scope, _goal, _opts), do: {:error, :invalid_scope}

  @doc """
  Durably request cancellation of a run (RP-AG-8). Org-scoped: the run is loaded through
  the caller's scope (`Samen.Policy.OrgScope` — a foreign org's run does not exist). Sets
  `cancel_requested_at`; the loop honors it at its NEXT turn boundary — the in-flight
  turn completes ("stopping after the current step", never "stopped"). Returns
  `{:ok, run}`, `{:error, :not_found}`, or `{:error, :already_terminal}`.
  """
  @spec cancel(Samen.Scope.t(), String.t()) ::
          {:ok, Ash.Resource.record()} | {:error, :not_found | :already_terminal | term()}
  def cancel(%Samen.Scope{} = scope, run_id) do
    case Ash.get(Run, run_id, scope: scope) do
      {:ok, %Run{state: state}} when state not in [:queued, :running] ->
        {:error, :already_terminal}

      {:ok, %Run{} = run} ->
        {:ok,
         run
         |> Ash.Changeset.for_update(:request_cancel, %{})
         |> Ash.update!(authorize?: false)}

      {:error, _} ->
        {:error, :not_found}
    end
  end

  @doc """
  The egress options the loop passes to EVERY `Samen.AI.complete/4` call. Pure and public
  so the §4.4 property is directly assertable: `:history` is exactly the accumulated
  rendered binaries, and `grant_egress?: false` is appended LAST — a caller-supplied
  override cannot re-enable grant plaintext on the agent path (masked-only, categorically;
  operator decision §9#2 TAKEN).
  """
  @spec egress_opts(keyword(), [String.t()]) :: keyword()
  def egress_opts(opts, history) do
    opts
    |> Keyword.take([:provider, :grounding, :meta, :env_reader])
    |> Keyword.put(:history, history)
    |> Keyword.put(:grant_egress?, false)
  end

  @doc """
  A1's bounded next-step envelope (dynamic next-step selection, tool-free form): a
  completion whose text opens with `FINAL:` ends the run with the remainder as the
  answer; anything else continues (the text joins the history). The richer tool-call
  envelope grammar is A3's (ADR-047 §10).
  """
  @spec parse_next(String.t()) :: {:final, String.t()} | {:continue, String.t()}
  def parse_next(text) when is_binary(text) do
    case String.trim_leading(text) do
      @final_marker <> rest -> {:final, String.trim(rest)}
      _ -> {:continue, text}
    end
  end

  @doc """
  Which budget (if any) is exhausted at this turn boundary (ADR-047 §6) — checked BEFORE
  every turn, so exhaustion can never silently truncate mid-answer: the turn that would
  overrun is never taken, and the last completed turn is never promoted. Returns a
  bounded error kind or `nil`.
  """
  @spec over_budget(Ash.Resource.record(), DateTime.t()) :: atom() | nil
  def over_budget(%Run{} = run, %DateTime{} = now) do
    cond do
      run.current_turn >= run.max_turns -> :max_turns
      run.tool_calls_used >= run.max_tool_calls -> :max_tool_calls
      run.input_tokens_used > run.max_input_tokens -> :max_input_tokens
      run.output_tokens_used > run.max_output_tokens -> :max_output_tokens
      deadline_passed?(run, now) -> :deadline
      true -> nil
    end
  end

  @doc """
  Degrade any failure reason to the bounded, closed error-kind enum (the
  `Samen.Automation.RunRecord.bounded_outcomes/1` posture): a member atom passes, a
  normalized `{:provider_error, _}` becomes `:provider_error`, anything else becomes
  `:unknown` — never an `inspect/1`, never a rejected finalize (EG6).
  """
  @spec safe_error_kind(term()) :: atom()
  def safe_error_kind(kind) when kind in @error_kinds, do: kind
  def safe_error_kind({:provider_error, _provider}), do: :provider_error
  def safe_error_kind(_other), do: :unknown

  @doc "The five resolved default budgets (§9#3 TAKEN). The honesty floor is not in here."
  @spec default_budgets() :: keyword()
  def default_budgets, do: @default_budgets

  # ------------------------------------------------------------------------------------
  # The loop (A1: synchronous; A2 moves execution into the Oban worker unchanged)

  defp loop(%Run{} = run, scope, definition, goal, history, opts) do
    # Reload the durable cursor at EVERY turn boundary: the cancel flag is durable state
    # another process may have set since the last turn (RP-AG-8 — sabotage 241's target).
    run = reload!(run)
    budget_kind = over_budget(run, DateTime.utc_now())

    cond do
      run.cancel_requested_at != nil ->
        run =
          run
          |> Ash.Changeset.for_update(:cancel, %{})
          |> Ash.update!(authorize?: false)

        log_terminal(run)
        {:error, :cancelled, run}

      budget_kind != nil ->
        # Fail-honest exhaustion (RP-AG-6): an explicit terminal state + a bounded kind.
        # `history` — including any last assistant text — is deliberately DROPPED, never
        # promoted to an answer (sabotage 240 keeps this refutable).
        run = terminal!(run, :exhaust, budget_kind)
        log_terminal(run)
        {:error, :budget_exhausted, run}

      true ->
        execute_turn(run, scope, definition, goal, history, opts)
    end
  end

  defp execute_turn(%Run{} = run, scope, definition, goal, history, opts) do
    {:ok, org_id} = scope_org(scope)
    turn_index = run.current_turn + 1
    started = System.monotonic_time(:millisecond)

    # Every provider-bound byte still routes kernel → chokepoint: prior turns re-enter
    # ONLY as `:history` (re-scrubbed per §3.2a + allowlist-scanned per §3.2 step 3/4,
    # every turn), and grant plaintext is categorically excluded (§4.4).
    result =
      Samen.AI.complete(scope, [definition.goal_prompt, goal], %{}, egress_opts(opts, history))

    duration_ms = System.monotonic_time(:millisecond) - started

    case result do
      {:ok, %Completion{} = completion} ->
        in_tokens = usage_int(completion.usage, :input_tokens)
        out_tokens = usage_int(completion.usage, :output_tokens)

        record_turn!(run, org_id, turn_index, %{
          status: :done,
          input_tokens: in_tokens,
          output_tokens: out_tokens,
          duration_ms: duration_ms,
          provider: bounded_provider(completion.provider),
          simulated: completion.simulated
        })

        run =
          run
          |> Ash.Changeset.for_update(:advance, %{
            current_turn: turn_index,
            next_turn_at: DateTime.add(DateTime.utc_now(), @inflight_watchdog_seconds),
            input_tokens_used: run.input_tokens_used + in_tokens,
            output_tokens_used: run.output_tokens_used + out_tokens
          })
          |> Ash.update!(authorize?: false)

        case parse_next(completion.text) do
          {:final, answer} ->
            run =
              run
              |> Ash.Changeset.for_update(:succeed, %{})
              |> Ash.update!(authorize?: false)

            log_terminal(run)
            {:ok, %{answer: answer, run: run, turns: run.current_turn}}

          {:continue, text} ->
            # The next-step decision is the model's (dynamic step selection): the turn's
            # rendered text joins the history — an ordinary untagged binary segment the
            # chokepoint re-scrubs on every subsequent turn.
            loop(run, scope, definition, goal, history ++ [text], opts)
        end

      {:error, reason} ->
        # Fail-honest error terminal (EG6): the bounded kind goes to the row; the
        # normalized reason (already content-free by the chokepoint) to the caller.
        kind = safe_error_kind(reason)

        record_turn!(run, org_id, turn_index, %{
          status: :failed,
          error_kind: to_string(kind),
          duration_ms: duration_ms
        })

        run = terminal!(run, :fail, kind)
        log_terminal(run)
        {:error, reason, run}
    end
  end

  # ------------------------------------------------------------------------------------
  # Durable-cursor writes (kernel-only, the Approvals trusted-API precedent)

  defp begin!(%Run{} = run) do
    now = DateTime.utc_now()

    run
    |> Ash.Changeset.for_update(:begin, %{
      started_at: now,
      next_turn_at: DateTime.add(now, @inflight_watchdog_seconds)
    })
    |> Ash.update!(authorize?: false)
  end

  defp terminal!(%Run{} = run, action, kind) do
    run = if run.state == :queued, do: begin!(run), else: run

    run
    |> Ash.Changeset.for_update(action, %{error_kind: to_string(safe_error_kind(kind))})
    |> Ash.update!(authorize?: false)
  end

  defp record_turn!(%Run{} = run, org_id, turn_index, attrs) do
    Turn
    |> Ash.Changeset.for_create(
      :record,
      Map.merge(attrs, %{org_id: org_id, run_id: run.id, turn_index: turn_index})
    )
    |> Ash.create!(authorize?: false)
  end

  defp reload!(%Run{} = run), do: Ash.get!(Run, run.id, authorize?: false)

  # The one terminal log line (EG6, ADR-047 §6): ids, enums, counts — token-only, never
  # prompt/completion text. The A1 no-text-in-logs test asserts on exactly this line.
  defp log_terminal(%Run{} = run) do
    require Logger

    Logger.info(
      "samen.ai.agent run=#{run.id} agent=#{run.agent} state=#{run.state} " <>
        "turns=#{run.current_turn} error_kind=#{run.error_kind || "none"} " <>
        "in_tokens=#{run.input_tokens_used} out_tokens=#{run.output_tokens_used}"
    )
  end

  # ------------------------------------------------------------------------------------
  # Validation / resolution

  defp scope_org(%Samen.Scope{actor: %{org_id: org_id}}) when is_binary(org_id),
    do: {:ok, org_id}

  # Fail-closed: an org-less actor starts nothing (the OrgScope posture).
  defp scope_org(_scope), do: {:error, :org_scope_required}

  defp default_origin(%Samen.Scope{actor: %{id: id}}) when is_binary(id), do: "user:" <> id
  defp default_origin(_scope), do: "user:unknown"

  defp validate_goal(goal) when is_binary(goal) and goal != "", do: :ok
  defp validate_goal(_), do: {:error, :invalid_goal}

  # Budget precedence: defaults < host config < agent definition < per-run opts. Every
  # value must be a positive integer; anything else refuses honestly (never a silent
  # fallback that would make a budget looser or tighter than the caller asked).
  defp resolve_budgets(definition, opts) do
    host = Application.get_env(:samen_core, __MODULE__, []) |> Keyword.get(:budgets, [])
    layers = [host, Map.get(definition, :budgets, []), Keyword.get(opts, :budgets, [])]

    if Enum.all?(layers, &valid_budget_layer?/1) do
      {:ok, Enum.reduce(layers, @default_budgets, &Keyword.merge(&2, &1))}
    else
      {:error, :invalid_budgets}
    end
  end

  defp valid_budget_layer?(layer) do
    Keyword.keyword?(layer) and
      Enum.all?(layer, fn {k, v} -> k in @budget_keys and is_integer(v) and v > 0 end)
  end

  defp deadline_passed?(%Run{started_at: %DateTime{} = started_at} = run, now),
    do: DateTime.diff(now, started_at, :second) >= run.deadline_seconds

  defp deadline_passed?(_run, _now), do: false

  defp usage_int(usage, key) when is_map(usage) do
    case Map.get(usage, key, 0) do
      n when is_integer(n) and n >= 0 -> n
      _ -> 0
    end
  end

  defp usage_int(_usage, _key), do: 0

  # `%Completion{}.provider` is a bounded adapter identifier atom (:scripted, :fake, …);
  # anything richer degrades to "unknown" — never payload content in a persisted column.
  defp bounded_provider(provider) when is_atom(provider) and not is_nil(provider),
    do: Atom.to_string(provider)

  defp bounded_provider(_), do: "unknown"

  # ------------------------------------------------------------------------------------
  # Compile-time definition validation (the `use` macro)

  defp validate_definition!(opts, caller) do
    name = Keyword.get(opts, :name)
    goal_prompt = Keyword.get(opts, :goal_prompt)
    tools = Keyword.get(opts, :tools, [])
    budgets = Keyword.get(opts, :budgets, [])

    unless is_binary(name) and Regex.match?(@name_pattern, name) do
      compile_error!(
        caller,
        "use Samen.AI.Agent requires `name:` — a bounded lowercase identifier " <>
          "(#{inspect(@name_pattern.source)}). Got: #{inspect(name)}"
      )
    end

    unless is_binary(goal_prompt) and goal_prompt != "" do
      compile_error!(
        caller,
        "use Samen.AI.Agent requires a non-empty `goal_prompt:` string (the authored, " <>
          "EG5-class goal prompt). Got: #{inspect(goal_prompt)}"
      )
    end

    # EG5 (ADR-043 §3.1): an authored prompt artifact may never embed a vt_ vault-token
    # sentinel — the same scan the Prompt resource + verifier check (c) apply.
    if String.contains?(goal_prompt, "vt_") do
      compile_error!(
        caller,
        "use Samen.AI.Agent: `goal_prompt:` contains a `vt_` vault-token sentinel — an " <>
          "authored prompt must never embed a raw vault FK token (ADR-043 §3.4 check (c))."
      )
    end

    unless is_list(tools) and Enum.all?(tools, &is_binary/1) do
      compile_error!(
        caller,
        "use Samen.AI.Agent: `tools:` must be a list of registry kind strings " <>
          "(ADR-047 §5.1; empty until batch A3 ships the tool surface). Got: #{inspect(tools)}"
      )
    end

    unless valid_budget_layer?(budgets) do
      compile_error!(
        caller,
        "use Samen.AI.Agent: `budgets:` must be a keyword list over " <>
          "#{inspect(@budget_keys)} with positive-integer values. Got: #{inspect(budgets)}"
      )
    end

    %{name: name, goal_prompt: goal_prompt, tools: tools, budgets: budgets}
  end

  defp compile_error!(caller, description) do
    raise %CompileError{file: caller.file, line: caller.line, description: description}
  end
end
