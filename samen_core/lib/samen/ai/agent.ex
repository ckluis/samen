defmodule Samen.AI.Agent do
  @moduledoc """
  `Samen.AI.Agent` — the first-party multi-turn agent loop over `Samen.AI.complete/4`
  (ADR-047 §3/§4/§6; batch A1: the loop core; batch A2: durability + erasure; batch A3:
  the read-tool surface + EG2 scrubbing).

  ## What A3 adds — governed tools (ADR-047 §4.2/§4.3/§5.1)

  A definition's `tools:` list now RESOLVES through the four-way narrowing intersection
  (`Samen.AI.Agent.Tools`: registry ∩ per-action `tool_schema/0` opt-in ∩ the declared
  list ∩ the owner actor's policy envelope at execution) — at run START (arms 1-3,
  fail-closed refusals persist nothing) and again PER CALL. One tool call per turn:
  native `%Completion{tool_calls:}` first, else the bounded `TOOL: {"tool": _, "args":
  _}` JSON envelope (`parse_next/1` — the A1 `FINAL:` grammar grown per §10). The EG2
  story hop-by-hop: tool DEFS ride the sealed payload's `:tools` field (compile-time
  static, chokepoint-scrubbed + static-membership-checked); model ARGS are vt_-scanned
  and validated by the action's own `validate/2` BEFORE execution; the governed action
  runs AS the owner actor (`Samen.AI.Agent.Context.build/2` — honest refusals recorded,
  never silent skips); the call ECHO + RESULT re-enter ONLY as
  `Samen.AI.Agent.ToolResult` rendered, PiiResolution-EGRESS-resolved binaries through
  the vault-routed transcript → `:history` (per-turn §3.2a re-scrub; `safe_segment?/1`
  fail-closed last line; vault-routed result fields render `••••` always — §9#2). The
  `{run_id, turn_index}` turn row gains the tool DECISION stamp (kind + arg key names +
  validated-args digest) committed before the tool fires; `tool_calls_used` now counts
  for real and `max_tool_calls` exhaustion is live. `effect: :write` tools refuse
  `:tools_not_supported` until A4 ships propose-then-approve.

  ## What A2 adds to the A1 loop

  The same turn engine now runs in **two modes over one durable cursor**:

    * `run/4` — A1's synchronous mode, unchanged in contract: execute to a terminal
      state in the calling process (tests, inline hosts);
    * `start/4` + `Samen.AI.Agent.TurnWorker` — the durable mode (ADR-047 §4.1(c)):
      the run row is created `:queued` and the FIRST worker job is enqueued via
      `Oban.insert` **inside the create's own transaction** (the
      `Samen.Automation.EventCapture` idiom — the job exists iff the row committed).
      The worker executes turns in batches of `turns_per_job/0` (default 4) and
      re-arms itself; the AshOban `:agent_turn_due` due-scan (on `Samen.AI.Agent.Run`)
      is the watchdog that recovers ANY lost job. `next_turn_at` is **never nil while
      the run is non-terminal** (the `Samen.Sequences` invariant), so a stalled run is
      always re-selectable. The run row is the SINGLE retry authority — the worker
      returns `:ok` to Oban for every business outcome (Sequences' rule).

  **Restart safety / turn-row replay (RP-AG-7).** Every turn writes two checkpoints:
  the **decision** — a `{run_id, turn_index}` `Samen.AI.Agent.Turn` row committed
  `:proposed` BEFORE the slow provider call — and the **outcome** — that same row
  finalized `:done`/`:failed` **in one DB transaction with the run-cursor advance**
  (so a `:done` row and the cursor can never disagree). A worker death mid-turn is
  recovered by the watchdog; the replay FINDS the existing `:proposed` row and REUSES
  it (`find_or_reuse_turn/3`, stamped `meta: %{"replayed" => true}`) — the
  `Samen.Sequences.find_or_create_step_send/2` row-reuse shape, and from A3 the reason
  a tool fires at most once per turn row. Posture stated plainly, as Sequences states
  it: **at-least-once, never claimed exactly-once** — the provider call between the
  two checkpoints can genuinely repeat; the turn row does not.

  ## The vault-routed transcript (A2 — §7.4; §9#2/#4 TAKEN)

  The run's accumulated history no longer lives in the executing process: goal + the
  rendered assistant lines persist as the run row's vault-routed `:transcript`
  (JSON `{"goal": _, "lines": [...]}`), inside the DEK envelope keyed on the run's own
  id. The engine reveals it at each turn boundary through the ONE decrypt chokepoint
  (`Samen.Vault.reveal/3`, bound `subject_id: run.id` — the `Samen.Identity.Totp`
  precedent) and threads the lines as `:history`, so `Samen.AI.Chokepoint`'s §3.2a
  re-scrub + step-3/4 allowlist scrub still run over EVERY prior line on EVERY turn.
  A shredded/unavailable transcript is a fail-honest terminal
  (`:transcript_unavailable`) — an erased run can never keep executing on cached text.
  Grant plaintext stays categorically excluded (`egress_opts/2` pins
  `grant_egress?: false` LAST; §4.4).

  ## Breakers + kill-switch (A2 — §6; `Samen.AI.Agent.Breaker`)

  `run/4` and `start/4` refuse at run start — and the loop re-checks the operator
  kill-switch at EVERY turn boundary (never only at run start — the
  `Automation.RunWorker` "already-queued half" lesson; sabotage 244's target):

    * host kill-switch ON ⇒ `{:error, :killed}` (fail-closed; in-flight runs stop at
      the next boundary, terminal `:failed`/`"killed"`);
    * the ratified 60-runs-per-org-hour rate trip (§9#3) — counted from the run log
      itself, no second counter; crossing it trips the SAME kill the operator uses,
      reason `:rate_tripped`, and re-arming is explicit-operator-only;
    * consecutive normalized provider errors park the agent definition
      (`{:error, :provider_tripped}`) rather than burning budget through an outage.

  ## Fail-honest budgets (§6; §9#3 TAKEN — the floor is NON-configurable)

  Five budgets per run, checked at EVERY turn boundary (`over_budget/2`) alongside the
  durable cancel flag and the kill-switch. Exhaustion is a terminal `:budget_exhausted`
  with a bounded `error_kind` — **the last assistant turn is NEVER promoted to an
  answer** (RP-AG-6; sabotage 240). Token budgets are deliberately soft by up to ONE
  turn (`over_budget/2` uses `>` on the summed counters — the turn that crosses the
  ceiling completes and is billed; the NEXT turn is refused); the breaker assumes soft
  ceilings and never treats the overshoot as a violation.

  ## Token-only observability (EG6, §6)

  The run row, the turn rows, and the one terminal `Logger` line carry ids, enums,
  counts, and durations only — no prompt text, no completion text, ever (the ONE text
  artifact is the vault-routed transcript above). `safe_error_kind/1` is the
  closed-enum degrade; `bounded_meta/1` is the map twin (the
  `RunRecord.bounded_outcomes/1` posture).

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

  alias Samen.AI.Agent.Breaker
  alias Samen.AI.Agent.Run
  alias Samen.AI.Agent.ToolResult
  alias Samen.AI.Agent.Tools
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
  # inspect and never a rejected finalize). A3 adds the TOOL kinds: the intersection
  # refusal (:tool_refused), the arg gates (:invalid_args, :invalid_tool_call), the
  # governed-action outcomes the two shipped read tools surface (:record_not_found,
  # :unknown_resource, :not_authorized, :no_org), the degrade (:tool_failed), and the
  # definition-resolution refusal (:invalid_tools).
  @error_kinds [
    :max_turns,
    :max_tool_calls,
    :max_input_tokens,
    :max_output_tokens,
    :deadline,
    :cancelled,
    :killed,
    :rate_tripped,
    :provider_tripped,
    :owner_unavailable,
    :agent_unresolvable,
    :transcript_unavailable,
    :turn_desync,
    :provider_error,
    :pii_egress_refused,
    :invalid_grounding_shape,
    :not_configured,
    :not_implemented,
    :tools_not_supported,
    :invalid_tools,
    :tool_refused,
    :invalid_args,
    :invalid_tool_call,
    :tool_failed,
    :record_not_found,
    :unknown_resource,
    :not_authorized,
    :no_org,
    :unknown
  ]

  # The in-flight watchdog horizon (ADR-047 §4.1): while a turn/batch executes, the
  # durable cursor stays selectable-by-due-scan at now + this many seconds — NEVER nil
  # (the Samen.Sequences MED-2 invariant).
  @inflight_watchdog_seconds 600

  # ADR-047 §4.1(c): turns executed per Oban job before the worker re-arms (deferred
  # tuning owned by A2; host-overridable via config :samen_core, Samen.AI.Agent).
  @default_turns_per_job 4

  @final_marker "FINAL:"
  @tool_marker "TOOL:"
  @name_pattern ~r/\A[a-z0-9][a-z0-9_.\-]*\z/

  # The vault FK-token sentinel: a model-emitted tool ARG carrying it is refused BEFORE
  # any execution (ADR-047 §4.3 — vault fields are structurally excluded from arg space;
  # the shipped sabotage-45 tuple hole, re-proven on the agent path at A3).
  @vt_sentinel "vt_"

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
  synchronously to a terminal state (the A1 mode, contract unchanged). Returns:

    * `{:ok, %{answer: answer, run: run, turns: n}}` — goal met (the model emitted the
      `FINAL:` envelope within budget);
    * `{:error, :budget_exhausted, run}` — a budget was exhausted; the run is terminal
      `:budget_exhausted` and NO partial answer is returned (the fail-honest floor);
    * `{:error, :cancelled, run}` — a durable cancel was honored at a turn boundary;
    * `{:error, :killed, run}` — the operator kill-switch stopped the run at a turn
      boundary (fail-closed; A2);
    * `{:error, reason, run}` — a provider/chokepoint error (bounded, EG6-normalized);
      the run is terminal `:failed` with a bounded `error_kind`;
    * `{:error, reason}` — the run could not start (`:org_scope_required`,
      `:invalid_goal`, `:invalid_budgets`, A2's breaker refusals — `:killed`,
      `:rate_tripped`, `:provider_tripped` — and A3's tool-resolution refusals:
      `:invalid_tools` for a declared kind that is unregistered or not opted in,
      `:tools_not_supported` for a declared `effect: :write` tool before A4;
      nothing is persisted for a refusal).

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
         {:ok, budgets} <- resolve_budgets(definition, opts),
         # A3 (ADR-047 §5.1): intersection arms 1-3 resolve at run start, fail-closed —
         # a definition declaring an unregistered / non-opted-in / write-effect tool is
         # REFUSED before anything persists (never silently run with fewer tools than
         # declared, never a tool the registry+opt-in did not admit).
         {:ok, tools} <- Tools.resolve_definition(definition),
         :ok <- Breaker.check_start(org_id, definition.name) do
      run = create_run!(agent_mod, definition, org_id, scope, goal, budgets, opts)
      run = begin!(run)
      loop(run, scope, definition, Keyword.put(opts, :resolved_tools, tools), :infinity)
    end
  end

  def run(_agent_mod, _scope, _goal, _opts), do: {:error, :invalid_scope}

  @doc """
  Start a DURABLE agent run (A2, ADR-047 §4.1(c)): create the run row `:queued` — with
  its vault-routed transcript seeded and its `next_turn_at` watchdog ARMED — and
  enqueue the first `Samen.AI.Agent.TurnWorker` job via `Oban.insert` **inside the
  create's own transaction** (the `EventCapture` idiom: the job exists iff the row
  committed; a lost/failed enqueue is recovered by the `:agent_turn_due` watchdog).
  Returns `{:ok, run}` (the `:queued` cursor) or the same start refusals as `run/4`
  (`{:error, :killed | :rate_tripped | :provider_tripped | …}` — nothing persisted).
  """
  @spec start(module(), Samen.Scope.t(), String.t(), keyword()) ::
          {:ok, Ash.Resource.record()} | {:error, term()}
  def start(agent_mod, scope, goal, opts \\ [])

  def start(agent_mod, %Samen.Scope{} = scope, goal, opts)
      when is_atom(agent_mod) and is_list(opts) do
    definition = agent_mod.definition()

    with {:ok, org_id} <- scope_org(scope),
         :ok <- validate_goal(goal),
         {:ok, budgets} <- resolve_budgets(definition, opts),
         :ok <- Breaker.check_start(org_id, definition.name),
         # A3: same start-time intersection resolution as run/4 (the worker re-resolves
         # from the row at execution time — a definition drift lands fail-honest there).
         {:ok, _tools} <- Tools.resolve_definition(definition) do
      {:ok, create_run!(agent_mod, definition, org_id, scope, goal, budgets, opts, enqueue: true)}
    end
  end

  def start(_agent_mod, _scope, _goal, _opts), do: {:error, :invalid_scope}

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
  rendered binaries, `:tools` (A3, ADR-047 §4.2) is exactly the LOOP-resolved static tool
  defs — the caller-opts allowlist (`Keyword.take/2`, unchanged from A1 byte-for-byte)
  admits NEITHER, so a caller can supply history, tools, nor grant state — and
  `grant_egress?: false` is appended LAST — a caller-supplied override cannot re-enable
  grant plaintext on the agent path (masked-only, categorically; operator decision §9#2
  TAKEN).
  """
  @spec egress_opts(keyword(), [String.t()], [map()]) :: keyword()
  def egress_opts(opts, history, tool_defs \\ []) do
    opts
    |> Keyword.take([:provider, :grounding, :meta, :env_reader])
    |> Keyword.put(:history, history)
    |> Keyword.put(:tools, tool_defs)
    |> Keyword.put(:grant_egress?, false)
  end

  @doc """
  The bounded next-step envelope (dynamic next-step selection). A1's `FINAL:` grammar,
  grown at A3 with tool-call selection (the ADR-047 §10 deferred spelling, decided
  here — the text-envelope FALLBACK for adapters without native tool use, §5.2):

    * `FINAL: <answer>` — goal met; the remainder is the answer;
    * `TOOL: {"tool": "<kind>", "args": {...}}` — ONE tool call as a bounded JSON
      object (exactly the keys `"tool"` — required, a registry kind string — and
      `"args"` — an optional object, default `{}`). Anything malformed — undecodable
      JSON, extra keys, a non-string tool, non-object args — is `{:tool_error,
      :invalid_tool_call}`: a fail-honest bounded feedback turn, never a raise, never
      a silent `continue` that would hide a mangled tool intent;
    * anything else continues (the text joins the history).

  Native `%Completion{tool_calls: [...]}` takes PRIORITY over text parsing — see
  `next_step/1`.
  """
  @spec parse_next(String.t()) ::
          {:final, String.t()}
          | {:continue, String.t()}
          | {:tool, String.t(), map()}
          | {:tool_error, :invalid_tool_call}
  def parse_next(text) when is_binary(text) do
    case String.trim_leading(text) do
      @final_marker <> rest -> {:final, String.trim(rest)}
      @tool_marker <> rest -> parse_tool_envelope(rest)
      _ -> {:continue, text}
    end
  end

  # The bounded JSON tool envelope: {"tool": kind} + optional {"args": %{}} and NOTHING
  # else (default-deny on extra keys — untrusted model output stays a closed shape).
  defp parse_tool_envelope(rest) do
    case Jason.decode(String.trim(rest)) do
      {:ok, %{"tool" => kind} = envelope} when is_binary(kind) ->
        args = Map.get(envelope, "args", %{})

        if is_map(args) and envelope |> Map.drop(["tool", "args"]) |> map_size() == 0 do
          {:tool, kind, args}
        else
          {:tool_error, :invalid_tool_call}
        end

      _ ->
        {:tool_error, :invalid_tool_call}
    end
  end

  @doc """
  The next-step decision for a completion (A3): native `tool_calls` win over the text
  envelope (ADR-047 §5.2 — an adapter that supports vendor tool use maps into the
  bounded field; one that does not leaves it `[]` and the text grammar applies).
  Exactly ONE native call is supported in v1 — more is `{:tool_error,
  :invalid_tool_call}` (fail-honest, never a silent partial execution).
  """
  @spec next_step(Completion.t()) ::
          {:final, String.t()}
          | {:continue, String.t()}
          | {:tool, String.t(), map()}
          | {:tool_error, :invalid_tool_call}
  def next_step(%Completion{tool_calls: [call]}), do: parse_native_call(call)
  def next_step(%Completion{tool_calls: [_ | _]}), do: {:tool_error, :invalid_tool_call}
  def next_step(%Completion{text: text}), do: parse_next(text)

  defp parse_native_call(%{"name" => kind, "args" => args}) when is_binary(kind) and is_map(args),
    do: {:tool, kind, args}

  defp parse_native_call(%{"name" => kind}) when is_binary(kind), do: {:tool, kind, %{}}
  defp parse_native_call(%{name: kind, args: args}) when is_binary(kind) and is_map(args),
    do: {:tool, kind, args}

  defp parse_native_call(%{name: kind}) when is_binary(kind), do: {:tool, kind, %{}}
  defp parse_native_call(_call), do: {:tool_error, :invalid_tool_call}

  @doc """
  Which budget (if any) is exhausted at this turn boundary (ADR-047 §6) — checked BEFORE
  every turn, so exhaustion can never silently truncate mid-answer: the turn that would
  overrun is never taken, and the last completed turn is never promoted. Token budgets
  use `>` on the summed counters — deliberately soft by up to one turn (the crossing
  turn completes; the next is refused). Returns a bounded error kind or `nil`.
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

  @doc """
  Filter a turn-log `meta` map to the bounded, token-only shape (the
  `RunRecord.bounded_outcomes/1` default-deny posture): plain maps only, string/atom
  keys rendered to strings, scalar values (binary/atom/number/boolean) only — anything
  struct-shaped, nested, or rich is DROPPED, never `inspect`-ed. A non-map degrades to
  `%{}` (never a rejected finalize).
  """
  @spec bounded_meta(term()) :: map()
  def bounded_meta(%_struct{}), do: %{}

  def bounded_meta(meta) when is_map(meta) do
    for {k, v} <- meta, bounded_meta_key?(k), bounded_meta_value?(v), into: %{} do
      {to_string(k), bounded_meta_value(v)}
    end
  end

  def bounded_meta(_other), do: %{}

  defp bounded_meta_key?(k), do: is_binary(k) or is_atom(k)
  defp bounded_meta_value?(v), do: is_binary(v) or is_atom(v) or is_number(v) or is_boolean(v)
  defp bounded_meta_value(v) when is_atom(v) and not is_boolean(v) and not is_nil(v), do: Atom.to_string(v)
  defp bounded_meta_value(v), do: v

  @doc "The five resolved default budgets (§9#3 TAKEN). The honesty floor is not in here."
  @spec default_budgets() :: keyword()
  def default_budgets, do: @default_budgets

  @doc "The in-flight watchdog window (seconds) — never-nil `next_turn_at` (§4.1)."
  @spec inflight_watchdog_seconds() :: pos_integer()
  def inflight_watchdog_seconds, do: @inflight_watchdog_seconds

  @doc "Turns executed per Oban job before the worker re-arms (host-configurable)."
  @spec turns_per_job() :: pos_integer()
  def turns_per_job do
    case Application.get_env(:samen_core, __MODULE__, [])[:turns_per_job] do
      n when is_integer(n) and n > 0 -> n
      _ -> @default_turns_per_job
    end
  end

  # ------------------------------------------------------------------------------------
  # The worker seam (A2)

  @doc """
  Load a run row by id for the worker (primary-key lookup, `org_id` force-selected —
  the `Samen.Sequences.fetch_by_id/2` discipline). Returns `{:ok, run}`,
  `{:error, :not_found}`, or `{:error, reason}` (a transient fetch failure the worker
  surfaces to Oban as retriable — the ONE `{:error, _}` a business run ever returns).
  """
  @spec fetch_run(String.t() | nil) :: {:ok, Ash.Resource.record()} | {:error, term()}
  def fetch_run(nil), do: {:error, :not_found}

  def fetch_run(id) do
    require Ash.Query

    Run
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.ensure_selected([:org_id, :transcript])
    |> Ash.Query.limit(1)
    |> Ash.read(authorize?: false)
    |> case do
      {:ok, [run]} -> {:ok, run}
      {:ok, []} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc """
  Execute up to `turns_per_job/0` turns of a durable run (called by
  `Samen.AI.Agent.TurnWorker`). Resolves the agent module and owner actor from the
  ROW (a missing/mismatched module is a fail-honest `:agent_unresolvable`; a missing
  owner is `:owner_unavailable` — the `Automation.RunWorker` owner-resolution rule,
  never a silent re-attribution) and runs the SAME loop `run/4` uses. Returns
  `{:continue, run}` at a batch boundary (the worker re-arms) or the loop's terminal
  tuple. An already-terminal run returns `{:done, run}` (a duplicate job is a no-op —
  the RunWorker "already-queued half" posture).
  """
  @spec execute_batch(Ash.Resource.record()) ::
          {:continue, Ash.Resource.record()} | {:done, Ash.Resource.record()} | term()
  def execute_batch(%Run{} = run) do
    cond do
      run.state not in [:queued, :running] ->
        {:done, run}

      true ->
        with {:ok, agent_mod} <- resolve_agent(run),
             {:ok, scope} <- owner_scope(run) do
          definition = agent_mod.definition()

          # A3: re-resolve the intersection from the definition AS DEPLOYED — a tool
          # de-registered/de-opted between start and execution is a fail-honest
          # terminal, never a silently narrowed tool surface.
          case Tools.resolve_definition(definition) do
            {:ok, tools} ->
              run = if run.state == :queued, do: begin!(run), else: run

              loop(
                run,
                scope,
                definition,
                Keyword.put(worker_opts(), :resolved_tools, tools),
                turns_per_job()
              )

            {:error, kind} ->
              {:error, kind, terminal_logged!(run, kind)}
          end
        else
          {:error, kind} -> {:error, kind, terminal_logged!(run, kind)}
        end
    end
  end

  # The worker's opts: the host-configured agent provider override (tests point this at
  # Samen.AI.Provider.Scripted — the cross-process script seam), else Samen.AI's own
  # provider resolution applies (host config / env fallback; fail-honest when unwired).
  defp worker_opts do
    case Application.get_env(:samen_core, __MODULE__, [])[:provider] do
      nil -> []
      provider -> [provider: provider]
    end
  end

  # The stored module string is untrusted-at-rest config: resolve fail-honestly. It must
  # name an EXISTING, loaded module exporting definition/0 whose validated name matches
  # the row's `agent` — anything else is :agent_unresolvable, never a guess.
  defp resolve_agent(%Run{agent_module: mod_string, agent: agent_name}) do
    with true <- is_binary(mod_string),
         {:ok, mod} <- existing_atom(mod_string),
         {:module, ^mod} <- Code.ensure_loaded(mod),
         true <- function_exported?(mod, :definition, 0),
         %{name: ^agent_name} <- mod.definition() do
      {:ok, mod}
    else
      _ -> {:error, :agent_unresolvable}
    end
  end

  defp existing_atom(string) do
    {:ok, String.to_existing_atom(string)}
  rescue
    ArgumentError -> {:error, :agent_unresolvable}
  end

  # The run executes AS the initiating member, re-resolved from the durable row at
  # turn time (never the envelope, never a synthesized actor — INV-2).
  defp owner_scope(%Run{owner_id: owner_id, org_id: org_id})
       when is_binary(owner_id) and is_binary(org_id) do
    {:ok, Samen.Scope.new(%{id: owner_id, org_id: org_id, role: :member})}
  end

  defp owner_scope(_run), do: {:error, :owner_unavailable}

  # ------------------------------------------------------------------------------------
  # The loop (one engine for both modes; `remaining` = :infinity | turns left this job)

  defp loop(%Run{} = run, scope, definition, opts, remaining) do
    # Reload the durable cursor at EVERY turn boundary: the cancel flag is durable state
    # another process may have set since the last turn (RP-AG-8 — sabotage 241's target),
    # and the operator kill-switch may have flipped (sabotage 244's target).
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

      Breaker.killed?() ->
        # Fail-closed interrupt (A2, §6): an operator kill between turn N and N+1 stops
        # turn N+1 — the in-flight turn completed and was recorded honestly.
        run = terminal!(run, :fail, :killed)
        log_terminal(run)
        {:error, :killed, run}

      budget_kind != nil ->
        # Fail-honest exhaustion (RP-AG-6): an explicit terminal state + a bounded kind.
        # The transcript — including any last assistant text — is deliberately NOT
        # promoted to an answer (sabotage 240 keeps this refutable).
        run = terminal!(run, :exhaust, budget_kind)
        log_terminal(run)
        {:error, :budget_exhausted, run}

      remaining == 0 ->
        # Batch boundary (worker mode): the durable cursor carries everything; the
        # worker re-arms and the watchdog covers a lost re-arm.
        {:continue, run}

      true ->
        case execute_turn(run, scope, definition, opts) do
          {:continue, run} -> loop(run, scope, definition, opts, dec(remaining))
          other -> other
        end
    end
  end

  defp dec(:infinity), do: :infinity
  defp dec(n) when is_integer(n), do: n - 1

  defp execute_turn(%Run{} = run, scope, definition, opts) do
    {:ok, org_id} = scope_org(scope)
    turn_index = run.current_turn + 1
    tools = Keyword.get(opts, :resolved_tools, [])

    with {:ok, {goal, lines}} <- transcript(run),
         {:ok, replayed?, turn_row} <- find_or_reuse_turn(run, org_id, turn_index) do
      started = System.monotonic_time(:millisecond)

      # Every provider-bound byte still routes kernel → chokepoint: prior turns re-enter
      # ONLY as `:history` (re-scrubbed per §3.2a + allowlist-scanned per §3.2 step 3/4,
      # every turn), tool DEFS ride the sealed payload's `:tools` field (scrubbed +
      # static-membership-checked, §4.2), and grant plaintext is categorically excluded
      # (§4.4). The slow provider call sits BETWEEN the two checkpoints, outside any
      # transaction (§4.1).
      result =
        Samen.AI.complete(
          scope,
          [definition.goal_prompt, goal],
          %{},
          egress_opts(opts, lines, Tools.defs(tools))
        )

      duration_ms = System.monotonic_time(:millisecond) - started

      case result do
        {:ok, %Completion{} = completion} ->
          Breaker.note_provider_ok(run.agent)

          case next_step(completion) do
            {:tool, kind, args} ->
              tool_turn(
                run,
                scope,
                tools,
                turn_row,
                completion,
                kind,
                args,
                duration_ms,
                {goal, lines},
                replayed?
              )

            {:tool_error, tool_error_kind} ->
              feedback_turn(
                run,
                turn_row,
                completion,
                tool_error_kind,
                nil,
                duration_ms,
                {goal, lines},
                replayed?
              )

            next ->
              run =
                commit_turn!(run, turn_row, completion, next, duration_ms, {goal, lines}, replayed?)

              case next do
                {:final, answer} ->
                  log_terminal(run)
                  {:ok, %{answer: answer, run: run, turns: run.current_turn}}

                {:continue, _text} ->
                  {:continue, run}
              end
          end

        {:error, reason} ->
          # Fail-honest error terminal (EG6): the bounded kind goes to the row; the
          # normalized reason (already content-free by the chokepoint) to the caller.
          kind = safe_error_kind(reason)
          if kind in [:provider_error, :not_configured], do: Breaker.note_provider_error(run.agent)

          finalize_turn!(turn_row, %{
            status: :failed,
            error_kind: to_string(kind),
            duration_ms: duration_ms,
            meta: bounded_meta(%{"replayed" => replayed?})
          })

          run = terminal!(run, :fail, kind)
          log_terminal(run)
          {:error, reason, run}
      end
    else
      {:error, kind} when is_atom(kind) ->
        {:error, kind, terminal_logged!(run, kind)}
    end
  end

  # The OUTCOME checkpoint (§4.1 checkpoint 2): finalize the turn row, advance the run
  # cursor (+ the vault-routed transcript, + counters, + the re-armed watchdog), and —
  # for a FINAL turn — the terminal transition, all in ONE DB transaction, so a :done
  # turn row and the cursor can never disagree (the replay-idempotency load-bearer).
  defp commit_turn!(%Run{} = run, turn_row, %Completion{} = completion, next, duration_ms, {goal, lines}, replayed?) do
    turn_index = run.current_turn + 1
    in_tokens = usage_int(completion.usage, :input_tokens)
    out_tokens = usage_int(completion.usage, :output_tokens)

    {:ok, run} =
      repo!().transaction(fn ->
        finalize_turn!(turn_row, %{
          status: :done,
          input_tokens: in_tokens,
          output_tokens: out_tokens,
          duration_ms: duration_ms,
          provider: bounded_provider(completion.provider),
          simulated: completion.simulated,
          meta: bounded_meta(%{"replayed" => replayed?})
        })

        run =
          run
          |> Ash.Changeset.for_update(:advance, %{
            current_turn: turn_index,
            next_turn_at: DateTime.add(DateTime.utc_now(), @inflight_watchdog_seconds),
            transcript: encode_transcript(goal, lines ++ [completion.text]),
            input_tokens_used: run.input_tokens_used + in_tokens,
            output_tokens_used: run.output_tokens_used + out_tokens
          })
          |> Ash.update!(authorize?: false)

        case next do
          {:final, _answer} ->
            run
            |> Ash.Changeset.for_update(:succeed, %{})
            |> Ash.update!(authorize?: false)

          {:continue, _text} ->
            run
        end
      end)

    run
  end

  # ------------------------------------------------------------------------------------
  # The tool turn (A3 — ADR-047 §4.3/§5.1)

  # One model-chosen tool call. Order is load-bearing:
  #   1. AUTHORIZE — the four-way intersection re-check (arms 1-3 via the run's RESOLVED
  #      set; sabotage 249's target) + the vt_-sentinel arg gate + the action's own
  #      write-time validate/2. Any refusal is an HONEST feedback turn (recorded on the
  #      turn row + a bounded line the model sees) — never a silent skip, never an
  #      execution;
  #   2. DECIDE — stamp tool_kind + arg key names + the validated-args sha256 digest onto
  #      the :proposed turn row (ADR-047 §4.1 checkpoint 1's tool half), committed BEFORE
  #      the governed action fires — the {run_id, turn_index} row is the tool-idempotency
  #      key a replay reuses;
  #   3. EXECUTE — the governed action runs AS the owner actor (arm 4: the actor's real
  #      policy envelope binds inside the action's own Ash reads; INV-2);
  #   4. RENDER + COMMIT — the call echo + result re-enter ONLY as ToolResult-rendered,
  #      PiiResolution-egress-resolved binaries appended to the vault-routed transcript
  #      (they re-enter as :history next turn — §3.2a re-scrub + safe_segment?/1 last
  #      line), finalized atomically with the cursor advance + tool_calls_used counter.
  defp tool_turn(run, scope, tools, turn_row, completion, kind, args, duration_ms, {goal, lines}, replayed?) do
    case authorize_tool(tools, kind, args) do
      {:ok, entry, normalized} ->
        turn_row = decide_tool!(turn_row, entry.kind, normalized)
        outcome = run_tool(entry, normalized, run, scope)

        new_lines = [
          ToolResult.render_call(entry.kind, normalized)
          | ToolResult.render(outcome, actor: scope_actor(scope))
        ]

        run =
          commit_tool_turn!(run, turn_row, completion, %{
            tool_kind: entry.kind,
            arg_keys: sorted_arg_keys(normalized),
            error_kind: outcome_error_kind(outcome),
            executed?: true,
            new_lines: new_lines,
            duration_ms: duration_ms,
            goal: goal,
            lines: lines,
            replayed?: replayed?
          })

        {:continue, run}

      {:error, refusal_kind, known_kind} ->
        feedback_turn(
          run,
          turn_row,
          completion,
          refusal_kind,
          known_kind,
          duration_ms,
          {goal, lines},
          replayed?
        )
    end
  end

  # A tool call the run could not even execute (outside the intersection, poisoned or
  # invalid args, malformed envelope): the HONEST refusal turn. Recorded on the turn row
  # (bounded error_kind; tool_kind only when the requested kind is a REGISTRY kind — an
  # arbitrary model string never lands in a persisted column) and fed back to the model
  # as one bounded fixed line, so the run continues under its budgets. Never a silent
  # skip, never an execution.
  defp feedback_turn(run, turn_row, completion, refusal_kind, known_kind, duration_ms, {goal, lines}, replayed?) do
    feedback = "tool_error: " <> to_string(safe_error_kind(refusal_kind))

    run =
      commit_tool_turn!(run, turn_row, completion, %{
        tool_kind: known_kind,
        arg_keys: [],
        error_kind: refusal_kind,
        executed?: false,
        new_lines: [feedback],
        duration_ms: duration_ms,
        goal: goal,
        lines: lines,
        replayed?: replayed?
      })

    {:continue, run}
  end

  # The four-way-intersection + arg gates for one call (order: membership → vt_ scan →
  # the action's own validator). Returns {:ok, entry, normalized} or
  # {:error, bounded_kind, registry_kind_or_nil}.
  defp authorize_tool(tools, kind, args) do
    known_kind = if Tools.registry_kind?(kind), do: kind, else: nil

    with {:ok, entry} <- Tools.resolve_call(tools, kind),
         :ok <- refuse_vt_args(args),
         {:ok, normalized} <- validate_args(entry.module, args) do
      {:ok, entry, normalized}
    else
      {:error, :tool_refused} -> {:error, :tool_refused, known_kind}
      {:error, :invalid_args} -> {:error, :invalid_args, known_kind}
    end
  end

  # A model-emitted arg carrying the vault-token sentinel is refused BEFORE anything
  # executes or persists beyond the bounded row (ADR-047 §4.3; the sabotage-45 EG2
  # tool-args hole, re-proven on the agent path). Keys AND values, recursively —
  # fail-closed: an unscannable shape refuses.
  defp refuse_vt_args(args) do
    if vt_free?(args), do: :ok, else: {:error, :invalid_args}
  rescue
    _ -> {:error, :invalid_args}
  end

  defp vt_free?(value) when is_binary(value), do: not String.contains?(value, @vt_sentinel)

  defp vt_free?(value) when is_atom(value) and not is_nil(value),
    do: not (value |> Atom.to_string() |> String.contains?(@vt_sentinel))

  defp vt_free?(value) when is_number(value) or is_boolean(value) or is_nil(value), do: true
  defp vt_free?(value) when is_list(value), do: Enum.all?(value, &vt_free?/1)

  defp vt_free?(value) when is_map(value) and not is_struct(value),
    do: Enum.all?(value, fn {k, v} -> vt_free?(k) and vt_free?(v) end)

  defp vt_free?(_other), do: false

  # Tool args are untrusted model output validated by the action's OWN write-time
  # validate/2 (the same validator the Workflow changeset uses; ADR-047 §4.3). Invalid
  # args are a fail-honest bounded tool error fed back to the model — never a raise
  # (a raise's message is an EG6 egress) and never a silent coercion.
  defp validate_args(module, args) when is_map(args) do
    case module.validate(args, nil) do
      {:ok, normalized} when is_map(normalized) -> {:ok, normalized}
      _ -> {:error, :invalid_args}
    end
  rescue
    _ -> {:error, :invalid_args}
  end

  defp validate_args(_module, _args), do: {:error, :invalid_args}

  # The governed execution (arm 4 binds HERE): the action runs AS the run's owner actor
  # through its own governed Ash reads — a policy refusal surfaces as the action's
  # bounded honest error. An action error never crashes the engine (ADR-039 §5.1) and
  # never leaks a rich term (EG6): anything unexpected degrades to :tool_failed.
  defp run_tool(entry, normalized, run, scope) do
    ctx = Samen.AI.Agent.Context.build(run, scope)

    case entry.module.run(normalized, ctx) do
      {:ok, meta} when is_map(meta) -> {:ok, meta}
      {:error, kind} when is_atom(kind) and not is_nil(kind) -> {:error, kind}
      _other -> {:error, :tool_failed}
    end
  rescue
    _ -> {:error, :tool_failed}
  end

  # The tool DECISION stamp (ADR-047 §4.1 checkpoint 1, tool half): tool_kind + arg key
  # NAMES + the validated-args sha256 digest land on the :proposed row BEFORE the
  # governed action fires. A watchdog replay that re-decides finds the stamp; a
  # divergent fresh decision (provider nondeterminism across the replay) is recorded
  # honestly — read tools are side-effect-free, so the fresh decision executes, with
  # `replay_divergent` in the bounded meta (A4's write path parks on the approval seam
  # instead, so a stamped write can never double-fire on divergence).
  defp decide_tool!(turn_row, kind, normalized) do
    digest = args_digest(normalized)
    prior = turn_row.meta || %{}

    meta =
      %{"args_digest" => digest}
      |> maybe_put_divergent(prior["args_digest"], digest)

    turn_row
    |> Ash.Changeset.for_update(:decide, %{
      tool_kind: kind,
      arg_keys: sorted_arg_keys(normalized),
      meta: bounded_meta(meta)
    })
    |> Ash.update!(authorize?: false)
  end

  defp maybe_put_divergent(meta, nil, _fresh), do: meta
  defp maybe_put_divergent(meta, prior, prior), do: meta
  defp maybe_put_divergent(meta, _prior, _fresh), do: Map.put(meta, "replay_divergent", true)

  # The validated-args digest: sha256 over the canonical (sorted [key, value] pairs)
  # JSON encoding — a stable identity for "this exact tool call", never the values
  # themselves. Public so the A3 suite proves the stamped digest byte-for-byte.
  @doc false
  @spec args_digest(map()) :: String.t()
  def args_digest(normalized) do
    canonical =
      normalized
      |> Enum.map(fn {k, v} -> [to_string(k), v] end)
      |> Enum.sort()
      |> Jason.encode!()

    :crypto.hash(:sha256, canonical) |> Base.encode16(case: :lower)
  end

  defp sorted_arg_keys(args) when is_map(args),
    do: args |> Map.keys() |> Enum.map(&to_string/1) |> Enum.sort()

  defp outcome_error_kind({:ok, _meta}), do: nil
  defp outcome_error_kind({:error, kind}), do: kind

  # The tool OUTCOME checkpoint (§4.1 checkpoint 2, tool half): finalize the turn row
  # (status :done — the TURN completed; a refused/failed TOOL is carried honestly in
  # error_kind), advance the cursor + the vault-routed transcript (echo + rendered
  # result lines — next turn's :history) + the tool_calls_used budget counter, all in
  # ONE transaction (the commit_turn! discipline).
  defp commit_tool_turn!(%Run{} = run, turn_row, %Completion{} = completion, turn) do
    turn_index = run.current_turn + 1
    in_tokens = usage_int(completion.usage, :input_tokens)
    out_tokens = usage_int(completion.usage, :output_tokens)

    finalize_meta =
      (turn_row.meta || %{})
      |> Map.put("replayed", turn.replayed?)

    {:ok, run} =
      repo!().transaction(fn ->
        finalize_turn!(turn_row, %{
          status: :done,
          tool_kind: turn.tool_kind,
          arg_keys: turn.arg_keys,
          error_kind: turn.error_kind && to_string(safe_error_kind(turn.error_kind)),
          input_tokens: in_tokens,
          output_tokens: out_tokens,
          duration_ms: turn.duration_ms,
          provider: bounded_provider(completion.provider),
          simulated: completion.simulated,
          meta: bounded_meta(finalize_meta)
        })

        run
        |> Ash.Changeset.for_update(:advance, %{
          current_turn: turn_index,
          next_turn_at: DateTime.add(DateTime.utc_now(), @inflight_watchdog_seconds),
          transcript: encode_transcript(turn.goal, turn.lines ++ turn.new_lines),
          tool_calls_used: run.tool_calls_used + if(turn.executed?, do: 1, else: 0),
          input_tokens_used: run.input_tokens_used + in_tokens,
          output_tokens_used: run.output_tokens_used + out_tokens
        })
        |> Ash.update!(authorize?: false)
      end)

    run
  end

  defp scope_actor(%Samen.Scope{actor: actor}) when is_map(actor), do: actor
  defp scope_actor(_scope), do: nil

  # The DECISION checkpoint (§4.1 checkpoint 1) + replay reuse (RP-AG-7): the
  # `{run_id, turn_index}` row is committed :proposed BEFORE the provider call; a replay
  # (worker death, watchdog re-select) FINDS that row and REUSES it — the
  # `Samen.Sequences.find_or_create_step_send/2` shape; the unique index refuses a
  # duplicate structurally. A resolved (:done/:failed) row at a not-yet-advanced cursor
  # is impossible by construction (commit_turn!'s single transaction) — seeing one is a
  # desync surfaced fail-honestly, never silently re-executed.
  defp find_or_reuse_turn(%Run{} = run, org_id, turn_index) do
    require Ash.Query

    Turn
    |> Ash.Query.filter(run_id == ^run.id and turn_index == ^turn_index)
    |> Ash.Query.limit(1)
    |> Ash.read!(authorize?: false)
    |> case do
      [] ->
        row =
          Turn
          |> Ash.Changeset.for_create(:record, %{
            org_id: org_id,
            run_id: run.id,
            turn_index: turn_index,
            status: :proposed
          })
          |> Ash.create!(authorize?: false)

        {:ok, false, row}

      [%{status: :proposed} = row] ->
        {:ok, true, row}

      [_resolved] ->
        {:error, :turn_desync}
    end
  end

  defp finalize_turn!(turn_row, attrs) do
    turn_row
    |> Ash.Changeset.for_update(:finalize, attrs)
    |> Ash.update!(authorize?: false)
  end

  # ------------------------------------------------------------------------------------
  # The vault-routed transcript (§7.4)

  # Reveal the run's transcript through the ONE decrypt chokepoint, bound to the run's
  # own subject id (the Samen.Identity.Totp precedent). A shredded / missing / undecodable
  # transcript is fail-honest :transcript_unavailable — an erased run never keeps
  # executing on cached text.
  defp transcript(%Run{} = run) do
    case run.transcript do
      %Samen.Masked{} = masked ->
        case Samen.Vault.reveal(masked, repo!(), subject_id: run.id) do
          {:ok, json} -> decode_transcript(json)
          {:error, _reason} -> {:error, :transcript_unavailable}
        end

      _ ->
        {:error, :transcript_unavailable}
    end
  end

  defp decode_transcript(json) do
    case Jason.decode(json) do
      {:ok, %{"goal" => goal, "lines" => lines}} when is_binary(goal) and is_list(lines) ->
        if Enum.all?(lines, &is_binary/1) do
          {:ok, {goal, lines}}
        else
          {:error, :transcript_unavailable}
        end

      _ ->
        {:error, :transcript_unavailable}
    end
  end

  defp encode_transcript(goal, lines), do: Jason.encode!(%{"goal" => goal, "lines" => lines})

  # ------------------------------------------------------------------------------------
  # Durable-cursor writes (kernel-only, the Approvals trusted-API precedent)

  defp create_run!(agent_mod, definition, org_id, scope, goal, budgets, opts, extra \\ []) do
    changeset =
      Run
      |> Ash.Changeset.for_create(
        :start,
        Map.merge(
          %{
            org_id: org_id,
            agent: definition.name,
            agent_module: Atom.to_string(agent_mod),
            owner_id: actor_id(scope),
            origin: Keyword.get(opts, :origin, default_origin(scope)),
            depth: 0,
            chain: [],
            transcript: encode_transcript(goal, []),
            next_turn_at: DateTime.add(DateTime.utc_now(), @inflight_watchdog_seconds)
          },
          Map.new(budgets)
        )
      )

    changeset =
      if Keyword.get(extra, :enqueue, false) do
        # Same-transaction launch enqueue (§4.1, the EventCapture idiom): Oban.insert
        # runs inside the create's after_action — the job exists iff the row committed.
        # A failed insert is LOGGED LOUDLY, never a rollback of the run row: the armed
        # next_turn_at watchdog guarantees recovery (the Sequences enqueue_send posture).
        Ash.Changeset.after_action(changeset, fn _changeset, run ->
          case Samen.AI.Agent.TurnWorker.enqueue(run.id) do
            {:ok, _job} ->
              :ok

            {:error, reason} ->
              require Logger

              Logger.error(
                "[Samen.AI.Agent] TurnWorker enqueue FAILED run=#{run.id} " <>
                  "reason=#{inspect(reason)} — the :agent_turn_due watchdog will recover"
              )
          end

          {:ok, run}
        end)
      else
        changeset
      end

    Ash.create!(changeset, authorize?: false)
  end

  defp begin!(%Run{} = run) do
    now = DateTime.utc_now()

    run
    |> Ash.Changeset.for_update(:begin, %{
      started_at: now,
      next_turn_at: DateTime.add(now, @inflight_watchdog_seconds)
    })
    |> Ash.update!(authorize?: false)
  end

  # :fail and :cancel transition from :queued OR :running; :exhaust is loop-only (the
  # loop always runs post-begin!, so an exhaust on a :queued row cannot arise).
  defp terminal!(%Run{} = run, action, kind) do
    run
    |> Ash.Changeset.for_update(action, %{error_kind: to_string(safe_error_kind(kind))})
    |> Ash.update!(authorize?: false)
  end

  defp terminal_logged!(%Run{} = run, kind) do
    run = terminal!(run, :fail, kind)
    log_terminal(run)
    run
  end

  # The vault-routed transcript (like the universal org_id) is NOT selected by default —
  # force-select both so the engine's boundary reload always has the cursor AND the
  # revealed-history source in hand (the Sequences fetch_by_id ensure_selected lesson).
  defp reload!(%Run{} = run) do
    require Ash.Query

    Run
    |> Ash.Query.filter(id == ^run.id)
    |> Ash.Query.ensure_selected([:org_id, :transcript])
    |> Ash.read!(authorize?: false)
    |> case do
      [row | _] -> row
      [] -> raise "Samen.AI.Agent: run #{run.id} vanished mid-loop"
    end
  end

  defp repo! do
    AshPostgres.DataLayer.Info.repo(Run, :mutate)
  end

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

  defp actor_id(%Samen.Scope{actor: %{id: id}}) when is_binary(id), do: id
  defp actor_id(_scope), do: nil

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
