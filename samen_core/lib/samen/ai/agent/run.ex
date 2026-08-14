defmodule Samen.AI.Agent.Run do
  @moduledoc """
  `Samen.AI.Agent.Run` — the durable agent-run cursor (ADR-047 §4.1, batch A1).

  One row per agent run: the AshStateMachine lifecycle (`queued → running →
  {succeeded, failed, cancelled, budget_exhausted}` — A4 adds `:awaiting_approval`), the
  turn cursor (`current_turn`), the resolved fail-honest budgets and their consumption
  counters, and the durable cancel flag (`cancel_requested_at`) `Samen.AI.Agent.cancel/2`
  sets and the loop re-checks at EVERY turn boundary (RP-AG-8).

  ## Token-only at rest (ADR-047 §6 — deliberate, load-bearing)

  This row carries **no prompt text, no completion text, no tool arg values, no result
  text, ever** — ids, enums, counts, and timestamps only. The rendered transcript (the
  one text artifact a run legitimately persists) is A2's **vault-routed** `:transcript`
  attribute inside the DEK envelope (ADR-047 §7.4); in A1 the accumulated history lives
  only in the executing process. That is what makes "no plaintext in any persisted
  artifact" an asserted property of this batch, not a hope.

  ## A1 scope honesty

  A1 executes runs synchronously in the calling process (`Samen.AI.Agent.run/4`); the
  row is already the durable cursor shape A2's Oban worker + never-nil `next_turn_at`
  watchdog resume from (`next_turn_at` is set while the run is live and cleared exactly
  once at the terminal transition — the `Samen.Sequences` invariant, adopted in A2).
  Writes go through the kernel only (`Samen.AI.Agent` — a trusted kernel API, the
  `Samen.Approvals` engine precedent); tenant reads are org-scoped through
  `Samen.Policy.OrgScope` like every other read (RP-AG-10).
  """
  use Samen.Resource,
    otp_app: :samen_core,
    domain: Samen.AI.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshStateMachine],
    abbrev: "arn"

  postgres do
    table("ai_agent_run")
    repo(Application.compile_env(:samen_core, :samen_ai_agent_run_repo, SamenCore.TestRepo))
  end

  state_machine do
    initial_states([:queued])
    default_initial_state(:queued)

    transitions do
      transition(:begin, from: :queued, to: :running)
      transition(:succeed, from: :running, to: :succeeded)
      transition(:fail, from: :running, to: :failed)
      # Exhaustion is its OWN honest terminal state (never dressed as :succeeded — §6).
      transition(:exhaust, from: :running, to: :budget_exhausted)
      # A cancel can land before the first turn ever runs (queued) or between turns.
      transition(:cancel, from: [:queued, :running], to: :cancelled)
    end
  end

  attributes do
    # The agent definition's validated name (`Samen.AI.Agent` `use` macro) — a bounded,
    # authored identifier, never tenant data.
    attribute(:agent, :string, public?: true, allow_nil?: false)

    # Pre-declare the AshStateMachine state attribute so AbbrevStorage prefixes its
    # physical column (the Samen.Approvals.Blueprint precedent).
    attribute(:state, :atom,
      allow_nil?: false,
      default: :queued,
      public?: true,
      writable?: false,
      constraints: [one_of: [:queued, :running, :succeeded, :failed, :cancelled, :budget_exhausted]]
    )

    # The turn cursor: how many turns have completed (the checkpoint A2's worker resumes at).
    attribute(:current_turn, :integer, public?: true, allow_nil?: false, default: 0)

    # The A2 watchdog cursor (never nil while non-terminal, ONCE the Oban worker exists;
    # A1 sets it while a run is live and clears it exactly once at the terminal write).
    attribute(:next_turn_at, :utc_datetime_usec, public?: true)

    attribute(:started_at, :utc_datetime_usec, public?: true)

    # The durable cancel flag (RP-AG-8): set by `Samen.AI.Agent.cancel/2`, re-checked by
    # the loop at EVERY turn boundary — never only at run start (sabotage 241's target).
    attribute(:cancel_requested_at, :utc_datetime_usec, public?: true)

    # Bounded terminal error kind (closed enum, `Samen.AI.Agent.safe_error_kind/1`-degraded —
    # the RunRecord.bounded_outcomes posture): never a freeform message, never an inspect.
    attribute(:error_kind, :string, public?: true)

    # The run's RESOLVED fail-honest budgets (ADR-047 §6, §9#3 TAKEN) — recorded on the row
    # so enforcement is auditable against exactly what this run was allowed.
    attribute(:max_turns, :integer, public?: true, allow_nil?: false)
    attribute(:max_tool_calls, :integer, public?: true, allow_nil?: false)
    attribute(:max_input_tokens, :integer, public?: true, allow_nil?: false)
    attribute(:max_output_tokens, :integer, public?: true, allow_nil?: false)
    attribute(:deadline_seconds, :integer, public?: true, allow_nil?: false)

    # Consumption counters (summed from `%Samen.AI.Completion{}.usage` per turn).
    attribute(:tool_calls_used, :integer, public?: true, allow_nil?: false, default: 0)
    attribute(:input_tokens_used, :integer, public?: true, allow_nil?: false, default: 0)
    attribute(:output_tokens_used, :integer, public?: true, allow_nil?: false, default: 0)

    # Loop provenance (the Automation.Context idiom, ADR-047 §5.1 recursion guard):
    # `origin` is a bounded ref string ("user:<id>" | "workflow:<id>" | "agent:<run_id>").
    attribute(:origin, :string, public?: true)
    attribute(:depth, :integer, public?: true, allow_nil?: false, default: 0)
    attribute(:chain, {:array, :string}, public?: true, allow_nil?: false, default: [])
  end

  actions do
    defaults([:read])

    create :start do
      description("Open an agent run cursor (:queued) with its resolved budgets. Kernel-only.")

      accept([
        :org_id,
        :agent,
        :origin,
        :depth,
        :chain,
        :max_turns,
        :max_tool_calls,
        :max_input_tokens,
        :max_output_tokens,
        :deadline_seconds
      ])
    end

    update :begin do
      accept([:started_at, :next_turn_at])
      require_atomic?(false)
      change(transition_state(:running))
    end

    # Per-turn cursor/counter advance (kernel-only, between turns).
    update :advance do
      accept([
        :current_turn,
        :next_turn_at,
        :tool_calls_used,
        :input_tokens_used,
        :output_tokens_used
      ])

      require_atomic?(false)
    end

    # The durable cancel flag — deliberately NOT a state transition: the RUNNING loop owns
    # the state machine and honors the flag at its next turn boundary ("stopping after the
    # current step", never "stopped" — ADR-047 §11).
    update :request_cancel do
      accept([])
      require_atomic?(false)
      change(set_attribute(:cancel_requested_at, &DateTime.utc_now/0))
    end

    update :succeed do
      accept([])
      require_atomic?(false)
      change(set_attribute(:next_turn_at, nil))
      change(transition_state(:succeeded))
    end

    update :fail do
      accept([:error_kind])
      require_atomic?(false)
      change(set_attribute(:next_turn_at, nil))
      change(transition_state(:failed))
    end

    # Budget exhaustion: an EXPLICIT honest terminal state with a bounded error_kind —
    # NEVER a silent truncation, NEVER a promotion of the last turn to a result (§6).
    update :exhaust do
      accept([:error_kind])
      require_atomic?(false)
      change(set_attribute(:next_turn_at, nil))
      change(transition_state(:budget_exhausted))
    end

    update :cancel do
      accept([])
      require_atomic?(false)
      change(set_attribute(:next_turn_at, nil))
      change(set_attribute(:error_kind, "cancelled"))
      change(transition_state(:cancelled))
    end
  end

  policies do
    # Tenant reads are org-scoped (fail-closed FilterCheck — a foreign org's runs do not
    # exist for this scope, RP-AG-10).
    policy action_type(:read) do
      authorize_if(Samen.Policy.OrgScope)
    end

    # Writes are kernel-driven (`Samen.AI.Agent`, the Approvals-engine trusted-API
    # precedent) — the loop is the only author; there is no tenant-facing write surface.
    policy action_type([:create, :update, :destroy]) do
      authorize_if(always())
    end
  end
end
