defmodule Demo.Repo.Migrations.BreakGlass do
  @moduledoc """
  T4.4 break-glass + breadth-budget kernel tables (demo mirror of the samen_core
  test_repo migration). See `Samen.BreakGlass`, `Samen.BreakGlass.Budget`, and
  `Samen.OperatorPlane.Suspension`. Token-only; not catalogued (mirrors the
  `imp_`/`rvg_` operator-plane kernel precedent).
  """
  use Ecto.Migration

  def up do
    create table(:osp_operator_suspension, primary_key: false) do
      add(:osp_id, :uuid, primary_key: true, null: false, default: fragment("gen_random_uuid()"))
      add(:osp_operator_id, :string, null: false)
      add(:osp_reason, :text, null: false)
      add(:osp_suspended_at, :utc_datetime_usec, null: false)
      add(:osp_cleared_at, :utc_datetime_usec)

      timestamps(
        type: :utc_datetime_usec,
        inserted_at: :osp_inserted_at,
        updated_at: :osp_updated_at
      )
    end

    create(
      unique_index(:osp_operator_suspension, [:osp_operator_id],
        where: "osp_cleared_at IS NULL",
        name: :osp_one_active_per_operator
      )
    )

    create table(:brl_reveal_ledger, primary_key: false) do
      add(:brl_id, :uuid, primary_key: true, null: false, default: fragment("gen_random_uuid()"))
      add(:brl_operator_id, :string, null: false)
      add(:brl_subject_id, :string, null: false)
      add(:brl_break_glass, :boolean, null: false, default: false)
      add(:brl_revealed_at, :utc_datetime_usec, null: false)
    end

    create(index(:brl_reveal_ledger, [:brl_operator_id, :brl_revealed_at]))

    create table(:brc_break_glass_anchor, primary_key: false) do
      add(:brc_id, :uuid, primary_key: true, null: false, default: fragment("gen_random_uuid()"))
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
