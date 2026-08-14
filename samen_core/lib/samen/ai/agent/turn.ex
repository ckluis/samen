defmodule Samen.AI.Agent.Turn do
  @moduledoc """
  `Samen.AI.Agent.Turn` — the bounded per-turn log row (ADR-047 §6, batches A1+A2).

  One row per executed turn, keyed `{run_id, turn_index}` — the identity that is A2's
  crash-replay idempotency key (`Samen.Sequences.find_or_create_step_send/2`'s
  row-reuse shape, RP-AG-7). A2 makes it load-bearing: the executor writes this row
  `:proposed` as the DECISION checkpoint **before** the slow provider call, and a
  replay of turn N (worker death, watchdog re-select) FINDS and REUSES that row —
  `Samen.AI.Agent`'s `find_or_reuse_turn!/3` — instead of creating a duplicate (the
  unique index refuses one structurally). The outcome checkpoint (`:finalize`) then
  commits atomically with the run-cursor advance, so a `:done` row always agrees with
  the cursor. Posture stated as Sequences states it: **at-least-once, never claimed
  exactly-once** — the provider call between the two checkpoints can genuinely repeat;
  the turn ROW (and, from A3, the tool execution keyed on it) does not.

  ## Token-only, by allowlist (the E4 / `RunRecord.bounded_outcomes/1` pattern)

  Exactly the ADR-047 §6 field set: `turn_index`, `tool_kind`, **arg key NAMES only**
  (`arg_keys` — never values), `status`, `error_kind` (closed enum, degraded — never
  rejected — via `Samen.AI.Agent.safe_error_kind/1`), `input_tokens`, `output_tokens`,
  `duration_ms`, `provider`, `simulated`, plus A2's **bounded `meta` map** (replay
  provenance — filtered through `Samen.AI.Agent.bounded_meta/1`, the
  `RunRecord.bounded_outcomes/1` posture: plain string-keyed scalars only, anything
  struct-shaped or rich degrades to `%{}`, never an `inspect`). **No prompt text, no
  tool arg values, no result text, ever** — `Samen.AgentCase.assert_no_text_at_rest!/2`
  scans every attribute INCLUDING map values (`Samen.AgentCase.leaks?/2`).
  """
  use Samen.Resource,
    otp_app: :samen_core,
    domain: Samen.AI.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "atn"

  postgres do
    table("ai_agent_turn")
    repo(Application.compile_env(:samen_core, :samen_ai_agent_turn_repo, SamenCore.TestRepo))
  end

  attributes do
    attribute(:run_id, :uuid, public?: true, allow_nil?: false)
    attribute(:turn_index, :integer, public?: true, allow_nil?: false)

    attribute(:status, :atom,
      public?: true,
      allow_nil?: false,
      constraints: [one_of: [:proposed, :done, :failed]]
    )

    # A3: the chosen tool's registry kind (a bounded registry atom rendered to string).
    attribute(:tool_kind, :string, public?: true)

    # A3: the model-emitted tool-arg KEY NAMES only — never a value (ADR-047 §6).
    attribute(:arg_keys, {:array, :string}, public?: true, allow_nil?: false, default: [])

    attribute(:error_kind, :string, public?: true)

    attribute(:input_tokens, :integer, public?: true, allow_nil?: false, default: 0)
    attribute(:output_tokens, :integer, public?: true, allow_nil?: false, default: 0)
    attribute(:duration_ms, :integer, public?: true, allow_nil?: false, default: 0)

    # The dispatched provider, as a bounded identifier (`%Completion{}.provider`, e.g.
    # "scripted") — never payload content.
    attribute(:provider, :string, public?: true)

    # Honesty provenance (T152): stamped from `%Completion{}.simulated` — by construction
    # at the chokepoint's dispatch site, never parsed from text.
    attribute(:simulated, :boolean, public?: true, allow_nil?: false, default: false)

    # A2: bounded replay/outcome provenance (e.g. %{"replayed" => true}). Every write
    # passes `Samen.AI.Agent.bounded_meta/1` (default-deny: plain string-keyed scalars
    # only) — a struct/exception/rich term can never be inspect-ed into this jsonb.
    attribute(:meta, :map, public?: true, allow_nil?: false, default: %{})
  end

  identities do
    # THE idempotency key (ADR-047 §4.1): a second row for the same {run, turn} is a
    # DB-level conflict — the A2 replay executor reuses the row instead of re-firing.
    identity(:run_turn, [:run_id, :turn_index])
  end

  actions do
    defaults([:read])

    create :record do
      description(
        "Record one turn's bounded, token-only log row (A2: the :proposed DECISION " <>
          "checkpoint, committed before the slow provider call). Kernel-only."
      )

      accept([
        :org_id,
        :run_id,
        :turn_index,
        :status,
        :tool_kind,
        :arg_keys,
        :error_kind,
        :input_tokens,
        :output_tokens,
        :duration_ms,
        :provider,
        :simulated,
        :meta
      ])
    end

    # A2: the OUTCOME checkpoint — finalize the (possibly replay-reused) :proposed row.
    # Kernel-only; committed in the SAME transaction as the run-cursor advance so a
    # :done row and the cursor can never disagree.
    update :finalize do
      accept([
        :status,
        :error_kind,
        :input_tokens,
        :output_tokens,
        :duration_ms,
        :provider,
        :simulated,
        :meta
      ])

      require_atomic?(false)
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if(Samen.Policy.OrgScope)
    end

    # Kernel-only writes (the Run resource's posture — see Samen.AI.Agent.Run).
    policy action_type([:create, :update, :destroy]) do
      authorize_if(always())
    end
  end
end
