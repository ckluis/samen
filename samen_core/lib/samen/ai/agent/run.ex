defmodule Samen.AI.Agent.Run do
  @moduledoc """
  `Samen.AI.Agent.Run` — the durable agent-run cursor (ADR-047 §4.1, batches A1+A2).

  One row per agent run: the AshStateMachine lifecycle (`queued → running →
  {succeeded, failed, cancelled, budget_exhausted}` — A4 adds `:awaiting_approval`), the
  turn cursor (`current_turn`), the resolved fail-honest budgets and their consumption
  counters, and the durable cancel flag (`cancel_requested_at`) `Samen.AI.Agent.cancel/2`
  sets and the loop re-checks at EVERY turn boundary (RP-AG-8).

  ## The vault-routed transcript (A2 — ADR-047 §7.4; operator decision §9#4 TAKEN)

  The ONE text artifact a run legitimately persists — the goal (tenant free text) plus
  the rendered assistant lines — lives in the vault-routed `:transcript` attribute
  (`pii do vault(:pii_transcript) … end`): plaintext never lands in the domain column
  (a `vt_*` token does — `Samen.Vault.Change` + `Samen.Type.VaultField`'s last-line
  refusal), the ciphertext sits INSIDE the DEK envelope keyed on the run row's OWN id
  (`Samen.Vault.Change.resolve_subject_id/1` — the framework's per-row crypto-shred
  unit), and subject-level reach is by retention: a default 90-day `:shred` retention
  spec is DERIVED framework-first (`Samen.Erasure.default_specs/1` → the
  `:retention_specs` registry) and asserted by `mix samen.verify.erasure_completeness`'s
  transcript arm. Every other run/turn column stays token-only (ADR-047 §6): ids, enums,
  counts, timestamps — no prompt/completion text outside the envelope, ever.

  ## Durability (A2 — the `Samen.Sequences` shape)

  `next_turn_at` is **never nil while the run is non-terminal** (the Sequences MED-2
  invariant): `:start` arms it at create, every `:advance` re-arms the in-flight
  watchdog window, and only the terminal transitions clear it — exactly once. The
  AshOban `:agent_turn_due` trigger (queue `:automation_timers`, explicit
  `scheduler_cron`, pinned module names so `mix samen.verify.oban_queues` sees both
  generated modules) re-selects any run whose watchdog window elapsed — a crashed
  worker, a lost enqueue, a silently-discarded job — and `:resume_due` re-enqueues
  `Samen.AI.Agent.TurnWorker` INSIDE its own action transaction (the `EventCapture` /
  Sequences `:advance_due` idiom). Writes go through the kernel only
  (`Samen.AI.Agent`); tenant reads are org-scoped through `Samen.Policy.OrgScope`
  (RP-AG-10).
  """
  use Samen.Resource,
    otp_app: :samen_core,
    domain: Samen.AI.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshStateMachine, AshOban],
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
      transition(:fail, from: [:queued, :running], to: :failed)
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

    # A2: the agent definition MODULE, so the Oban worker can re-resolve `definition/0`
    # across a restart (validated on resolve: must exist, export definition/0, and its
    # name must equal `:agent` — anything else is a fail-honest `:agent_unresolvable`).
    attribute(:agent_module, :string, public?: true)

    # A2: the initiating member's id — the owner actor the worker re-resolves at turn
    # time (the Automation.RunWorker owner-resolution rule: a missing owner is
    # `:owner_unavailable`, never a silent re-attribution).
    attribute(:owner_id, :string, public?: true)

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

    # The A2 watchdog cursor — NEVER nil while non-terminal (the Samen.Sequences MED-2
    # invariant: a nil cursor is unselectable by the due-scan `where` clause and produces
    # a permanent silent stall). Armed at :start, re-armed per :advance, cleared exactly
    # once by the terminal transitions.
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

  # A2 (ADR-047 §7.4, §9#2/#4 TAKEN): the run's ONE persisted text artifact — the goal +
  # rendered transcript lines, JSON-encoded — vault-routed inside the DEK envelope keyed
  # on this row's own id. The domain column only ever holds a `vt_*` token; reads present
  # `%Samen.Masked{}`; the loop reveals through the single `Samen.Vault.reveal/3`
  # chokepoint bound to `subject_id: run.id` (the Samen.Identity.Totp precedent).
  pii do
    vault(:pii_transcript)
    pii_attribute(:transcript, :string, vault: :pii_transcript)
    reveal(:reveal_agent_run)
  end

  actions do
    defaults([:read])

    create :start do
      description(
        "Open an agent run cursor (:queued) with its resolved budgets, the seeded " <>
          "vault-routed transcript, and an ARMED next_turn_at watchdog. Kernel-only."
      )

      accept([
        :org_id,
        :agent,
        :agent_module,
        :owner_id,
        :origin,
        :depth,
        :chain,
        :transcript,
        :next_turn_at,
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

    # Per-turn cursor/counter/transcript advance (kernel-only, between turns). The
    # transcript plaintext handed here is vault-routed by Samen.Vault.Change before
    # the row is written — the column receives a token, never text.
    update :advance do
      accept([
        :current_turn,
        :next_turn_at,
        :transcript,
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

    # Internal cross-org system read used ONLY by the AshOban :agent_turn_due scheduler
    # (bypass-authorized below) — each due row resumes under its OWN org, never
    # cross-plane.
    read :due_scan do
      pagination(keyset?: true, required?: false)
    end

    # System maintenance action driven by the :agent_turn_due AshOban trigger (A2's
    # watchdog): re-arm the in-flight window and re-enqueue the TurnWorker INSIDE this
    # action's transaction (the EventCapture / Sequences :advance_due idiom — the job
    # exists iff the re-arm committed). The trigger's `where` clause selects only due,
    # non-terminal runs; the changeset filter is the defensive double-check.
    update :resume_due do
      accept([])
      require_atomic?(false)

      change(fn changeset, _ctx ->
        changeset
        |> Ash.Changeset.filter({:state, [in: [:queued, :running]]})
        |> Ash.Changeset.force_change_attribute(
          :next_turn_at,
          DateTime.add(DateTime.utc_now(), Samen.AI.Agent.inflight_watchdog_seconds())
        )
        |> Ash.Changeset.after_action(fn _changeset, result ->
          Samen.AI.Agent.TurnWorker.enqueue(result.id)
          {:ok, result}
        end)
      end)
    end

    action :reveal_agent_run, :map do
      argument(:actor_id, :string, allow_nil?: false)
      argument(:subject_id, :string, allow_nil?: false)

      run(fn input, _ctx ->
        ctx = %Samen.Reveal.Context{
          actor: input.arguments.actor_id,
          subject_id: input.arguments.subject_id,
          resource: __MODULE__,
          action: :reveal_agent_run,
          label: :transcript
        }

        if Samen.Reveal.grant_checker().granted?(ctx) do
          {:ok, %{status: "granted", subject_id: input.arguments.subject_id}}
        else
          {:error, :denied}
        end
      end)
    end
  end

  oban do
    triggers do
      trigger :agent_turn_due do
        action(:resume_due)
        queue(:automation_timers)
        scheduler_cron("* * * * *")
        scheduler_module_name(Samen.AI.Agent.Run.AgentTurnDueScheduler)
        worker_module_name(Samen.AI.Agent.Run.AgentTurnDueWorker)
        read_action(:due_scan)
        worker_read_action(:due_scan)
        stream_with(:full_read)
        actor_persister(:none)
        max_attempts(3)

        # The never-nil invariant makes this selector complete: every non-terminal run
        # HAS a next_turn_at, so a stalled run is always eventually due — there is no
        # unselectable in-flight state (the Sequences MED-2 lesson, adopted verbatim).
        where(
          expr(
            ^ref(:state) in [:queued, :running] and not is_nil(^ref(:next_turn_at)) and
              ^ref(:next_turn_at) <= now()
          )
        )
      end
    end
  end

  policies do
    bypass action([:resume_due, :due_scan]) do
      authorize_if(always())
    end

    policy action(:reveal_agent_run) do
      authorize_if(always())
    end

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
