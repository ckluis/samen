defmodule Samen.AI.Agent.Turn do
  @moduledoc """
  `Samen.AI.Agent.Turn` — the bounded per-turn log row (ADR-047 §6, batch A1).

  One row per executed turn, keyed `{run_id, turn_index}` — the identity that becomes
  A2's crash-replay idempotency key (`Samen.Sequences.find_or_create_step_send/2`'s
  row-reuse shape; a replayed turn finds its existing row and does NOT re-execute,
  RP-AG-7).

  ## Token-only, by allowlist (the E4 / `RunRecord.bounded_outcomes/1` pattern)

  Exactly the ADR-047 §6 field set: `turn_index`, `tool_kind`, **arg key NAMES only**
  (`arg_keys` — never values), `status`, `error_kind` (closed enum, degraded — never
  rejected — via `Samen.AI.Agent.safe_error_kind/1`), `input_tokens`, `output_tokens`,
  `duration_ms`, `provider`, `simulated`. **No prompt text, no tool arg values, no
  result text, ever** — a Completion's `:text` never touches this row (asserted
  directly by the A1 no-text-at-rest test, not inferred).

  A1 is tool-free, so `tool_kind`/`arg_keys` are written empty; the columns exist
  because they are the §6 contract of the turn log itself (A3 fills them). `:proposed`
  is the A2 decision-checkpoint status (committed before a tool fires); A1 writes
  `:done` / `:failed` only.
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
  end

  identities do
    # THE idempotency key (ADR-047 §4.1): a second write for the same {run, turn} is a
    # DB-level conflict — A2's replay executor reuses the row instead of re-firing.
    identity(:run_turn, [:run_id, :turn_index])
  end

  actions do
    defaults([:read])

    create :record do
      description("Record one executed turn's bounded, token-only log row. Kernel-only.")

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
        :simulated
      ])
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
