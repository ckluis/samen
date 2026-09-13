defmodule Samen.AI.Agent.Hook do
  @moduledoc """
  `Samen.AI.Agent.Hook` — the **declared policy seam** of the ADR-047 agent loop
  (T181; §10a row 25). One ordered chain, seven named points, one return contract.

  Before this behaviour the loop had *no* seam at all: every policy decision it makes
  (the four-way tool intersection, the `vt_` arg gate, the budgets, the write-via-approval
  door) was loop-internal and unextendable, so a host that needed one more narrowing rule
  had nowhere to put it but a fork of `Samen.AI.Agent`. This is that place — and it is
  deliberately a **narrowing-only** seam: a hook can refuse, tighten, or stop, and it can
  do nothing else.

  ## The seven points

  | point | fires | may return |
  |---|---|---|
  | `:session_start` | once, before the run's FIRST turn (both `run/4` and the worker) | `:halt` |
  | `:before_completion` | after the turn row is committed `:proposed`, before the provider call | `:halt` |
  | `:after_compaction` | the ADR-048 §5 fold's summary passed ingress and was appended, before the fold is persisted | `:block`, `:halt` |
  | `:after_tool_request` | the model asked for a tool, before the intersection resolves it | `:block`, `:halt` |
  | `:before_tool_call` | the call passed the intersection + `validate/2`, before it executes or proposes | `:block`, `:edit`, `:halt` |
  | `:after_tool_execution` | the governed action returned, before the outcome is committed | `:halt` |
  | `:on_error` | the loop recorded a RECOVERABLE error it would otherwise absorb | `:halt` |

  `:after_compaction` was declared with **no in-loop caller** through ADR-047 v1, which shipped
  no compactor (the pattern is `findings/034` item 5). ADR-048 §5#6 gives it its FIRST caller:
  `Samen.AI.Agent`'s Level-1 fold dispatches it **after** the model-written summary has passed
  §5#3's ingress path (`Secrets.redact/1` → `Ingress.sanitize/1` → the chokepoint allowlist) and
  been appended to the fold's `llm_view`, and **before** the fold is persisted — so a hook can
  observe only GOVERNED bytes, and a `:block` still means "this fold does not happen".

  Its accepted set is `[:block, :halt]` and — a deliberate divergence §5#6 states outright —
  **it must not accept `{:edit, _}`**: an edit there is a host rewriting governed transcript
  text AFTER the scrub, which is the one thing the ingress path exists to prevent. A hook that
  raises, or returns an `:edit` here, fails the fold CLOSED (`:hook_error`): the fold does not
  happen and the run continues uncompacted (§5#5), never unhooked.

  ## The return contract

    * `:ok` — no decision; the chain continues to the next hook.
    * `{:block, reason}` — refuse this tool call. It does not execute and does not
      propose; the loop records a fail-honest `:hook_blocked` turn and feeds one bounded
      line back to the model, so the run continues under its budgets. Never a silent skip.
    * `{:edit, call}` — execute a **different** call. `call` is `%{args: map}` (an optional
      `:kind` key must equal the requested kind — **tool identity is immutable**). The
      edited args re-run the FULL arg gate before anything executes.
    * `{:halt, reason}` — stop the run. The run reaches a real terminal state with the
      bounded kind `:hook_halted`; it is never reported as a success.

  ## First-decision-wins

  The chain is ORDERED and the first hook that returns anything other than `:ok` decides.
  Later hooks in the chain are **not consulted at all** — they cannot widen, overturn, or
  soften the decision that was already taken. This is what makes the seam composable: a
  host's outermost policy hook cannot be talked out of a refusal by a hook a vertical
  registered behind it.

  ## Narrowing only (the invariant this seam exists to keep)

  A hook may make the loop do LESS. It can never make it do more:

    * an `{:edit, call}` may not change which tool runs (`:kind` is immutable);
    * edited args re-run `refuse_vt_args/1` **and** the action's own `validate/2`, so a
      hook cannot inject a `vt_` vault token to unmask a field, nor hand the action a
      payload its own validator would reject;
    * no decision executes a write. An `effect: :write` tool still PROPOSES and the run
      still parks `:awaiting_approval` (ADR-043 §6.2, unamended) — the seam can block a
      proposal, never approve one;
    * hooks are invisible to `Samen.AI.Agent.egress_opts/3` (its `Keyword.take/2` allowlist
      is unchanged), so no hook can re-enable grant plaintext on the agent path.

  ## Fail closed

  A hook that **raises, throws, or exits** does not silently degrade the loop into running
  unhooked. `Samen.AI.Agent.Hooks.dispatch/3` converts it into the strongest refusal the
  point accepts — `{:block, "hook_error"}` where blocking is honoured, `{:halt, "hook_error"}`
  otherwise. The same conversion applies to a decision the point cannot honour (an `:edit`
  at `:after_tool_execution`, say) and to a malformed edit. A broken hook's failure mode is
  "the tool call did not happen", never "the tool call happened without the policy".

  ## Registering hooks

      # host-wide, and the only source the durable worker can see:
      config :samen_core, Samen.AI.Agent, hooks: [MyApp.BudgetHook, MyApp.PolicyHook]

      # per run (tests, and callers that own the whole call):
      Samen.AI.Agent.run(MyAgent, scope, "goal", hooks: [MyApp.OneOffHook])

  Host-config hooks run FIRST, per-run hooks after them, so a caller-supplied hook can
  never pre-empt the host's own policy.

  ## Writing one

      defmodule MyApp.PolicyHook do
        @behaviour Samen.AI.Agent.Hook

        @impl true
        def call(:before_tool_call, %{kind: "fetch_record", args: args}) do
          {:edit, %{args: Map.put(args, "resource", "MyApp.Ticket")}}
        end

        def call(_point, _ctx), do: :ok
      end

  Hooks must be **idempotent**: a watchdog replay of turn 1 re-fires `:session_start`, and
  a replayed tool turn re-fires `:after_tool_request` / `:before_tool_call`.
  """

  @typedoc "One of the seven declared points."
  @type point ::
          :session_start
          | :before_completion
          | :after_compaction
          | :after_tool_request
          | :before_tool_call
          | :after_tool_execution
          | :on_error

  @typedoc "A tool call as a hook sees (and may edit) it. `:kind` is immutable."
  @type call :: %{optional(:kind) => String.t(), required(:args) => map()}

  @typedoc "The bounded, token-only context a point hands its hooks."
  @type ctx :: %{optional(atom()) => term()}

  @typedoc "What a hook may return. Anything else is treated as a fail-closed refusal."
  @type decision :: :ok | {:block, term()} | {:edit, call()} | {:halt, term()}

  @doc """
  Decide at `point`. Return `:ok` to defer to the next hook in the chain, or one of the
  three decisions — the FIRST decision in the chain wins and ends it.
  """
  @callback call(point(), ctx()) :: decision()

  # The chain, in the order the loop fires them across a run's life.
  @points [
    :session_start,
    :before_completion,
    :after_compaction,
    :after_tool_request,
    :before_tool_call,
    :after_tool_execution,
    :on_error
  ]

  # Per point, the CLOSED set of decisions that point can actually honour. A decision
  # outside its point's set is not "ignored" — it is a fail-closed refusal, because a
  # hook that believed it blocked something must never be silently overruled.
  @accepts %{
    session_start: [:halt],
    before_completion: [:halt],
    after_compaction: [:block, :halt],
    after_tool_request: [:block, :halt],
    before_tool_call: [:block, :edit, :halt],
    after_tool_execution: [:halt],
    on_error: [:halt]
  }

  @doc "The seven declared points, in loop order."
  @spec points() :: [point()]
  def points, do: @points

  @doc "Is `point` one of the seven declared points?"
  @spec point?(term()) :: boolean()
  def point?(point), do: point in @points

  @doc """
  The closed set of decisions `point` can honour (`[]` for an unknown point — fail
  closed: an undeclared point honours nothing).
  """
  @spec accepts(term()) :: [:block | :edit | :halt]
  def accepts(point), do: Map.get(@accepts, point, [])

  @doc "Does `point` honour `decision_tag` (`:block` / `:edit` / `:halt`)?"
  @spec accepts?(term(), term()) :: boolean()
  def accepts?(point, decision_tag), do: decision_tag in accepts(point)
end
