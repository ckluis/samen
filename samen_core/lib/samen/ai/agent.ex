defmodule Samen.AI.Agent do
  @moduledoc """
  `Samen.AI.Agent` — the first-party multi-turn agent loop over `Samen.AI.complete/4`
  (ADR-047 §3/§4/§6; batch A1: the loop core; batch A2: durability + erasure; batch A3:
  the read-tool surface + EG2 scrubbing).

  ## The declared policy seam (T181, §10a row 25)

  Every policy this loop applies used to be loop-internal and unextendable. It now has
  exactly ONE declared seam — `Samen.AI.Agent.Hook`'s seven-point ordered chain, dispatched
  by `Samen.AI.Agent.Hooks` — resolved once per run (host config, then the per-run `:hooks`
  opt) and threaded on `opts` as `:resolved_hooks` beside `:resolved_tools`. Six of the
  seven points have call sites here (`:session_start`, `:before_completion`,
  `:after_tool_request`, `:before_tool_call`, `:after_tool_execution`, `:on_error`), and
  ADR-048 §5#6 gives the seventh — `:after_compaction` — its first: the Level-1 fold
  dispatches it once the summary has passed §5#3's ingress path and been appended, and
  before the fold is persisted, so a `:block` there means the fold does not happen.

  **First-decision-wins**, and hooks may only NARROW: a `{:block, reason}` is the fail-honest
  refusal turn `:hook_blocked`, a `{:halt, reason}` is a real terminal `:hook_halted`
  (never a promoted answer), an `{:edit, call}` may not change WHICH tool runs and its args
  re-run `refuse_vt_args/1` plus the action's own `validate/2` before anything is stamped
  or executed, and no hook return approves a write — an `effect: :write` tool still parks
  for a distinct human (ADR-043 §6.2, unamended). A hook that RAISES fails the call closed
  (`:hook_error`), never letting it execute unhooked. `egress_opts/3`'s allowlist is
  untouched, so no hook can re-enable grant plaintext on the agent path.

  ## What A4 adds — the WRITE surface, via approval only (ADR-047 §5.3)

  ADR-043 §6.2 — *"AI writes do not exist … anything with side effects goes through the
  E3 approvals engine"* — was ratified **unamended** for this loop (§9#1), and A4 is where
  that stops being a promise. An `effect: :write` tool passes the same four-way
  intersection a read tool passes, and that admission buys it a **proposal, not an
  execution**: the turn stamps its decision (tool kind + arg key names + the sha256
  args digest) on the still-`:proposed` `{run_id, turn_index}` row, opens an E3 approval
  through `Samen.AI.Agent.WriteProposal` with the AI service principal as requester, and
  the run **parks `:awaiting_approval`** — non-terminal, watchdog armed to the deadline,
  cursor NOT advanced, `tool_calls_used` NOT billed. `entry.module.run/2` is never called
  on that path.

  A DISTINCT human's approve is the only thing that executes it, and `execute_approved/3`
  runs the governed action **as the APPROVER** — never the agent, never the AI principal,
  which holds no write authority anywhere (§10a row 7). Before it fires, `bind_proposal/3`
  requires the proposal recovered from the run's DEK envelope to agree, field by field,
  with the token-only stamp committed before the human ever saw it: **approving proposal X
  executes exactly X**, and a mutated or substituted payload refuses `:proposal_mismatch`,
  rolling the whole decision back. The four-way intersection, `validate/2` and the `vt_`
  arg gate all re-run at execution — nothing is trusted from proposal time. A rejection
  terminates the run `:rejected`, honestly, having executed nothing.

  The §5.1 **recursion guard is live**: an AMBIENT provenance marker is published around
  every tool execution (inline reads and approved writes alike), so an action that starts
  an agent run is refused `:depth_exceeded` whether or not it passes a `:depth` argument.
  v1 admits no nesting (`max_agent_depth/0 == 0`).

  ## What A3 adds — governed tools (ADR-047 §4.2/§4.3/§5.1)

  A definition's `tools:` list now RESOLVES through the five-way narrowing intersection
  (`Samen.AI.Agent.Tools`: registry ∩ per-action `tool_schema/0` opt-in ∩ the T183
  SURFACE scope ∩ the declared list ∩ the owner actor's policy envelope at execution)
  — at run START (arms 1-3, fail-closed refusals persist nothing) and again PER CALL.
  One tool call per turn:
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
  for real and `max_tool_calls` exhaustion is live. `effect: :write` tools PROPOSE
  instead of executing (A4, above) — A3's interim `:tools_not_supported` refusal is gone,
  replaced by a real door rather than a wider one.

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

  Five SPEND budgets per run, checked at EVERY turn boundary (`over_budget/2`) alongside
  the durable cancel flag and the kill-switch. Exhaustion is a terminal `:budget_exhausted`
  with a bounded `error_kind` — **the last assistant turn is NEVER promoted to an
  answer** (RP-AG-6; sabotage 240). Token budgets are deliberately soft by up to ONE
  turn (`over_budget/2` uses `>` on the summed counters — the turn that crosses the
  ceiling completes and is billed; the NEXT turn is refused); the breaker assumes soft
  ceilings and never treats the overshoot as a violation.

  A sixth budget, `context_cutoff_tokens` (ADR-048 §6), is a WATERMARK rather than a
  spend ceiling and is deliberately NOT part of `over_budget/2`: crossing it means the
  assembled context is too large to keep growing, not that the tenant's allowance is
  spent. Level 1 folds the oldest eligible span; Level 3 is the honest terminal
  `{:error, :context_exhausted, run}` for a context that will not fit under the run's HARD
  `max_input_tokens` ceiling with nothing eligible left to fold.
  It is a DIFFERENT terminal from `:budget_exhausted`, because "this run outgrew its
  context window" and "this run spent its allowance" are different facts for an operator.
  The floor is identical and equally non-configurable: the last assistant turn is NEVER
  promoted, at Level 3 no less than at budget exhaustion.

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

  alias Samen.AI.Agent.Approver
  alias Samen.AI.Agent.Breaker
  alias Samen.AI.Agent.Compaction
  alias Samen.AI.Agent.Hooks
  alias Samen.AI.Agent.Run
  alias Samen.AI.Agent.ToolResult
  alias Samen.AI.Agent.Tools
  alias Samen.AI.Agent.Turn
  alias Samen.AI.Agent.WriteProposal
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
    deadline_seconds: 600,
    # ADR-048 §6 (T218/C2) — the CONTEXT watermark, not a spend ceiling. It is the point
    # at which the assembled context is too large to keep growing: Level 1 folds the
    # oldest eligible span, and Level 3 (`:context_exhausted`) is what is left when the
    # watermark is crossed and NOTHING is eligible to fold. Default = 70% of the default
    # `max_input_tokens`, exactly as §6 states it.
    context_cutoff_tokens: 42_000
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
    # T183 (ADR-047 §5.1a): intersection arm 5 — the tool exists and is opted in, but is
    # registered for a DIFFERENT surface than the one this run executes on. A NAMED
    # refusal, so the turn row/feedback says "off surface", never "no such tool" and
    # never the silent `:unknown` a missing @error_kinds member would degrade to.
    :tool_off_surface,
    :invalid_args,
    :invalid_tool_call,
    :tool_failed,
    :record_not_found,
    :unknown_resource,
    :not_authorized,
    :no_org,
    # A4 (ADR-047 §5.3/§5.1) — the write-via-approval kinds. `:awaiting_approval` is a
    # PARK, not a failure; `:approval_unavailable` is the fail-honest kind for an unwired
    # / refusing approvals engine (the write is NOT executed); `:proposal_mismatch` is the
    # args-digest binding refusing to execute something other than exactly what was
    # approved; `:rejected` is a distinct human's refusal; `:depth_exceeded` is the live
    # recursion guard; the last three are the write action's own governed outcomes.
    :awaiting_approval,
    :approval_unavailable,
    :approval_not_found,
    :approval_not_approved,
    :approval_org_mismatch,
    :proposal_mismatch,
    :rejected,
    # A5: the A4 verifier's R4b — a proposal whose deadline lapsed with no human
    # decision, and the R2 fail-closed refusal of an unresolvable approver.
    :deadline_expired,
    :approver_unresolvable,
    :depth_exceeded,
    :no_owner_attribute,
    :unauthorized,
    :write_failed,
    # T181 (§10a row 25) — the declared hook seam's three bounded outcomes.
    # `:hook_blocked` is a hook's honest refusal of ONE tool call (the run continues under
    # its budgets, nothing executed); `:hook_halted` is a hook stopping the RUN (a real
    # terminal, never a silent success); `:hook_error` is the FAIL-CLOSED degrade — a hook
    # that raised, or returned something its point cannot honour, refuses the call rather
    # than letting it execute unhooked.
    :hook_blocked,
    :hook_halted,
    :hook_error,
    # ADR-048 §6 (T218) — the two CONTEXT kinds. `:context_overflow` is the provider's
    # "prompt too long" answer, normalized out of the content-free `:provider_error` it
    # collapses into today (Level 2's trigger). `:context_exhausted` is Level 3's terminal
    # kind: this run outgrew its context window, which is a DIFFERENT fact from
    # `:budget_exhausted`'s "this run spent its allowance". Both are members here because
    # the enum is closed — an unlisted kind degrades to the useless `:unknown`.
    :context_overflow,
    :context_exhausted,
    # ADR-048 §5#5 (T219) — the compaction REFUSAL kind. The §5 summarize call refused
    # (`:pii_egress_refused`), failed, returned nothing, or its summary did not survive
    # §5#3's ingress path — so the fold DID NOT HAPPEN and the run continues UNCOMPACTED.
    # It is a member here because the enum is closed: the note the loop writes on the turn
    # row is keyed by `safe_error_kind(:compaction_refused)`, so dropping it from this list
    # degrades that note to the useless `:unknown` and the refusal stops being nameable.
    :compaction_refused,
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

  # ADR-047 §5.1 recursion guard, LIVE (A4). "An agent tool may not start another agent
  # run at `depth > 0` in v1" — read literally and conservatively: an agent run at depth
  # > 0 may not be started AT ALL, so v1 admits no nesting. The guard is AMBIENT (a
  # process-scoped provenance marker set around every tool execution, including the
  # APPROVED write execution) rather than a `:depth` argument, precisely so an action
  # cannot route around it by calling `run/4`/`start/4` without one. An explicit
  # `:depth`/`:chain` opt is checked too; the ambient marker wins.
  #
  # NAMED RESIDUAL — a RAW `spawn/1` still escapes, and closing it is A7's job
  # (A6; the A5 verifier's R-A5-1). A5 made the marker follow `$callers`/`$ancestors`,
  # which closes the ORDINARY-concurrency class (`Task.async`, `Task.Supervisor`, a task
  # of a task, a supervised child) — verified live. A bare `spawn/1` sets NEITHER, so a
  # first-party action module whose `run/2` did its work there and called `start/4` from
  # the child would persist a fresh TOP-LEVEL run at `depth: 0, chain: []`. A6 examined
  # every DYNAMIC closure and rejected each as disproportionate or actively harmful:
  #
  #   * any process-scoped mechanism (dictionary, ambient marker, logger metadata) is
  #     defeated by the same primitive that defeats this one — it is the primitive's
  #     defining property that it inherits nothing;
  #   * a DURABLE in-flight arm — "refuse a start whose caller chain is unresolvable
  #     while this {org, definition} has a tool execution in flight" — is the only
  #     runtime signal a raw-spawned child shares with its parent, and it REFUSES
  #     LEGITIMATE CONCURRENCY: two humans starting the same triage definition in the
  #     same org at the same time is ordinary, and the second start would be refused
  #     because the first is mid-tool. Trading a real availability bug for a
  #     defence-in-depth one is a bad trade, and the ADR's own instruction is not to
  #     ship a half-measure that breaks legitimate concurrency;
  #   * stamping the run/turn row does not help either: the child cannot be ATTRIBUTED
  #     to the parent run without the caller chain the raw spawn destroyed, so the
  #     stamp could only be consulted by {org, definition} — which is the same
  #     concurrency-breaking arm above, wearing a schema change.
  #
  # The escape's reachability class is unchanged from A4's R3: only a FIRST-PARTY /
  # host-authored action module can author the spawn (tenant data never becomes code),
  # so this is defence-in-depth, not a tenant-reachable path. The sound closure is
  # therefore STATIC, not dynamic: `mix samen.verify.agent_coverage` (A7, §9#6) must
  # assert by AST that no `tool_schema/0`-exporting module calls `Samen.AI.Agent.start/4`
  # or `run/4` at all — which refuses the escape at compile/gate time regardless of
  # which spawn primitive the module would have used, and costs no concurrency. Recorded
  # as ADR-047 §10a row 19 and carried as an explicit A7 obligation.
  @max_agent_depth 0
  @provenance_key {__MODULE__, :tool_provenance}

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
    * `{:error, :context_exhausted, run}` — ADR-048 §6 Level 3: the assembled context
      will not fit under `max_input_tokens` and nothing was eligible to fold. The run is
      terminal `:context_exhausted` (NOT `:budget_exhausted`) and, as at every other
      terminal, NO partial answer is returned;
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
         # A4 (§5.1): the LIVE recursion guard. A run started from inside a tool
         # execution — including an APPROVED write's execution — is refused
         # `:depth_exceeded` before anything persists.
         {:ok, opts} <- resolve_provenance(opts),
         # T181 (§10a row 25): the declared policy chain is resolved ONCE per run — host
         # config first, then the per-run `:hooks` opt — and rides `opts` beside the
         # resolved tools. `egress_opts/3`'s Keyword.take allowlist is unchanged, so
         # neither key can reach the chokepoint.
         {:ok, opts} <- resolve_hooks(opts),
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

  A per-run `:hooks` opt (UXD-08, T21-verdict.json) is persisted on the row (`arn_hooks`)
  and re-resolved by the durable worker at each execution batch — it fires exactly as it
  would under `run/4`, host config still first (`Samen.AI.Agent.Hooks.resolve/1`).
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
         {:ok, opts} <- resolve_provenance(opts),
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
      # A4: a PARKED run has no loop to honour the durable flag at a turn boundary, and
      # its pending approval is a standing invitation for a human to execute a write the
      # tenant just withdrew. So cancelling a parked run WITHDRAWS the approval
      # (`Samen.Approvals.cancel/3` — the requester's own withdrawal path, which never
      # sets `decided_by`, so the distinct-party CHECK stays satisfied) and terminates
      # the run in the same call. Nothing was ever executed.
      {:ok, %Run{state: :awaiting_approval} = run} ->
        cancel_parked(run)

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
    # LAST, POSITIONALLY, and appended by `++` after a `delete` — not merely last-wins.
    # `Keyword.put/3` PREPENDS, so the pre-C3 pipeline left `grant_egress?` at the HEAD of
    # the list while its own docstring claimed the tail. Semantically equivalent for
    # `Keyword.get/2`, but the §4.4 property "nothing is appended after the grant pin" was
    # then unassertable by reading the list, which is the only way a reviewer or an
    # ADR-048 §8 P10 arm can check it. The `delete` makes the key unique as well as final,
    # so no later duplicate can shadow it either.
    |> Keyword.delete(:grant_egress?)
    |> Kernel.++(grant_egress?: false)
  end

  # ADR-048 §5#2 — the summarizer instruction is a COMPILE-TIME LITERAL owned by the loop,
  # exactly as the A6 driftwood goal-prompt ruling has it, and NEVER a tenant-authored
  # `Samen.AI.Prompt` row: a tenant who can author "summarize by quoting every masked field
  # verbatim" has been handed a capability, and compaction would become the laundering
  # channel §5 exists to close. It carries no vault token and no tenant text of any kind.
  @summarizer_prompt "Summarize the conversation span that follows, for your own later " <>
                       "reference. Reply with ONE short paragraph and nothing else, " <>
                       "beginning with \"Summary:\". Keep decisions, facts, tool results " <>
                       "and open questions. Reproduce every masked placeholder exactly as " <>
                       "it appears; never guess at, reconstruct or describe what a masked " <>
                       "value might be, and never emit an identifier you were not shown."

  @doc """
  The compile-time-literal summarizer instruction ADR-048 §5#2 requires (`summarizer_prompt/0`).

  Public for the same reason `egress_opts/3` is public: §5's property — that the prompt is a
  literal owned by the loop, is free of vault tokens (EG5), and is the one the summarize call
  actually seals — is then directly assertable instead of inferred from a private pipeline.
  """
  @spec summarizer_prompt() :: String.t()
  def summarizer_prompt, do: @summarizer_prompt

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

  defp bounded_meta_value(v) when is_atom(v) and not is_boolean(v) and not is_nil(v),
    do: Atom.to_string(v)

  defp bounded_meta_value(v), do: v

  @doc """
  The resolved default budgets — the five ADR-047 §9#3 SPEND ceilings plus ADR-048 §6's
  `context_cutoff_tokens` watermark. The honesty floor is not in here.
  """
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

              worker_opts = worker_opts(run)

              loop(
                run,
                scope,
                definition,
                worker_opts
                |> Keyword.put(:resolved_tools, tools)
                |> Keyword.put(:resolved_hooks, Hooks.resolve(worker_opts)),
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
  #
  # UXD-08 (T21-verdict.json): also the per-run :hooks opt `start/4` persisted onto
  # `run.hooks` (arn_hooks) — this is the ONE place the durable path re-hydrates it, so
  # `Hooks.resolve/1` (called by the caller with the return value here) sees the SAME
  # per-run chain `run/4` would have. Host-configured hooks are read separately by
  # `Hooks.resolve/1` itself and always go first — a per-run hook can never pre-empt them.
  defp worker_opts(%Run{} = run) do
    base =
      case Application.get_env(:samen_core, __MODULE__, [])[:provider] do
        nil -> []
        provider -> [provider: provider]
      end

    case run.hooks do
      hooks when is_list(hooks) and hooks != [] ->
        Keyword.put(base, :hooks, Enum.map(hooks, &String.to_atom/1))

      _ ->
        base
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

      Breaker.killed?(run.org_id, run.agent) ->
        # Fail-closed interrupt (A2, §6): an operator kill between turn N and N+1 stops
        # turn N+1 — the in-flight turn completed and was recorded honestly. A5 widens
        # WHAT counts as a kill here (the host switch OR this org's DURABLE
        # per-definition row) and narrows what a rate trip THROWS (that row, never the
        # host switch) — so a targeted stop still stops this run mid-flight, and one
        # tenant's trip no longer stops every other tenant's. Sabotage 260 makes the
        # per-definition half of this check refutable.
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
    hooks = Keyword.get(opts, :resolved_hooks, [])

    with :ok <- session_start_hook(hooks, run),
         {:ok, {goal, lines, views}} <- transcript_with_views(run),
         {:ok, run, lines, views} <-
           fold_context(run, scope, views, definition, tools, goal, lines, opts),
         :ok <- context_gate(run, views, definition, tools, goal, lines),
         {:ok, replayed?, turn_row} <- find_or_reuse_turn(run, org_id, turn_index),
         # ADR-048 §5#5: if the fold above was REFUSED, the turn row this turn is about to
         # take says so. The turn itself proceeds — uncompacted is not failed.
         turn_row = note_compaction_refusal!(turn_row, views),
         :ok <- before_completion_hook(hooks, run, turn_row, turn_index) do
      # Every provider-bound byte still routes kernel → chokepoint: prior turns re-enter
      # ONLY as `:history` (re-scrubbed per §3.2a + allowlist-scanned per §3.2 step 3/4,
      # every turn), tool DEFS ride the sealed payload's `:tools` field (scrubbed +
      # static-membership-checked, §4.2), and grant plaintext is categorically excluded
      # (§4.4). The slow provider call sits BETWEEN the two checkpoints, outside any
      # transaction (§4.1).
      #
      # ADR-048 §6 LEVEL 2 rides inside `complete_with_recovery/10`: a `:context_overflow`
      # on the FIRST attempt folds inline and retries ONCE on this same turn index, and
      # the counter is stamped on the turn ROW before the retry leaves. The helper hands
      # back the (possibly re-folded) run + history, the turn row carrying the counter,
      # and how many retries were spent — which is never more than one.
      {run, lines, turn_row, result, duration_ms, retries} =
        complete_with_recovery(
          run,
          scope,
          definition,
          tools,
          goal,
          lines,
          views,
          turn_row,
          opts,
          1
        )

      case result do
        {:ok, %Completion{} = completion} ->
          Breaker.note_provider_ok(run.agent)

          case next_step(completion) do
            {:tool, kind, args} ->
              tool_turn(
                run,
                scope,
                opts,
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
                replayed?,
                hooks,
                nil
              )

            next ->
              run =
                commit_turn!(
                  run,
                  turn_row,
                  completion,
                  next,
                  duration_ms,
                  {goal, lines},
                  replayed?
                )

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

          if kind == :context_overflow and retries > 0 do
            # ADR-048 §6 LEVEL 3, reached ONLY here: the single mid-turn recovery attempt
            # overflowed too. §10 row 5 RATIFIED (a) forbids a second retry, and §6
            # forbids collapsing this into `:budget_exhausted` — "outgrew its context
            # window" and "spent its allowance" are different facts for an operator. The
            # last assistant turn is NOT promoted (the floor, unweakened).
            finalize_turn!(turn_row, %{
              status: :failed,
              error_kind: "context_exhausted",
              duration_ms: duration_ms,
              meta: bounded_meta(Map.put(turn_row.meta || %{}, "replayed", replayed?))
            })

            run = terminal!(run, :context_exhaust, :context_exhausted)
            log_terminal(run)
            {:error, :context_exhausted, run}
          else
            if kind in [:provider_error, :not_configured],
              do: Breaker.note_provider_error(run.agent)

            finalize_turn!(turn_row, %{
              status: :failed,
              error_kind: to_string(kind),
              duration_ms: duration_ms,
              meta: bounded_meta(Map.put(turn_row.meta || %{}, "replayed", replayed?))
            })

            run = terminal!(run, :fail, kind)
            log_terminal(run)
            {:error, reason, run}
          end
      end
    else
      # T181: a hook stopped the run at `:session_start` or `:before_completion`. The turn
      # row (when one already exists) is finalized `:failed` before the terminal, so the
      # audit trail says which turn the halt landed on — never a dangling `:proposed` row.
      {:halt, kind, reason, turn_row} ->
        halt_run(run, turn_row, kind, reason)

      # ADR-048 §6 Level 3. Its own terminal STATE, so an operator health surface can tell
      # "outgrew its context window" from "spent its allowance" — the whole point of the
      # kind. Reached BEFORE `find_or_reuse_turn/3`, so the refused turn leaves no turn
      # row and no bytes ever reach the provider: the turn that cannot fit is never taken,
      # exactly as the budget floor refuses the turn that would overrun.
      {:error, :context_exhausted} ->
        run = terminal!(run, :context_exhaust, :context_exhausted)
        log_terminal(run)
        {:error, :context_exhausted, run}

      {:error, kind} when is_atom(kind) ->
        {:error, kind, terminal_logged!(run, kind)}
    end
  end

  # ------------------------------------------------------------------------------------
  # ADR-048 §6 LEVEL 2 — mid-turn recovery, EXACTLY ONE attempt (§10 row 5, RATIFIED (a))

  # One turn index, at most TWO provider attempts, never a loop. The bound is the
  # `attempt` argument, NOT "whether the watermark cleared" — so option (c) ("until it
  # fits", the budget hole §10 row 5 rejected) is unreachable by construction rather than
  # by discipline. §6's three constraints, each one located:
  #
  #   1. the failed attempt's tokens still count — both attempts are real chokepoint
  #      calls and the committing site bills the usage it is handed;
  #   2. the retry boundary's kill-switch/cancel/budget re-check is **P5** and is
  #      deliberately NOT taken in this batch (`nodes/C2R/work/spec-notes.md` §2);
  #   3. if the single retry ALSO overflows, the caller turns it into LEVEL 3
  #      (`:context_exhausted`) — never a second retry.
  #
  # The counter is stamped on the `:proposed` turn ROW before the retry leaves, so it
  # survives whichever commit path finalizes the turn (plain, tool, feedback or failure)
  # rather than living only on the happy path.
  #
  # D4 (§10 row 4, RATIFIED (a)): the inline fold goes through `derive_fold/6`, which
  # spends `input_tokens_used`/`output_tokens_used` and NOTHING else — `current_turn` and
  # `tool_calls_used` are not in its `:advance` map at all. The reuse arm of
  # `fold_context/6` is deliberately bypassed here: a Level 2 fold is a NEW fold on an
  # already-started turn, not a replay of one.
  @max_context_retries 1

  defp complete_with_recovery(
         %Run{} = run,
         scope,
         definition,
         tools,
         goal,
         lines,
         views,
         turn_row,
         opts,
         attempt
       ) do
    started = System.monotonic_time(:millisecond)

    result =
      Samen.AI.complete(
        scope,
        [definition.goal_prompt, goal],
        %{},
        egress_opts(opts, lines, Tools.defs(tools))
      )

    duration_ms = System.monotonic_time(:millisecond) - started
    retries = attempt - 1

    if attempt <= @max_context_retries and context_overflow?(result) do
      case derive_fold(run, scope, views, definition, tools, goal, lines, opts) do
        {:ok, run, lines, views} ->
          turn_row =
            turn_row
            |> note_compaction_refusal!(views)
            |> note_context_retry!(attempt)

          complete_with_recovery(
            run,
            scope,
            definition,
            tools,
            goal,
            lines,
            views,
            turn_row,
            opts,
            attempt + 1
          )

        # A hook HALTED the run at `:after_compaction` during a LEVEL 2 fold. This turn row
        # already exists, so the honest spelling is the loop's own error terminal: the
        # caller's `{:error, reason}` branch finalizes the row `:failed` with the bounded
        # kind and takes the run terminal. Never a retry, and never a silent continue.
        {:halt, kind, _reason, _turn_row} ->
          {run, lines, turn_row, {:error, kind}, duration_ms, retries}
      end
    else
      {run, lines, turn_row, result, duration_ms, retries}
    end
  end

  defp context_overflow?({:error, reason}), do: safe_error_kind(reason) == :context_overflow
  defp context_overflow?(_result), do: false

  # The counter §6 puts "on the same turn row". Written through the `:decide` checkpoint
  # action (meta only — the tool stamp is untouched) and MERGED into the row's existing
  # meta, so it can never mint a second turn index for a recovery attempt.
  defp note_context_retry!(turn_row, n) do
    turn_row
    |> Ash.Changeset.for_update(:decide, %{
      meta: bounded_meta(Map.put(turn_row.meta || %{}, "context_retries", n))
    })
    |> Ash.update!(authorize?: false)
  end

  # ------------------------------------------------------------------------------------
  # ADR-048 §6 — the pre-turn context gate (the LEVEL 1 / LEVEL 3 boundary)

  # Run BEFORE `seal/3`, as §6 states it. Two DIFFERENT numbers decide two different
  # things, and conflating them is the mistake this comment exists to prevent:
  #
  #   * `context_cutoff_tokens` is the WATERMARK — crossing it is Level 1's trigger to
  #     fold the oldest eligible span. Crossing it is NOT a failure and NEVER ends a run:
  #     the deterministic drop-with-marker fold is the next node of this batch, and until
  #     it lands a run over the watermark simply proceeds exactly as it does today.
  #   * `max_input_tokens` is the run's HARD input ceiling. A context that does not fit
  #     under it with NOTHING eligible left to fold is **Level 3**, and there is no honest
  #     third option: the alternative to refusing is sending a prompt that cannot fit, or
  #     silently truncating one — and silent truncation is the exact dishonesty the floor
  #     forbids.
  #
  # Under the ceiling the turn proceeds unchanged, which is what every shipped agent test
  # exercises — so this gate cannot be satisfied by a constant.
  defp context_gate(%Run{} = run, views, definition, tools, goal, lines) do
    if context_tokens(definition, tools, goal, lines) > run.max_input_tokens and
         foldable(views, lines) == [] do
      {:error, :context_exhausted}
    else
      :ok
    end
  end

  # What Level 1 is allowed to fold — UXD-17's FOUR exclusions, each one structural:
  #
  #   * the GOAL is never in `llm_view` at all (it rides the sealed payload's own field),
  #     so no span can reach it;
  #   * the TOOL DEFS are never in `llm_view` either (compile-time static, §4.2);
  #   * a PRIOR FOLD's own summary segment is excluded EXPLICITLY: every fold replaces its
  #     span with ONE marker segment and appends ONE ledger entry, and markers accumulate
  #     oldest-first at the head of `llm_view` — so the leading `length(folds)` segments
  #     are markers and selection starts strictly AFTER them. This is the ruling that
  #     keeps folds ONE LEVEL DEEP: no fold ever consumes another fold's summary;
  #   * the PROTECTED RECENT TAIL is `@protected_tail_turns` most recent turns. At the
  #     moment the fold runs the turn being ASSEMBLED is the most recent turn — it has no
  #     committed segment yet — so the tail costs `@protected_tail_turns - 1` committed
  #     segments and the in-flight turn is the other one.
  #
  # Eligibility is expressed in whole TURNS, never in lines: a turn can append more than
  # one line (a tool call and its result), and a fold that split one would put a call in
  # the ledger without its result (§6). `views.turn_lens` is what makes that decidable.
  @protected_tail_turns 2

  defp foldable(views, lines) do
    segments = segments(views, lines)

    segments
    |> Enum.drop(length(views.folds))
    |> Enum.drop(-(@protected_tail_turns - 1))
  end

  # `llm_view` chunked into whole turns. `turn_lens` is written by every transcript write
  # and is verified against the line count on read, so a blob whose boundaries do not
  # reconcile degrades to one-line turns rather than to a boundary this build invented.
  defp segments(views, lines) do
    lens =
      if Enum.sum(views.turn_lens) == length(lines),
        do: views.turn_lens,
        else: List.duplicate(1, length(lines))

    {segs, _rest} =
      Enum.map_reduce(lens, lines, fn len, rest ->
        {Enum.take(rest, len), Enum.drop(rest, len)}
      end)

    segs
  end

  # ------------------------------------------------------------------------------------
  # ADR-048 §6 LEVEL 1 — the deterministic, non-model, drop-with-marker fold (T218 / C2)
  #
  # PRE-TURN (before `seal/3`), OLDEST-eligible-span, WHOLE TURNS ONLY.
  #
  # ADR-048 §5 / C3 (`T219`) has now replaced C2's deterministic drop-with-marker REPLACEMENT
  # TEXT with a model-written summary: `summarize_span/3` below is an ordinary governed
  # `Samen.AI.complete/4` through `seal/3`, so exactly one extra provider call rides each
  # folding turn, ahead of that turn's own call. **SELECTION is still deterministic** — which
  # span folds is a pure function of `{the carried view state, the assembled size}` and no
  # model influences it; only the replacement text is model-written, and the ledger entry says
  # so (`"deterministic" => false`). A summarize call that REFUSES folds nothing at all and
  # the run continues uncompacted (§5#4): compaction is not a laundering channel.
  #
  # §4 non-negotiable 4 holds by construction: the folded span is replaced in `llm_view`
  # by ONE bounded marker, and `ui_view` GAINS one appended line saying a fold happened
  # and loses nothing.
  #
  # D4 (§10 row 4, RATIFIED (a)) is enforced BY CONSTRUCTION: the fold's `:advance` sets
  # ONLY `transcript`, `input_tokens_used` and `output_tokens_used`. `current_turn` and
  # `tool_calls_used` are not in the map at all, so both the ceilings and the used-counters
  # are byte-identical immediately before and after a fold. The tokens ARE billed —
  # RATIFIED (a) says a fold's spend is real — and the deterministic bill is the bytes the
  # fold read (the folded span) and the bytes it wrote (the marker).
  # Ruling UXD-18's TWO CHECKPOINTS, at the top of every turn:
  #
  #   * checkpoint 1 — `apply_fold!/4` persists the entry `"proposed"` BEFORE the slow
  #     provider call, i.e. before the TURN's own `complete/4`. Since C3 the §5 summarize
  #     call sits EARLIER still, ahead of checkpoint 1 — a crash inside it therefore leaves
  #     no ledger row and the replay legitimately re-derives, which is precisely the case
  #     UXD-18 already sanctions below ("a crash BEFORE checkpoint 1 leaves no row");
  #   * checkpoint 2 — the SAME transaction that advances the run cursor finalizes the
  #     entry to `"done"` (`encode_transcript_finalizing/3-4`).
  #
  # A replay therefore lands here with the entry already on disk and REUSES it — it does
  # not re-derive. The fold is a pure function of `{run_id, turn_index, view state}`, so
  # a re-derivation would be invisible in the body; the `meta.replayed` stamp is what
  # makes reuse refutable on the ledger itself instead of inferred from a call count.
  # A crash BEFORE checkpoint 1 leaves no row, and that replay legitimately re-derives.
  defp fold_context(%Run{} = run, scope, views, definition, tools, goal, lines, opts) do
    case reusable_fold(views, run.current_turn + 1) do
      nil -> derive_fold(run, scope, views, definition, tools, goal, lines, opts)
      entry -> reuse_fold!(run, views, goal, entry, lines)
    end
  end

  defp derive_fold(%Run{} = run, scope, views, definition, tools, goal, lines, opts) do
    if context_tokens(definition, tools, goal, lines) > run.context_cutoff_tokens do
      case fold_span(run, views, definition, tools, goal, lines) do
        nil ->
          {:ok, run, lines, views}

        span ->
          # `summarize_span/3` returns the summary ALREADY through §5#3's ingress path —
          # `Secrets.redact/1` then `Ingress.sanitize/1` then the chokepoint allowlist — so
          # there is no spelling of this call site that appends an unscrubbed binary.
          case summarize_span(scope, span, opts) do
            {:ok, summary} ->
              # §5#6: the point fires on the span the summary has ALREADY been folded into,
              # and BEFORE `apply_fold!/4` persists it — the only ordering in which `:block`
              # can still mean "this fold does not happen".
              folded = with_summary(span, summary)

              case after_compaction_hook(Keyword.get(opts, :resolved_hooks, []), run, folded) do
                :ok ->
                  apply_fold!(run, views, goal, folded)

                # A hook REFUSED the fold (its own `{:block, _}`, or the fail-closed
                # `:hook_error` an `{:edit, _}` at this point degrades to — §5#6 forbids
                # edits outright). Same honest answer as a refused summarize.
                {:block, kind, _reason} ->
                  {:ok, run, lines, refused(views, kind)}

                # A hook STOPPED the run. The `with` in `execute_turn/4` routes this to
                # `halt_run/4`, a real terminal — never a promoted partial answer.
                {:halt, kind, reason} ->
                  {:halt, kind, reason, nil}
              end

            # The summarize call REFUSED or failed, or its summary did not survive the
            # ingress path. §5's whole point is that compaction is not a laundering channel,
            # so there is exactly one honest answer: the fold does not happen and the run
            # continues UNCOMPACTED on the span it already had. Appending an unscrubbed — or
            # un-obtained — summary anyway is the fail-OPEN reading this batch exists to make
            # impossible. §5#5's bounded `:compaction_refused` carries WHICH refusal it was
            # onto the turn row, so a refusal is never a silently shorter transcript.
            {:error, reason} ->
              {:ok, run, lines, refused(views, reason)}
          end
      end
    else
      {:ok, run, lines, views}
    end
  end

  # ADR-048 §5#1 — THE SUMMARIZE CALL. An ORDINARY governed `Samen.AI.complete/4`, sealed by
  # `Samen.AI.Chokepoint.seal/3` like every other provider-bound byte in this loop, with the
  # SAME `egress_opts/3` allowlist and therefore `grant_egress?: false` pinned LAST — a
  # caller-supplied `grant_egress?: true` cannot re-open grant plaintext on the summarize path
  # any more than it can on an ordinary turn. §5#1's "its input is already-masked history, so
  # no new egress class opens" is honoured BY CONSTRUCTION: the span rides `:history`, the
  # exact field prior turns re-enter through (re-scrubbed per §3.2a and allowlist-scanned per
  # §3.2 step 3/4, every call), and the only authored bytes are the compile-time
  # `summarizer_prompt/0` literal. No tool defs are offered — the summarizer selects nothing.
  defp summarize_span(scope, span, opts), do: Compaction.summarize(scope, span.folded, opts)

  # ADR-048 §5#6 — `:after_compaction`'s FIRST call site. It fires AFTER the summary has
  # passed §5#3's ingress path and been folded into the span's `llm_view` lines, and BEFORE
  # `apply_fold!/4` writes anything, so:
  #
  #   * a hook observes only GOVERNED bytes (post-redact, post-sanitize, allowlist-checked);
  #   * `:block` is meaningful — nothing has been persisted yet, so "skip this fold" is a
  #     real option and the run continues uncompacted (§5#5);
  #   * `{:edit, _}` is refused by `Hook`'s closed `@accepts` (it is not in the set) and
  #     `Hooks.refuse/1` turns it into the strongest refusal the point honours — a `:block`
  #     tagged `:hook_error`. The host's payload is NEVER applied to the summary, which is
  #     the one thing §5#6 forbids outright.
  #
  # The ctx is bounded and token-only like every other point's. It carries the SCRUBBED
  # summary, because a hook that cannot see what was folded cannot narrow on it — and by
  # construction those are the only bytes it can see.
  defp after_compaction_hook(hooks, %Run{} = run, span) do
    Hooks.dispatch(hooks, :after_compaction, %{
      run_id: run.id,
      agent: run.agent,
      org_id: run.org_id,
      turn_index: run.current_turn + 1,
      seq: span.seq,
      first_turn: span.first_turn,
      last_turn: span.last_turn,
      summary: span.marker
    })
  end

  # ADR-048 §5#5 — the fold was REFUSED. The views are returned UNCHANGED (that is what
  # "the run continues uncompacted" means: not a partial fold, not a dropped span) and the
  # transient note rides them to the turn row, where `note_compaction_refusal!/2` records it.
  # The note is NEVER persisted into the transcript blob: `encode_views/6` takes the four
  # view fields by name and this is not one of them.
  defp refused(views, reason), do: Map.put(views, :compaction_refusal, reason)

  # The bounded, observable half of §5#5: a refused fold leaves a NAMED note on the turn row
  # it would have folded for. The key is `safe_error_kind(:compaction_refused)` — routed
  # through the closed enum on purpose, so removing the kind from `@error_kinds` degrades
  # this note to `"unknown"` and the refusal stops being nameable (that is the mutation
  # `nodes/C3I2/work/mutation-controls.md` M4 records). The value is the bounded reason the
  # refusal carried, so `:pii_egress_refused`, `:unsafe_summary` and a hook's `:hook_error`
  # stay distinguishable on the record.
  defp note_compaction_refusal!(turn_row, views) do
    case Map.get(views, :compaction_refusal) do
      nil ->
        turn_row

      reason ->
        meta =
          (turn_row.meta || %{})
          |> Map.put(
            to_string(safe_error_kind(:compaction_refused)),
            Hooks.bounded_reason(reason)
          )
          |> bounded_meta()

        turn_row
        |> Ash.Changeset.for_update(:decide, %{meta: meta})
        |> Ash.update!(authorize?: false)
    end
  end

  # The model-written summary REPLACES the deterministic marker in the span, in place: the
  # marker sits at index `seq - 1` of `new_lines` (the `seq - 1` retained earlier markers
  # precede it), so this substitution cannot move a neighbouring segment.
  defp with_summary(span, summary) do
    %{span | marker: summary, new_lines: List.replace_at(span.new_lines, span.seq - 1, summary)}
  end

  # The `find_or_reuse_turn/3` row-reuse pattern, one level down (§6's own citation): the
  # ledger entry for THIS turn index, whatever checkpoint it stopped at.
  defp reusable_fold(%{folds: folds}, turn_index) when is_list(folds) do
    Enum.find(folds, fn
      %{"turn_index" => ^turn_index, "status" => status} -> status in ["proposed", "done"]
      _entry -> false
    end)
  end

  defp reusable_fold(_views, _turn_index), do: nil

  # REUSE, not re-derivation. Nothing is re-billed (the tokens were billed at checkpoint
  # 1), no span is re-selected, and D4 holds trivially: the `:advance` map carries the
  # transcript and nothing else — not `current_turn`, not `tool_calls_used`, not either
  # token counter. The stamp is persisted at the MOMENT of reuse rather than at the
  # commit, so a run that dies again still says on disk that its fold was replayed.
  defp reuse_fold!(%Run{} = run, views, goal, entry, lines) do
    replayed_entry =
      Map.put(entry, "meta", Map.put(Map.get(entry, "meta") || %{}, "replayed", true))

    folds = Enum.map(views.folds, fn e -> if e == entry, do: replayed_entry, else: e end)
    views = %{views | folds: folds}

    run =
      run
      |> Ash.Changeset.for_update(:advance, %{
        transcript:
          encode_views(
            goal,
            views.llm_view,
            views.ui_view,
            folds,
            views.turn_lens,
            views.pending
          )
      })
      |> Ash.update!(authorize?: false)

    {:ok, run, lines, views}
  end

  # SELECTION, kept apart from eligibility on purpose: oldest-first over the eligible
  # turns, whole turns only, and the SMALLEST prefix whose removal brings the assembled
  # context back under the watermark — the whole eligible span when no prefix can (a
  # watermark below the protected tail's own size is not a reason to fold nothing).
  defp fold_span(%Run{} = run, views, definition, tools, goal, lines) do
    segments = segments(views, lines)
    markers = length(views.folds)
    eligible = foldable(views, lines)

    if eligible == [] do
      nil
    else
      kept_markers = Enum.take(lines, markers)
      first_turn = 1 + Enum.sum(Enum.map(views.folds, &fold_covered/1))
      total = length(eligible)

      turns =
        Enum.find(1..total//1, total, fn k ->
          projected =
            kept_markers ++
              [fold_marker(markers + 1, first_turn, first_turn + k - 1)] ++
              Enum.concat(Enum.drop(segments, markers + k))

          context_tokens(definition, tools, goal, projected) <= run.context_cutoff_tokens
        end)

      marker = fold_marker(markers + 1, first_turn, first_turn + turns - 1)

      %{
        seq: markers + 1,
        first_turn: first_turn,
        last_turn: first_turn + turns - 1,
        turns: turns,
        marker: marker,
        folded: Enum.concat(Enum.take(eligible, turns)),
        new_lines: kept_markers ++ [marker] ++ Enum.concat(Enum.drop(segments, markers + turns)),
        new_lens:
          List.duplicate(1, markers + 1) ++
            (segments |> Enum.drop(markers + turns) |> Enum.map(&length/1))
      }
    end
  end

  defp apply_fold!(%Run{} = run, views, goal, span) do
    in_tokens = est_tokens(span.folded)
    out_tokens = est_tokens([span.marker])

    entry = %{
      "seq" => span.seq,
      "turn_index" => run.current_turn + 1,
      # UXD-18 checkpoint 1: the entry is born `"proposed"`. Only the cursor-advance
      # transaction may finalize it, so a `"done"` entry can never sit at a cursor that
      # has not passed the fold's own turn index.
      "status" => "proposed",
      "level" => 1,
      # ADR-048 §5: the body is MODEL-WRITTEN now — the summarize call above produced it —
      # so the ledger says so. C2's drop-with-marker was `true`; nothing else reads this
      # field, and the P10 arms refute exactly it.
      "deterministic" => false,
      "body" => span.marker,
      "covered" => span.turns,
      "lines" => length(span.folded),
      "first_turn" => span.first_turn,
      "last_turn" => span.last_turn,
      "input_tokens" => in_tokens,
      "output_tokens" => out_tokens,
      "meta" => %{"replayed" => false}
    }

    folded_views = %{
      views
      | llm_view: span.new_lines,
        ui_view: views.ui_view ++ [fold_note(span)],
        folds: views.folds ++ [entry],
        turn_lens: span.new_lens
    }

    run =
      run
      |> Ash.Changeset.for_update(:advance, %{
        transcript:
          encode_views(
            goal,
            folded_views.llm_view,
            folded_views.ui_view,
            folded_views.folds,
            folded_views.turn_lens,
            views.pending
          ),
        input_tokens_used: run.input_tokens_used + in_tokens,
        output_tokens_used: run.output_tokens_used + out_tokens
      })
      |> Ash.update!(authorize?: false)

    {:ok, run, span.new_lines, folded_views}
  end

  defp fold_covered(%{"covered" => n}) when is_integer(n) and n > 0, do: n
  defp fold_covered(_entry), do: 1

  defp fold_marker(seq, turn, turn), do: "[folded: turn #{turn} → fold ##{seq}]"

  defp fold_marker(seq, first, last), do: "[folded: turns #{first}–#{last} → fold ##{seq}]"

  defp fold_note(span) do
    "[fold ##{span.seq}: turns #{span.first_turn}–#{span.last_turn} were folded out of " <>
      "the model's working set. Nothing above was removed from this record.]"
  end

  # A deterministic size estimate over exactly the bytes the turn would seal: the authored
  # goal prompt, the tenant goal, the re-entering history, and the static tool defs. A pure
  # function of its arguments (§6's determinism rule) — no provider round-trip, no model,
  # no clock. ~4 bytes per token is the standard coarse approximation; the watermark is a
  # policy threshold, not a billing figure, and the real spend ceilings
  # (`max_input_tokens`/`max_output_tokens`) are still enforced from measured usage.
  defp context_tokens(definition, tools, goal, lines) do
    est_tokens(
      [definition.goal_prompt, goal | lines] ++ Enum.map(Tools.defs(tools), &def_bytes/1)
    )
  end

  # The ONE deterministic estimator: the fold's own bill (§6 "the tokens are real and are
  # billed") is measured with exactly the function that decides the watermark, so a fold
  # can never bill on one scale and trigger on another.
  defp est_tokens(texts) do
    texts
    |> Enum.map(fn text -> div(byte_size(text) + 3, 4) end)
    |> Enum.sum()
  end

  defp def_bytes(schema) do
    case Jason.encode(schema) do
      {:ok, json} -> json
      {:error, _} -> ""
    end
  end

  # ------------------------------------------------------------------------------------
  # T181 — the declared hook seam's call sites (ADR-047 §10a row 25)

  # `:session_start` fires ONCE per run, at the top of the first turn — which is the one
  # place both modes share (`run/4`'s inline loop and the durable worker's batch), so the
  # point cannot be reached in one mode and skipped in the other. A watchdog replay of
  # turn 1 re-fires it; hooks are documented as idempotent.
  # Resolve the chain once and put it on `opts`. Always `{:ok, _}` — an unloadable or
  # misconfigured hook module is NOT filtered out here; it stays in the chain and refuses
  # at dispatch time, because dropping it would run the loop with less policy than the
  # host configured (`Samen.AI.Agent.Hooks`' fail-closed posture).
  defp resolve_hooks(opts), do: {:ok, Keyword.put(opts, :resolved_hooks, Hooks.resolve(opts))}

  defp session_start_hook(hooks, %Run{current_turn: 0} = run) do
    case Hooks.dispatch(hooks, :session_start, %{
           run_id: run.id,
           agent: run.agent,
           org_id: run.org_id,
           turn_index: 1
         }) do
      :ok -> :ok
      {:halt, kind, reason} -> {:halt, kind, reason, nil}
    end
  end

  defp session_start_hook(_hooks, _run), do: :ok

  # `:before_completion` fires after the DECISION checkpoint has committed the turn row
  # `:proposed` and before the provider call — the last point at which stopping the run
  # costs nothing, because no bytes have left for the provider yet.
  defp before_completion_hook(hooks, %Run{} = run, turn_row, turn_index) do
    case Hooks.dispatch(hooks, :before_completion, %{
           run_id: run.id,
           agent: run.agent,
           org_id: run.org_id,
           turn_index: turn_index
         }) do
      :ok -> :ok
      {:halt, kind, reason} -> {:halt, kind, reason, turn_row}
    end
  end

  # The one terminal a hook can cause. Fail-honest by construction: an explicit terminal
  # state with the bounded kind `:hook_halted` and the bounded reason on the turn row —
  # never `{:ok, answer}`, never a partial answer promoted out of the transcript.
  defp halt_run(%Run{} = run, turn_row, kind, reason) do
    if turn_row do
      finalize_turn!(turn_row, %{
        status: :failed,
        error_kind: to_string(safe_error_kind(kind)),
        meta: bounded_meta(Map.put(turn_row.meta || %{}, "hook_reason", reason))
      })
    end

    run = terminal!(run, :fail, kind)
    log_terminal(run)
    {:error, safe_error_kind(kind), run}
  end

  # The OUTCOME checkpoint (§4.1 checkpoint 2): finalize the turn row, advance the run
  # cursor (+ the vault-routed transcript, + counters, + the re-armed watchdog), and —
  # for a FINAL turn — the terminal transition, all in ONE DB transaction, so a :done
  # turn row and the cursor can never disagree (the replay-idempotency load-bearer).
  defp commit_turn!(
         %Run{} = run,
         turn_row,
         %Completion{} = completion,
         next,
         duration_ms,
         {goal, lines},
         replayed?
       ) do
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
          # MERGED, not replaced: ADR-048 §6 Level 2's `context_retries` counter is
          # stamped on the `:proposed` row before the retry and must survive the
          # finalize (the `commit_tool_turn!` idiom, applied here too).
          meta: bounded_meta(Map.put(turn_row.meta || %{}, "replayed", replayed?))
        })

        run =
          run
          |> Ash.Changeset.for_update(:advance, %{
            current_turn: turn_index,
            next_turn_at: DateTime.add(DateTime.utc_now(), @inflight_watchdog_seconds),
            transcript: encode_transcript_finalizing(run, goal, lines ++ [completion.text]),
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
  #
  # T181 threads the declared hook seam through steps 1-3: `:after_tool_request` sees the
  # RAW model request before the intersection resolves it, `:before_tool_call` sees the
  # already-validated call and may block, edit, or halt it, and `:after_tool_execution`
  # sees the outcome before it is committed. An edit re-runs the WHOLE arg gate.
  defp tool_turn(
         run,
         scope,
         opts,
         turn_row,
         completion,
         kind,
         args,
         duration_ms,
         {goal, lines},
         replayed?
       ) do
    tools = Keyword.get(opts, :resolved_tools, [])
    hooks = Keyword.get(opts, :resolved_hooks, [])

    case Hooks.dispatch(hooks, :after_tool_request, %{
           run_id: run.id,
           agent: run.agent,
           org_id: run.org_id,
           kind: kind,
           arg_keys: sorted_arg_keys(args)
         }) do
      :ok ->
        authorized_tool_turn(
          run,
          scope,
          {tools, hooks},
          turn_row,
          completion,
          kind,
          args,
          duration_ms,
          {goal, lines},
          replayed?
        )

      {:block, block_kind, reason} ->
        # The requested kind has not been through the intersection yet, so only a
        # REGISTRY kind may land in the persisted column (an arbitrary model string
        # never does — the arm-1 rule, unchanged).
        hook_blocked_turn(
          run,
          turn_row,
          completion,
          if(Tools.registry_kind?(kind), do: kind, else: nil),
          block_kind,
          reason,
          duration_ms,
          {goal, lines},
          replayed?,
          hooks
        )

      {:halt, halt_kind, reason} ->
        halt_run(run, turn_row, halt_kind, reason)
    end
  end

  defp authorized_tool_turn(
         run,
         scope,
         {tools, hooks},
         turn_row,
         completion,
         kind,
         args,
         duration_ms,
         {goal, lines},
         replayed?
       ) do
    case authorize_tool(tools, kind, args) do
      {:ok, entry, normalized} ->
        # T181 `:before_tool_call` — the ONE point that may block, EDIT, or halt. It sits
        # AFTER the four-way intersection and the action's own `validate/2` (so a hook
        # never sees, and can never admit, a call the loop itself would refuse) and
        # BEFORE `decide_tool!/3` (so an edit changes the call that is stamped, executed,
        # and — for a write — bound to the approval; there is no logged-only copy).
        case Hooks.dispatch(hooks, :before_tool_call, %{
               run_id: run.id,
               agent: run.agent,
               org_id: run.org_id,
               kind: entry.kind,
               effect: entry.effect,
               args: normalized
             }) do
          :ok ->
            decided_tool_turn(
              run,
              scope,
              hooks,
              turn_row,
              completion,
              entry,
              normalized,
              duration_ms,
              {goal, lines},
              replayed?
            )

          {:edit, %{args: edited}} ->
            edited_tool_turn(
              run,
              scope,
              hooks,
              turn_row,
              completion,
              entry,
              edited,
              duration_ms,
              {goal, lines},
              replayed?
            )

          {:block, block_kind, reason} ->
            hook_blocked_turn(
              run,
              turn_row,
              completion,
              entry.kind,
              block_kind,
              reason,
              duration_ms,
              {goal, lines},
              replayed?,
              hooks
            )

          {:halt, halt_kind, reason} ->
            halt_run(run, turn_row, halt_kind, reason)
        end

      {:error, refusal_kind, known_kind} ->
        feedback_turn(
          run,
          turn_row,
          completion,
          refusal_kind,
          known_kind,
          duration_ms,
          {goal, lines},
          replayed?,
          hooks,
          nil
        )
    end
  end

  # Hooks may only NARROW. Edited args are UNTRUSTED exactly like the model's own: they
  # re-run the `vt_` sentinel gate AND the action's own `validate/2` before anything is
  # stamped or executed, so an edit cannot smuggle in a vault token to unmask a field,
  # cannot hand the action a payload its validator rejects, and (by
  # `Samen.AI.Agent.Hooks`' identity rule) cannot change WHICH tool runs.
  defp edited_tool_turn(
         run,
         scope,
         hooks,
         turn_row,
         completion,
         entry,
         edited,
         duration_ms,
         {goal, lines},
         replayed?
       ) do
    with :ok <- refuse_vt_args(edited),
         {:ok, normalized} <- validate_args(entry.module, edited) do
      decided_tool_turn(
        run,
        scope,
        hooks,
        turn_row,
        completion,
        entry,
        normalized,
        duration_ms,
        {goal, lines},
        replayed?
      )
    else
      {:error, refusal_kind} ->
        feedback_turn(
          run,
          turn_row,
          completion,
          refusal_kind,
          entry.kind,
          duration_ms,
          {goal, lines},
          replayed?,
          hooks,
          nil
        )
    end
  end

  defp decided_tool_turn(
         run,
         scope,
         hooks,
         turn_row,
         completion,
         entry,
         normalized,
         duration_ms,
         {goal, lines},
         replayed?
       ) do
    case entry do
      # A4 (ADR-047 §5.3; ADR-043 §6.2 unamended): a MUTATING tool never executes here.
      # It passed the same four-way intersection a read tool passes — and that admission
      # buys it a PROPOSAL, not an execution. The decision stamp lands first (so the
      # args digest that BINDS the proposal is committed before anything else), then the
      # E3 approval opens and the run parks. `entry.module.run/2` is not called on this
      # path at all; the ONLY caller of it for a write is `execute_approved/3`, after a
      # distinct human approved, with the APPROVER's actor.
      # T181: a hook can BLOCK a proposal (narrowing), and no hook return can approve
      # one — a write still parks for a distinct human. There is no widening decision.
      %{effect: :write} = entry ->
        turn_row = decide_tool!(turn_row, entry.kind, normalized)

        propose_turn(
          run,
          turn_row,
          completion,
          entry,
          normalized,
          duration_ms,
          {goal, lines},
          replayed?,
          hooks
        )

      entry ->
        turn_row = decide_tool!(turn_row, entry.kind, normalized)
        outcome = run_tool(entry, normalized, run, scope)

        # T181 `:after_tool_execution` — the outcome is visible before it is committed,
        # and the only decision the point honours is `:halt`. The executed turn is
        # committed FIRST either way: a halt stops the RUN, it never un-records work the
        # governed action already did.
        decision =
          Hooks.dispatch(hooks, :after_tool_execution, %{
            run_id: run.id,
            agent: run.agent,
            org_id: run.org_id,
            kind: entry.kind,
            arg_keys: sorted_arg_keys(normalized),
            error_kind: outcome_error_kind(outcome)
          })

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

        case decision do
          {:halt, halt_kind, reason} -> halt_run(run, nil, halt_kind, reason)
          _ -> {:continue, run}
        end
    end
  end

  # T181: a hook's honest refusal of ONE tool call. Structurally the same fail-honest
  # turn a refused/invalid call already produces — nothing executed, nothing proposed,
  # the bounded kind `:hook_blocked` on the row (plus the bounded reason in `meta`) and
  # one bounded line fed back, so the run continues under its budgets.
  defp hook_blocked_turn(
         run,
         turn_row,
         completion,
         known_kind,
         block_kind,
         reason,
         duration_ms,
         {goal, lines},
         replayed?,
         hooks
       ) do
    feedback_turn(
      run,
      turn_row,
      completion,
      block_kind,
      known_kind,
      duration_ms,
      {goal, lines},
      replayed?,
      hooks,
      reason
    )
  end

  # A tool call the run could not even execute (outside the intersection, poisoned or
  # invalid args, malformed envelope, a hook's block): the HONEST refusal turn. Recorded
  # on the turn row (bounded error_kind; tool_kind only when the requested kind is a
  # REGISTRY kind — an arbitrary model string never lands in a persisted column) and fed
  # back to the model as one bounded fixed line, so the run continues under its budgets.
  # Never a silent skip, never an execution.
  #
  # T181: this is the ONE place the loop absorbs an error and keeps going, so it is where
  # `:on_error` fires. A hook may escalate the absorbed error into a fail-honest terminal
  # halt — after the refusal turn is committed, so the record of WHY still lands. (The
  # provider-error branch of `execute_turn/4` is already unconditionally terminal and does
  # not fire the point: there is no decision left there to take.)
  defp feedback_turn(
         run,
         turn_row,
         completion,
         refusal_kind,
         known_kind,
         duration_ms,
         {goal, lines},
         replayed?,
         hooks,
         hook_reason
       ) do
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
        replayed?: replayed?,
        hook_reason: hook_reason
      })

    case Hooks.dispatch(hooks, :on_error, %{
           run_id: run.id,
           agent: run.agent,
           org_id: run.org_id,
           kind: known_kind,
           error_kind: safe_error_kind(refusal_kind),
           reason: hook_reason
         }) do
      {:halt, halt_kind, reason} -> halt_run(run, nil, halt_kind, reason)
      _ -> {:continue, run}
    end
  end

  # ------------------------------------------------------------------------------------
  # A4 — write via approval (ADR-047 §5.3; ADR-043 §6.2 unamended)

  # PROPOSE + PARK. Nothing is mutated: the E3 approval is opened against the still-
  # `:proposed` `{run_id, turn_index}` turn row (so a replay proposes ONCE — the engine's
  # own `{org_id, kind, subject_ref}` pending-idempotency), the model's call ECHO plus a
  # bounded "proposed" line join the vault-routed transcript, and the run parks
  # `:awaiting_approval` with `next_turn_at` armed to the approval deadline (non-nil —
  # the run is NOT terminal). The proposed ARGS ride the transcript, i.e. inside the DEK
  # envelope; the approval row and the turn row hold only tokens.
  #
  # An approvals engine that cannot open the approval (unwired host, unregistered kind,
  # write failure) is a fail-honest `:approval_unavailable` feedback turn — the run keeps
  # going under its budgets and NOTHING is executed. The failure mode of a broken
  # approvals seam is "the agent cannot propose", never "the agent just did it".
  defp propose_turn(
         run,
         turn_row,
         completion,
         entry,
         normalized,
         duration_ms,
         {goal, lines},
         replayed?,
         hooks
       ) do
    case WriteProposal.open(%{
           org_id: run.org_id,
           turn_id: turn_row.id,
           tool_kind: entry.kind,
           args: normalized
         }) do
      {:ok, approval} ->
        approval_id = to_string(approval.id)

        new_lines = [
          ToolResult.render_call(entry.kind, normalized),
          "tool_proposed: #{entry.kind} status=awaiting_human_approval"
        ]

        pending = %{
          "approval_id" => approval_id,
          "kind" => entry.kind,
          "turn_index" => turn_row.turn_index,
          "digest" => args_digest(normalized),
          "args" => normalized
        }

        _ = stamp_proposal!(turn_row, approval_id, replayed?)
        run = park_run!(run, completion, {goal, lines ++ new_lines}, pending, approval)
        log_terminal(run)
        {:awaiting_approval, run}

      {:error, reason} ->
        require Logger

        Logger.warning(
          "[Samen.AI.Agent] write proposal NOT opened run=#{run.id} " <>
            "tool=#{entry.kind} reason=#{inspect(reason)} — nothing was executed"
        )

        feedback_turn(
          run,
          turn_row,
          completion,
          :approval_unavailable,
          entry.kind,
          duration_ms,
          {goal, lines},
          replayed?,
          hooks,
          nil
        )
    end
  end

  # The proposal stamp: the approval id joins the turn row's bounded meta alongside the
  # args digest `decide_tool!/3` already committed. The row stays `:proposed` — it is the
  # idempotency key the approved execution finalizes, so a proposal can never be
  # double-executed and a park can never be mistaken for a completed turn.
  defp stamp_proposal!(turn_row, approval_id, replayed?) do
    meta =
      (turn_row.meta || %{})
      |> Map.put("approval_id", approval_id)
      |> Map.put("awaiting_approval", true)
      |> Map.put("replayed", replayed?)

    turn_row
    |> Ash.Changeset.for_update(:decide, %{meta: bounded_meta(meta)})
    |> Ash.update!(authorize?: false)
  end

  defp park_run!(%Run{} = run, %Completion{} = completion, {goal, lines}, pending, approval) do
    run
    |> Ash.Changeset.for_update(:park, %{
      next_turn_at: park_deadline(approval),
      transcript: encode_transcript(run, goal, lines, pending),
      # The provider turn genuinely happened, so its tokens are billed. `tool_calls_used`
      # is NOT touched: nothing executed (A3's `executed?` rule, unchanged) — the
      # approved execution bills the one tool call it actually performs.
      input_tokens_used: run.input_tokens_used + usage_int(completion.usage, :input_tokens),
      output_tokens_used: run.output_tokens_used + usage_int(completion.usage, :output_tokens)
    })
    |> Ash.update!(authorize?: false)
  end

  defp park_deadline(%{deadline_at: %DateTime{} = at}), do: at
  defp park_deadline(_approval), do: DateTime.add(DateTime.utc_now(), @inflight_watchdog_seconds)

  @doc """
  Execute an APPROVED write proposal — called ONLY by `Samen.AI.Agent.WriteProposal`'s
  `on_approve/2`, INSIDE the E3 decision transaction, after the engine has already
  refused `decided_by == requested_by` at both the policy and DB-CHECK layers.

  **The approval itself is verified from the DATABASE, not from the argument.** The struct
  handed in is caller-supplied — this function is public because the E3 handler lives in
  its own module — and its `id` is the only field an attacker needs, which is exactly the
  field that sits in the PLAIN `atn_meta.approval_id` column next to the proposal. So
  `verify_approval/4` re-loads the row through the engine and requires it to be a real,
  `:approved`-state approval, in the RUN's org, of this module's kind, hanging on THIS
  turn's `subject_ref`, decided by a distinct party who is the actor now executing. A
  forged map, a still-`pending` row, a rejected/cancelled row, or another org's approval
  all refuse fail-closed — so the execution can never outrun the state transition that
  makes the decision real and writes its audit event.

  Three properties are load-bearing here, and each has its own sabotage:

    * **the approval of proposal X executes exactly X** — `bind_proposal/3` re-derives the
      proposal from the vault-routed transcript and requires it to agree, field by field,
      with the token-only stamp committed on the turn row BEFORE the approval was opened:
      the sha256 args digest recomputed over the stored args, the digest recorded in the
      proposal, the tool kind, the arg key names, the turn index, and the approval id. A
      payload mutated or substituted between proposal and approval — in either store —
      refuses `:proposal_mismatch`, which rolls the whole decision back;
    * **only an APPROVED approval executes** — `verify_approval/4` (above); sabotage 256
      drops the state guard and a still-`pending` approval executes the parked write with
      no decision transition and no `approval_approved` audit event;
    * **execution carries the APPROVER's authority, never the agent's** — the governed
      action runs as a principal built from the DECIDING actor. The AI service principal
      that requested it holds no write authority on this path (or any other), which is
      what makes ADR-043 §6.2 ("AI writes do not exist") structurally true rather than
      procedurally hoped-for.

  The full four-way intersection is re-resolved here, not trusted from proposal time: a
  tool de-registered, de-opted-in, or de-declared while the approval sat pending refuses
  `:tool_refused`. `validate/2` and the `vt_` arg gate run again too.

  Any `{:error, _}` rolls the decision back: the approval stays `pending`, the run stays
  parked, nothing executed, no audit lands.
  """
  @spec execute_approved(String.t(), struct(), map()) :: {:ok, map()} | {:error, term()}
  def execute_approved(turn_id, approval, ctx) do
    approver_id = deciding_actor_id(ctx)

    with {:ok, turn_row} <- fetch_turn(turn_id),
         :ok <- turn_proposed?(turn_row),
         {:ok, run} <- fetch_run(turn_row.run_id),
         :ok <- run_parked?(run),
         :ok <- refuse_principal_execution(approver_id),
         {:ok, approval} <- verify_approval(approval, run, turn_row, approver_id),
         {:ok, approver_scope} <- approver_scope(approver_id, run),
         {:ok, {goal, lines, pending}} <- transcript_state(run),
         {:ok, proposal} <- bind_proposal(pending, turn_row, approval),
         {:ok, agent_mod} <- resolve_agent(run),
         {:ok, entry} <- resolve_write_tool(agent_mod, proposal.kind),
         {:ok, normalized} <- revalidate_proposal_args(entry, proposal) do
      case run_tool(entry, normalized, run, approver_scope) do
        {:ok, meta} ->
          new_lines =
            ["tool_approved: #{entry.kind} executed_by=approver"] ++
              ToolResult.render({:ok, meta}, actor: scope_actor(approver_scope))

          run =
            commit_approved!(run, turn_row, {goal, lines}, new_lines, %{
              kind: entry.kind,
              normalized: normalized,
              approval_id: to_string(approval.id),
              approver_id: approver_id,
              # A5 (the A4 verifier's R2, second half): the approver's REAL role, as
              # resolved from their membership row — a bounded enum, token-only (§6).
              # A4 hardcoded `:member` here, so the audit trail could not distinguish
              # an owner's consent from a silently-elevated narrower role. Recording it
              # makes the resolved role observable, which is what makes sabotage 257's
              # re-synthesis flip a named test rather than pass unnoticed.
              approver_role: scope_role(approver_scope)
            })

          # Same-transaction resume enqueue (the EventCapture idiom): the continuation
          # job exists iff the decision committed. A lost enqueue is recovered by the
          # `:agent_turn_due` watchdog, which can now see the run again (it is :running).
          _ = Samen.AI.Agent.TurnWorker.enqueue(run.id)

          {:ok,
           %{
             executed: entry.kind,
             run_id: to_string(run.id),
             turn_index: turn_row.turn_index,
             executed_by: "approver"
           }}

        {:error, kind} ->
          # A genuine tool failure is NOT swallowed into an :ok and does NOT consume the
          # approval: the whole decision rolls back, so an approver who approved X and
          # got nothing still holds a pending approval to retry or reject (the
          # ReplyHandler fail-honest posture).
          {:error, {:tool_failed, safe_error_kind(kind)}}
      end
    end
  end

  @doc """
  Handle a REJECTED write proposal (the `on_reject/2` face) — inside the reject
  transaction. The governed action is never invoked. The run terminates `:rejected`, an
  honest terminal of its own, with a bounded line appended to the transcript so a later
  reader sees WHY the run stopped. A missing/garbled turn or an already-decided run never
  blocks the rejection (the `ReplyHandler` precedent).
  """
  @spec reject_proposal(String.t(), struct(), map()) :: :ok | {:error, term()}
  def reject_proposal(turn_id, _approval, _ctx) do
    with {:ok, turn_row} <- fetch_turn(turn_id),
         {:ok, %Run{state: :awaiting_approval} = run} <- fetch_run(turn_row.run_id) do
      finalize_turn!(turn_row, %{
        status: :failed,
        error_kind: "rejected",
        meta: bounded_meta(Map.put(turn_row.meta || %{}, "rejected", true))
      })

      attrs =
        case transcript_state(run) do
          {:ok, {goal, lines, _pending}} ->
            kind = turn_row.tool_kind || "write"
            %{transcript: encode_transcript(run, goal, lines ++ ["tool_rejected: #{kind}"])}

          _ ->
            %{}
        end

      run =
        run
        |> Ash.Changeset.for_update(:reject, attrs)
        |> Ash.update!(authorize?: false)

      log_terminal(run)
      :ok
    else
      _ -> :ok
    end
  end

  @doc """
  Expire a PARKED run whose approval deadline has lapsed (ADR-047 §5.3; the A4
  verifier's R4b, closed at A5).

  A4 parked a run on a human decision and set `next_turn_at` to the approval deadline,
  but nothing ever swept it: a lapsed proposal sat decidable forever, and the run was an
  unselectable in-flight state. `:awaiting_approval` is now swept by the
  `:agent_proposal_expiry` AshOban trigger, which drives this path.

  What expiry IS, precisely: the pending approval is **withdrawn** (via the requester's
  own `Samen.Approvals.cancel/3` — `decided_by` stays NULL, so the distinct-party CHECK
  is untouched and the audit trail never claims a human decided), the still-`:proposed`
  turn row is finalized `:failed` / `deadline_expired`, one bounded line is appended to
  the vault-routed transcript so a later reader sees WHY the run stopped, and the run
  lands in the honest terminal `:expired` with `next_turn_at` cleared (never-nil holds:
  the run is terminal). **The proposed write is never executed** — and cannot be, because
  `execute_approved/3` requires `run_parked?/1` AND a genuinely `:approved` approval row,
  and the withdrawal makes the second impossible while the terminal makes the first
  impossible.

  Public + idempotent so the sweep is directly drivable in a test (and by an operator
  surface) without waiting on a cron tick. A run that is not parked is a no-op.
  """
  @spec expire_parked(Ash.Resource.record() | String.t()) ::
          {:ok, Ash.Resource.record()} | {:error, term()}
  def expire_parked(%Run{} = run), do: expire_parked(run.id)

  def expire_parked(run_id) when is_binary(run_id) do
    with {:ok, %Run{state: :awaiting_approval} = run} <- fetch_run(run_id) do
      {:ok,
       run
       |> Ash.Changeset.for_update(:expire_due, %{})
       |> Ash.update!(authorize?: false)}
    else
      {:ok, %Run{}} -> {:error, :run_not_parked}
      other -> other
    end
  end

  def expire_parked(_run), do: {:error, :not_found}

  @doc false
  @spec on_proposal_expired(Ash.Resource.record()) :: :ok
  def on_proposal_expired(%Run{} = updated) do
    # Re-read the row so the vault-routed transcript is a `%Samen.Masked{}` this path can
    # reveal: the record an update hands back carries the just-written attributes, not
    # necessarily the loaded vault token.
    run =
      case fetch_run(updated.id) do
        {:ok, %Run{} = reloaded} -> reloaded
        _ -> updated
      end

    # 1. Withdraw the pending approval FIRST — the lapsed proposal must stop being
    #    decidable in the same transaction that terminates the run.
    _ = withdraw_pending_approval(run)

    # 2. Finalize the still-:proposed turn row honestly (token-only, bounded kind).
    case pending_turn(run) do
      {:ok, turn_row} ->
        finalize_turn!(turn_row, %{
          status: :failed,
          error_kind: "deadline_expired",
          meta: bounded_meta(Map.put(turn_row.meta || %{}, "expired", true))
        })

      _ ->
        :ok
    end

    # 3. One bounded transcript line (inside the DEK envelope), and the pending proposal
    #    CLEARED by the 2-arity encoder — an expired proposal is never re-bindable.
    case transcript_state(run) do
      {:ok, {goal, lines, _pending}} ->
        kind = pending_kind(run) || "write"

        run
        |> Ash.Changeset.for_update(:advance, %{
          transcript: encode_transcript(run, goal, lines ++ ["tool_expired: #{kind}"])
        })
        |> Ash.update!(authorize?: false)

      _ ->
        :ok
    end

    log_terminal(run)
    :ok
  rescue
    _ -> :ok
  end

  defp pending_turn(%Run{} = run) do
    require Ash.Query

    Turn
    |> Ash.Query.filter(run_id == ^run.id and status == :proposed)
    |> Ash.Query.sort(turn_index: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read(authorize?: false)
    |> case do
      {:ok, [turn]} -> {:ok, turn}
      _ -> {:error, :turn_not_found}
    end
  rescue
    _ -> {:error, :turn_not_found}
  end

  defp pending_kind(%Run{} = run) do
    case transcript_state(run) do
      {:ok, {_goal, _lines, pending}} when is_map(pending) -> Map.get(pending, "kind")
      _ -> nil
    end
  end

  # THE STATE + IDENTITY GUARD on the approval itself (see the `execute_approved/3` doc).
  # Everything here is read from the PERSISTED row: the argument is only ever used for its
  # id. Inside the E3 decision transaction the `pending -> approved` transition has already
  # been applied, so a genuine decision sees `:approved` on this same connection — while a
  # caller who reached this seam directly, holding nothing but the id, sees `:pending` and
  # is refused.
  defp verify_approval(approval, %Run{} = run, turn_row, approver_id) do
    case load_approval(approval_id_of(approval)) do
      {:ok, loaded} ->
        cond do
          loaded.state != :approved ->
            {:error, :approval_not_approved}

          loaded.org_id != run.org_id ->
            {:error, :approval_org_mismatch}

          loaded.kind != WriteProposal.kind() ->
            {:error, :proposal_mismatch}

          loaded.subject_ref != WriteProposal.subject_ref(turn_row.id) ->
            {:error, :proposal_mismatch}

          not is_binary(loaded.decided_by) or loaded.decided_by == "" ->
            {:error, :approval_not_approved}

          # The persisted decision IS the authority: the actor executing must be the party
          # the row records as having decided, and that party must be distinct from the
          # requester (the engine's own rule, re-asserted from the row rather than trusted
          # from the call).
          loaded.decided_by == loaded.requested_by ->
            {:error, :not_authorized}

          loaded.decided_by != approver_id ->
            {:error, :not_authorized}

          true ->
            {:ok, loaded}
        end

      _ ->
        {:error, :approval_not_found}
    end
  end

  # Fail-closed on every edge: a nil/garbled/unknown id is `:approval_not_found`, never a
  # raise escaping into the decision transaction.
  defp load_approval(nil), do: {:error, :approval_not_found}

  defp load_approval(id) do
    Samen.Approvals.get(id)
  rescue
    _ -> {:error, :approval_not_found}
  end

  defp approval_id_of(%{id: id}) when is_binary(id), do: id
  defp approval_id_of(%{id: id}) when not is_nil(id), do: to_string(id)
  defp approval_id_of(_approval), do: nil

  # THE BINDING (RP-AG-5's "exactly X" half). Two independent stores must agree: the
  # token-only stamp on the turn row (a plain column, committed BEFORE the approval was
  # opened) and the proposal inside the run's DEK envelope. Tampering with either one
  # alone refuses; tampering with both requires the vault key AND the domain row.
  defp bind_proposal(pending, turn_row, approval) when is_map(pending) do
    stamped = Map.get(turn_row.meta || %{}, "args_digest")
    kind = Map.get(pending, "kind")
    args = Map.get(pending, "args")

    cond do
      not is_binary(stamped) -> {:error, :proposal_mismatch}
      not is_binary(kind) -> {:error, :proposal_mismatch}
      not (is_map(args) and not is_struct(args)) -> {:error, :proposal_mismatch}
      Map.get(pending, "digest") != stamped -> {:error, :proposal_mismatch}
      args_digest(args) != stamped -> {:error, :proposal_mismatch}
      kind != turn_row.tool_kind -> {:error, :proposal_mismatch}
      sorted_arg_keys(args) != turn_row.arg_keys -> {:error, :proposal_mismatch}
      Map.get(pending, "turn_index") != turn_row.turn_index -> {:error, :proposal_mismatch}
      Map.get(pending, "approval_id") != to_string(approval.id) -> {:error, :proposal_mismatch}
      true -> {:ok, %{kind: kind, args: args}}
    end
  end

  defp bind_proposal(_pending, _turn_row, _approval), do: {:error, :proposal_mismatch}

  # The intersection, re-resolved at EXECUTION time (arms 1-3) — never trusted from
  # proposal time. Arm 4 binds inside the action's own governed writes, as the approver.
  defp resolve_write_tool(agent_mod, kind) do
    with definition when is_map(definition) <- agent_mod.definition(),
         {:ok, tools} <- Tools.resolve_definition(definition),
         {:ok, %{effect: :write} = entry} <- Tools.resolve_call(tools, kind) do
      {:ok, entry}
    else
      _ -> {:error, :tool_refused}
    end
  end

  # The arg gates run AGAIN at execution, and the re-validation must be STABLE: a
  # validator that normalizes to different bytes than the digest bound at decision time
  # would execute something the approver never saw.
  defp revalidate_proposal_args(entry, proposal) do
    with :ok <- refuse_vt_args(proposal.args),
         {:ok, normalized} <- validate_args(entry.module, proposal.args),
         true <- args_digest(normalized) == args_digest(proposal.args) do
      {:ok, normalized}
    else
      false -> {:error, :proposal_mismatch}
      {:error, kind} -> {:error, kind}
    end
  end

  defp commit_approved!(%Run{} = run, turn_row, {goal, lines}, new_lines, stamp) do
    meta =
      (turn_row.meta || %{})
      |> Map.delete("awaiting_approval")
      |> Map.put("approved", true)
      |> Map.put("approval_id", stamp.approval_id)
      |> Map.put("approver_id", stamp.approver_id)
      |> Map.put("approver_role", stamp.approver_role)
      |> Map.put("executed_by", "approver")

    finalize_turn!(turn_row, %{
      status: :done,
      tool_kind: stamp.kind,
      arg_keys: sorted_arg_keys(stamp.normalized),
      meta: bounded_meta(meta)
    })

    run
    |> Ash.Changeset.for_update(:resume, %{
      current_turn: turn_row.turn_index,
      next_turn_at: DateTime.utc_now(),
      # The pending proposal is CLEARED (the 2-arity encoder): an executed proposal must
      # never be re-bindable by a second decision. This is also a cursor advance, so it
      # is a UXD-18 checkpoint 2 and finalizes any `:proposed` fold entry with it.
      transcript: encode_transcript_finalizing(run, goal, lines ++ new_lines),
      tool_calls_used: run.tool_calls_used + 1,
      input_tokens_used: run.input_tokens_used,
      output_tokens_used: run.output_tokens_used
    })
    |> Ash.update!(authorize?: false)
  end

  defp turn_proposed?(%{status: :proposed}), do: :ok
  defp turn_proposed?(_turn_row), do: {:error, :not_pending}

  defp run_parked?(%Run{state: :awaiting_approval}), do: :ok
  defp run_parked?(_run), do: {:error, :run_not_parked}

  # The DECIDING actor (`Samen.Approvals.Handler`'s ctx contract: `actor` is the approver,
  # already normalized to a bounded id by the engine's `to_actor_id/1`).
  defp deciding_actor_id(%{actor: actor}), do: bounded_actor_id(actor)
  defp deciding_actor_id(_ctx), do: nil

  defp bounded_actor_id(id) when is_binary(id), do: id
  defp bounded_actor_id(%{id: id}) when is_binary(id), do: id
  defp bounded_actor_id(_), do: nil

  # Belt-and-braces third layer under the engine's policy refusal and the
  # `<abbrev>_distinct_party` DB CHECK: the AI service principal can never be the actor a
  # write executes as, even if some future caller reached this function directly.
  defp refuse_principal_execution(actor_id) do
    if is_binary(actor_id) and actor_id != WriteProposal.requester_principal_id(),
      do: :ok,
      else: {:error, :not_authorized}
  end

  # A5 (the A4 verifier's R2): the approver is RESOLVED, never synthesized. A4 built
  # `%Scope{id: <unvalidated argument>, org_id: run.org_id, role: :member}` here, so
  # (i) membership was never verified — a wholly foreign actor id executed a governed
  # write in the run's org — and (ii) the role was hardcoded, silently ELEVATING an
  # approver whose real role is narrower. `Samen.AI.Agent.Approver.resolve/2` reads the
  # host's REAL membership row for {approver, run org} and carries its REAL role; a
  # non-member refuses `:not_authorized` and an unwired host refuses
  # `:approver_unresolvable` — either way the whole E3 decision rolls back, the approval
  # stays pending, and nothing executed. Sabotage 257 puts the synthesis back.
  defp approver_scope(approver_id, %Run{org_id: org_id}),
    do: Approver.resolve(approver_id, org_id)

  defp fetch_turn(turn_id) when is_binary(turn_id) do
    require Ash.Query

    Turn
    |> Ash.Query.filter(id == ^turn_id)
    |> Ash.Query.ensure_selected([:org_id])
    |> Ash.Query.limit(1)
    |> Ash.read(authorize?: false)
    |> case do
      {:ok, [turn]} -> {:ok, turn}
      _ -> {:error, :turn_not_found}
    end
  rescue
    _ -> {:error, :turn_not_found}
  end

  defp fetch_turn(_turn_id), do: {:error, :turn_not_found}

  defp cancel_parked(%Run{} = run) do
    run = reload!(run)
    _ = withdraw_pending_approval(run)

    run =
      run
      |> Ash.Changeset.for_update(:request_cancel, %{})
      |> Ash.update!(authorize?: false)

    run =
      run
      |> Ash.Changeset.for_update(:cancel, %{})
      |> Ash.update!(authorize?: false)

    log_terminal(run)
    {:ok, run}
  end

  defp withdraw_pending_approval(%Run{} = run) do
    with {:ok, {_goal, _lines, pending}} <- transcript_state(run),
         true <- is_map(pending),
         approval_id when is_binary(approval_id) <- Map.get(pending, "approval_id") do
      Samen.Approvals.cancel(approval_id, WriteProposal.requester_principal_id())
    else
      _ -> :ok
    end
  end

  # ------------------------------------------------------------------------------------
  # The LIVE recursion guard (ADR-047 §5.1)

  @doc """
  The ambient agent provenance of the current process (`%{depth:, chain:}`), or `nil`
  outside any tool execution. Set around EVERY tool execution — the inline read path and
  the approved write path alike — so an action cannot start a nested agent run simply by
  omitting a `:depth` argument. Public so the guard's liveness is directly assertable.
  """
  @spec current_provenance() :: %{depth: non_neg_integer(), chain: [String.t()]} | nil
  def current_provenance do
    case Process.get(@provenance_key) do
      %{} = provenance -> provenance
      # A5 (the A4 verifier's R3): ORDINARY CONCURRENCY DOES NOT ESCAPE THE MARKER.
      # A process-dictionary marker is process-SCOPED, so a tool whose `run/2` did its
      # work in a `Task.async` (the most ordinary way an action does concurrent work)
      # called `Agent.start/4` from a child with an EMPTY dictionary: the guard fell
      # through to the caller-opts branch and persisted a fresh TOP-LEVEL run at
      # `depth: 0, chain: []` — so `max_agent_depth 0` never bound and even the depth
      # accounting could not see the nesting. The marker now follows the same
      # `$callers`/`$ancestors` chain the BEAM (and Ecto/Ash's own sandbox ownership,
      # and Task/Supervisor) already propagate for exactly this purpose. Sabotage 258
      # removes the walk and the named spawn-escape red flips.
      _ -> inherited_provenance()
    end
  end

  # Walk the spawn chain for an ambient marker. `$callers` is set by `Task.async`/
  # `Task.Supervisor` (transitively — a task of a task carries the whole chain);
  # `$ancestors` covers a bare `spawn_link`/GenServer start under a supervisor. Both
  # are read defensively: a dead pid, a registered-name atom that no longer resolves,
  # and a process that refuses inspection all contribute nothing.
  #
  # A RAW `spawn/1` sets neither list and therefore still escapes this walk — a NAMED,
  # DEFERRED residual whose sound closure is A7's static AST check, argued in full at
  # `@max_agent_depth` above (A6; the A5 verifier's R-A5-1, ADR-047 §10a row 19).
  defp inherited_provenance do
    (Process.get(:"$callers", []) ++ Process.get(:"$ancestors", []))
    |> Enum.find_value(&provenance_of/1)
  end

  defp provenance_of(pid) when is_pid(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dict} when is_list(dict) ->
        case List.keyfind(dict, @provenance_key, 0) do
          {_key, %{depth: d, chain: c}} when is_integer(d) and is_list(c) ->
            %{depth: d, chain: c}

          _ ->
            nil
        end

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp provenance_of(name) when is_atom(name) and not is_nil(name) do
    case Process.whereis(name) do
      pid when is_pid(pid) -> provenance_of(pid)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp provenance_of(_other), do: nil

  @doc "The v1 nesting ceiling (ADR-047 §5.1): agent runs above this depth are refused."
  @spec max_agent_depth() :: non_neg_integer()
  def max_agent_depth, do: @max_agent_depth

  defp with_tool_provenance(%Run{} = run, fun) do
    prior = Process.get(@provenance_key)
    Process.put(@provenance_key, %{depth: run.depth, chain: run.chain ++ [run.id]})

    try do
      fun.()
    after
      if is_nil(prior),
        do: Process.delete(@provenance_key),
        else: Process.put(@provenance_key, prior)
    end
  end

  # Resolve this run's `{depth, chain}` and refuse anything past the v1 ceiling. The
  # AMBIENT marker wins over caller opts: a tool that calls `run/4`/`start/4` with no
  # depth argument at all is still bounded. A repeated run id in the chain (a cycle) is
  # refused on its own, so the guard does not depend on depth accounting alone.
  defp resolve_provenance(opts) do
    {depth, chain} =
      case current_provenance() do
        %{depth: d, chain: c} when is_integer(d) and is_list(c) -> {d + 1, c}
        _ -> {Keyword.get(opts, :depth, 0), Keyword.get(opts, :chain, [])}
      end

    cond do
      not (is_integer(depth) and depth >= 0) -> {:error, :depth_exceeded}
      not (is_list(chain) and Enum.all?(chain, &is_binary/1)) -> {:error, :depth_exceeded}
      depth > @max_agent_depth -> {:error, :depth_exceeded}
      length(chain) > @max_agent_depth -> {:error, :depth_exceeded}
      length(Enum.uniq(chain)) != length(chain) -> {:error, :depth_exceeded}
      true -> {:ok, opts |> Keyword.put(:depth, depth) |> Keyword.put(:chain, chain)}
    end
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

    # A4 (§5.1): the ambient recursion marker is set around EVERY governed tool
    # execution — the inline read path and the approved write path alike — so an action
    # that tries to start a nested agent run is refused `:depth_exceeded` whether or not
    # it bothers to pass a `:depth` option.
    with_tool_provenance(run, fn ->
      case entry.module.run(normalized, ctx) do
        {:ok, meta} when is_map(meta) -> {:ok, meta}
        {:error, kind} when is_atom(kind) and not is_nil(kind) -> {:error, kind}
        _other -> {:error, :tool_failed}
      end
    end)
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
      |> maybe_put_hook_reason(Map.get(turn, :hook_reason))

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
          transcript: encode_transcript_finalizing(run, turn.goal, turn.lines ++ turn.new_lines),
          tool_calls_used: run.tool_calls_used + if(turn.executed?, do: 1, else: 0),
          input_tokens_used: run.input_tokens_used + in_tokens,
          output_tokens_used: run.output_tokens_used + out_tokens
        })
        |> Ash.update!(authorize?: false)
      end)

    run
  end

  # T181: a hook's block/halt reason on the bounded turn row. Already normalized by
  # `Samen.AI.Agent.Hooks.bounded_reason/1` (atom-or-binary, <= 64 bytes, `vt_`-free)
  # before it ever reaches here, and `bounded_meta/1` is the second gate.
  defp maybe_put_hook_reason(meta, nil), do: meta
  defp maybe_put_hook_reason(meta, reason), do: Map.put(meta, "hook_reason", reason)

  defp scope_actor(%Samen.Scope{actor: actor}) when is_map(actor), do: actor
  defp scope_actor(_scope), do: nil

  # The bounded role enum off a resolved scope (never a free term — §6).
  defp scope_role(%Samen.Scope{actor: %{role: role}}) when is_atom(role) and not is_nil(role),
    do: Atom.to_string(role)

  defp scope_role(_scope), do: "unknown"

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
  # ADR-048 §6 (C2): the SAME single reveal, returning the carried view state alongside
  # the history — the fold needs `folds` (UXD-17's prior-fold exclusion) and `turn_lens`
  # (whole-turns-only) at the top of every turn, and paying a second decrypt for them
  # would be a second read of the same envelope for no reason.
  defp transcript_with_views(%Run{transcript: %Samen.Masked{} = masked} = run) do
    with {:ok, json} <- Samen.Vault.reveal(masked, repo!(), subject_id: run.id),
         {:ok, {goal, _lines, _pending}} <- decode_transcript(json) do
      views = decode_views(json)
      # §4 non-negotiable 3: the loop threads `llm_view` and ONLY `llm_view`. Taking the
      # history from the same map the fold reasons over is what keeps the fold's segment
      # arithmetic and the sealed payload describing the same list.
      {:ok, {goal, views.llm_view, views}}
    else
      _ -> {:error, :transcript_unavailable}
    end
  end

  defp transcript_with_views(%Run{}), do: {:error, :transcript_unavailable}

  # A4: the same single reveal, returning the PENDING write proposal alongside the
  # history. The proposal's ARGS are the one place a write's argument VALUES are ever
  # persisted, and they live here — inside the DEK envelope, keyed on the run's own id,
  # reached by the run's own 90-day `:shred` retention (§7.4). The approval row and the
  # turn row stay token-only.
  defp transcript_state(%Run{} = run) do
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
      {:ok, %{"goal" => goal, "lines" => lines} = decoded}
      when is_binary(goal) and is_list(lines) ->
        if Enum.all?(lines, &is_binary/1) do
          {:ok, {goal, lines, Map.get(decoded, "pending")}}
        else
          {:error, :transcript_unavailable}
        end

      _ ->
        {:error, :transcript_unavailable}
    end
  end

  @doc """
  ADR-048 §4 (T217) — READER-SIDE-ONLY migration. Returns the run's `ui_view` and
  `llm_view` from the same sealed blob `transcript_state/1` reads. No backfill and
  no sealed-byte rewrite ever runs: a blob written before this change carries only
  the legacy `lines` key, so both views fall back to `lines` when their own key is
  absent. A blob written by the current `encode_transcript/2,3` already carries
  both keys explicitly and this simply passes them through unchanged.
  """
  @spec transcript_views(Ash.Resource.record()) ::
          {:ok, %{goal: String.t(), ui_view: [String.t()], llm_view: [String.t()]}}
          | {:error, term()}
  def transcript_views(%Run{} = run) do
    case run.transcript do
      %Samen.Masked{} = masked ->
        case Samen.Vault.reveal(masked, repo!(), subject_id: run.id) do
          {:ok, json} -> decode_transcript_views(json)
          {:error, _reason} -> {:error, :transcript_unavailable}
        end

      _ ->
        {:error, :transcript_unavailable}
    end
  end

  defp decode_transcript_views(json) do
    case Jason.decode(json) do
      {:ok, %{"goal" => goal, "lines" => lines} = decoded}
      when is_binary(goal) and is_list(lines) ->
        if Enum.all?(lines, &is_binary/1) do
          {:ok,
           %{
             goal: goal,
             ui_view: Map.get(decoded, "ui_view", lines),
             llm_view: Map.get(decoded, "llm_view", lines)
           }}
        else
          {:error, :transcript_unavailable}
        end

      _ ->
        {:error, :transcript_unavailable}
    end
  end

  # ADR-048 §4 (D2, T217) + §6 (T218/C2): ONE JSON blob, sealed under the run's single
  # DEK — never two tables with two retention specs. `ui_view` is APPEND-ONLY (exactly
  # what the tenant saw); `llm_view` is the loop's compactable working set (`lines` is its
  # legacy alias and stays byte-identical to it); `folds` is the compaction ledger;
  # `turn_lens` is `llm_view`'s per-turn line count, which is what makes §6's WHOLE TURNS
  # ONLY rule decidable — a turn can append more than one line (a tool call and its
  # result) and a fold that split one would put a call in the ledger without its result.
  #
  # Every write carries the prior blob's `ui_view`, `folds` and boundaries FORWARD. Only
  # the Level 1 fold diverges the two views, and a later turn's write must not silently
  # re-flatten them — that would delete what the tenant was shown, which is the
  # audit-integrity regression §4 exists to prevent.
  defp encode_transcript(run, goal, lines), do: encode_transcript(run, goal, lines, :none)

  defp encode_transcript(run, goal, lines, pending) do
    {ui_view, turn_lens, folds} = carried_for_write(run, lines)
    encode_views(goal, lines, ui_view, folds, turn_lens, pending)
  end

  # ADR-048 §6 / ruling UXD-18 CHECKPOINT 2. Identical to `encode_transcript/3-4` except
  # that it finalizes every `:proposed` fold-ledger entry to `"done"`. Call it ONLY from
  # inside a transaction that also advances the run cursor — that co-location IS the
  # ruling: the fold entry and the cursor move together or neither moves, so no crash
  # window can leave a finalized fold at an un-advanced cursor (the mirror of
  # `commit_turn!`'s single-transaction rule for turn ROWS).
  defp encode_transcript_finalizing(run, goal, lines, pending \\ :none) do
    {ui_view, turn_lens, folds} = carried_for_write(run, lines)
    encode_views(goal, lines, ui_view, finalize_folds(folds), turn_lens, pending)
  end

  defp finalize_folds(folds) when is_list(folds) do
    Enum.map(folds, fn
      %{"status" => "proposed"} = entry -> Map.put(entry, "status", "done")
      entry -> entry
    end)
  end

  defp finalize_folds(folds), do: folds

  defp carried_for_write(run, lines) do
    prior = carried_views(run)

    {ui_view, turn_lens} =
      cond do
        not List.starts_with?(lines, prior.llm_view) ->
          # Not a suffix append — only reachable if a caller threaded a `lines` that did
          # not come from this run's own current blob. Degrade to the pre-C2 shape rather
          # than invent a UI history.
          {lines, List.duplicate(1, length(lines))}

        length(lines) == length(prior.llm_view) ->
          {prior.ui_view, prior.turn_lens}

        true ->
          appended = Enum.drop(lines, length(prior.llm_view))
          {prior.ui_view ++ appended, prior.turn_lens ++ [length(appended)]}
      end

    {ui_view, turn_lens, prior.folds}
  end

  defp encode_views(goal, lines, ui_view, folds, turn_lens, pending) do
    base = %{
      "goal" => goal,
      "lines" => lines,
      "ui_view" => ui_view,
      "llm_view" => lines,
      "folds" => folds,
      "turn_lens" => turn_lens
    }

    Jason.encode!(if pending in [:none, nil], do: base, else: Map.put(base, "pending", pending))
  end

  # The carried view state, read through the SAME single decrypt chokepoint
  # `transcript_state/1` uses. A run with no transcript yet (create) or an unreadable one
  # degrades to the empty carry — never to a fabricated history.
  defp carried_views(nil), do: empty_views()

  defp carried_views(%Run{transcript: %Samen.Masked{} = masked} = run),
    do: reveal_views(masked, run.id)

  # A vault-routed attribute is NOT handed back on the record an `:advance` writes — the
  # plaintext must never ride home on the struct — so a run THIS process just wrote
  # carries `%Ash.NotLoaded{}` here. Re-read that one row rather than degrade: silently
  # dropping the carry would erase the fold ledger and the append-only `ui_view` on the
  # very next write, which is exactly the deletion §4 forbids. The common path (a run
  # read at the top of a turn) is already `%Samen.Masked{}` and never reaches here.
  defp carried_views(%Run{id: id}) when is_binary(id) do
    require Ash.Query

    Run
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.ensure_selected([:transcript])
    |> Ash.Query.limit(1)
    |> Ash.read!(authorize?: false)
    |> case do
      [%Run{transcript: %Samen.Masked{} = masked}] -> reveal_views(masked, id)
      _ -> empty_views()
    end
  end

  defp carried_views(_run), do: empty_views()

  defp reveal_views(masked, subject_id) do
    case Samen.Vault.reveal(masked, repo!(), subject_id: subject_id) do
      {:ok, json} -> decode_views(json)
      {:error, _reason} -> empty_views()
    end
  end

  defp decode_views(json) do
    case Jason.decode(json) do
      {:ok, %{"lines" => lines} = decoded} when is_list(lines) ->
        if Enum.all?(lines, &is_binary/1) do
          llm = Map.get(decoded, "llm_view", lines)

          %{
            llm_view: llm,
            ui_view: Map.get(decoded, "ui_view", lines),
            folds: Map.get(decoded, "folds", []),
            turn_lens: carried_turn_lens(Map.get(decoded, "turn_lens"), llm),
            pending: Map.get(decoded, "pending")
          }
        else
          empty_views()
        end

      _ ->
        empty_views()
    end
  end

  defp empty_views,
    do: %{llm_view: [], ui_view: [], folds: [], turn_lens: [], pending: nil}

  # A blob written before C2 records no turn boundaries. The honest reader-side default is
  # one line per turn: it never CLAIMS a boundary that was not recorded, and every turn
  # this build itself wrote carries its real one.
  defp carried_turn_lens(lens, llm) when is_list(lens) do
    if Enum.all?(lens, &is_integer/1) and Enum.sum(lens) == length(llm),
      do: lens,
      else: List.duplicate(1, length(llm))
  end

  defp carried_turn_lens(_lens, llm), do: List.duplicate(1, length(llm))

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
            # A4 (§5.1): the resolved loop provenance (`resolve_provenance/1` refused
            # anything past the v1 ceiling before we got here), not a hardcoded 0/[].
            depth: Keyword.get(opts, :depth, 0),
            chain: Keyword.get(opts, :chain, []),
            # UXD-08 (T21-verdict.json): persist the per-run :hooks opt on the row so the
            # durable TurnWorker can re-resolve it at execution time (worker_opts/1) —
            # Oban job args stay token-only (ADR-037 §5.9), so the row is the only
            # durability path for this. Shared by run/4 AND start/4 (both funnel through
            # this one function), so both modes now agree on what they persisted.
            hooks: opts |> Keyword.get(:hooks) |> List.wrap() |> Enum.map(&Atom.to_string/1),
            transcript: encode_transcript(nil, goal, []),
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
