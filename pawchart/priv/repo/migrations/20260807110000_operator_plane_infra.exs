defmodule PawChart.Repo.Migrations.OperatorPlaneInfra do
  @moduledoc """
  T157: the operator-plane KERNEL tables — masked-impersonation sessions (T4.1/T150) +
  break-glass / reveal-ledger / operator-suspension (T4.4) — mounted over PawChart so an
  operator can open a bounded, reason-required impersonation session against a clinic tenant.

  Mirrors `driftwood/priv/repo/migrations/20260707170000_operator_plane.exs` (the demo/samen_core
  precedent) exactly. Token-only; NOT catalogued (the `imp_`/`osp_`/`brl_`/`brc_` operator-plane
  kernel tables carry no domain PII and are intentionally outside the catalog-parity managed set).
  """
  use Ecto.Migration

  def up do
    # --- T4.1/T150 masked-impersonation session ---
    create table(:imp_impersonation_session, primary_key: false) do
      add(:imp_id, :uuid, primary_key: true, null: false, default: fragment("gen_random_uuid()"))
      add(:imp_operator_id, :string, null: false)
      add(:imp_org_id, :uuid, null: false)
      add(:imp_reason, :text, null: false)
      add(:imp_expires_at, :utc_datetime_usec, null: false)
      add(:imp_closed_at, :utc_datetime_usec)
      add(:imp_close_cause, :text)

      timestamps(type: :utc_datetime_usec, inserted_at: :imp_inserted_at, updated_at: :imp_updated_at)
    end

    create(index(:imp_impersonation_session, [:imp_org_id]))
    create(index(:imp_impersonation_session, [:imp_operator_id]))
    create(index(:imp_impersonation_session, [:imp_expires_at]))

    # --- T4.4 break-glass / suspension / breadth budget ---
    create table(:osp_operator_suspension, primary_key: false) do
      add(:osp_id, :uuid, primary_key: true, null: false, default: fragment("gen_random_uuid()"))
      add(:osp_operator_id, :string, null: false)
      add(:osp_reason, :text, null: false)
      add(:osp_suspended_at, :utc_datetime_usec, null: false)
      add(:osp_cleared_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec, inserted_at: :osp_inserted_at, updated_at: :osp_updated_at)
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
    drop(table(:imp_impersonation_session))
  end
end
