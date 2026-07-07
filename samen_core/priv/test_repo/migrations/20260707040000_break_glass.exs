defmodule SamenCore.TestRepo.Migrations.BreakGlass do
  @moduledoc """
  T4.4 break-glass + breadth-budget kernel tables. Three abbrev-prefixed tables, all
  token-only (operator ids, subject tokens, bounded metadata — never plaintext PII).

  Follows the `imp_`/`rvg_` reveal/impersonation precedent: these are operator-plane
  kernel infra backed by plain `Ecto.Schema`s consulted by the deny paths, NOT Ash
  resources, and NOT catalogued (like `imp_impersonation_session` and `rvg_reveal_grant`).

    * `osp_operator_suspension` — the per-operator auto-suspend flag (clause (d)). A
      non-cleared row = suspended; every reveal path (routine, impersonation,
      break-glass) denies while a row is active. `clear/2` sets `osp_cleared_at`.
    * `brl_reveal_ledger` — the durable, cross-path reveal ledger the breadth budget
      counts (clause (d)). One row per (operator, subject, time); DISTINCT subjects in
      the window is the breadth. `brl_break_glass` marks which path spent it.
    * `brc_break_glass_anchor` — tracks which local break-glass entries have been
      anchored into the central T4.3 chain (clause (b)), keyed by the local entry's
      content hash (UNIQUE) so reconciliation is idempotent.
  """
  use Ecto.Migration

  def up do
    # (1) Operator auto-suspend flag (clause (d)).
    create table(:osp_operator_suspension, primary_key: false) do
      add(:osp_id, :uuid, primary_key: true, null: false, default: fragment("gen_random_uuid()"))
      add(:osp_operator_id, :string, null: false)
      add(:osp_reason, :text, null: false)
      add(:osp_suspended_at, :utc_datetime_usec, null: false)
      # NULL while active; set by clear/2 when the operator is re-enabled.
      add(:osp_cleared_at, :utc_datetime_usec)

      timestamps(
        type: :utc_datetime_usec,
        inserted_at: :osp_inserted_at,
        updated_at: :osp_updated_at
      )
    end

    # The active-suspension lookup (the hot deny-path check): one active row per
    # operator. A partial UNIQUE index enforces "at most one active suspension".
    create(
      unique_index(:osp_operator_suspension, [:osp_operator_id],
        where: "osp_cleared_at IS NULL",
        name: :osp_one_active_per_operator
      )
    )

    # (2) The breadth-budget reveal ledger (clause (d)).
    create table(:brl_reveal_ledger, primary_key: false) do
      add(:brl_id, :uuid, primary_key: true, null: false, default: fragment("gen_random_uuid()"))
      add(:brl_operator_id, :string, null: false)
      add(:brl_subject_id, :string, null: false)
      add(:brl_break_glass, :boolean, null: false, default: false)
      add(:brl_revealed_at, :utc_datetime_usec, null: false)
    end

    # The breadth count query: DISTINCT subjects for an operator within a window.
    create(index(:brl_reveal_ledger, [:brl_operator_id, :brl_revealed_at]))

    # (3) The break-glass anchor-tracking table (clause (b)).
    create table(:brc_break_glass_anchor, primary_key: false) do
      add(:brc_id, :uuid, primary_key: true, null: false, default: fragment("gen_random_uuid()"))
      # The local entry's content hash — the idempotency key. UNIQUE so a re-run
      # never double-anchors a local entry into the central chain.
      add(:brc_local_hash, :string, null: false)
      add(:brc_local_seq, :bigint, null: false)
      add(:brc_org_id, :string, null: false)
      add(:brc_subject_id, :string)
      add(:brc_actor_id, :string)
      add(:brc_correlation_id, :string)
      add(:brc_anchored_at, :utc_datetime_usec, null: false)
    end

    create(unique_index(:brc_break_glass_anchor, [:brc_local_hash]))
  end

  def down do
    drop(table(:brc_break_glass_anchor))
    drop(table(:brl_reveal_ledger))
    drop(table(:osp_operator_suspension))
  end
end
