defmodule Samen.WebTest.Repo.Migrations.OperatorSuspension do
  @moduledoc """
  T150 — provision the T4.4 per-operator suspension flag table in the samen_web
  scratch host repo. `Samen.Impersonation.Sessions.open/1` and
  `Samen.Impersonation.Scope.for_session/3` both consult
  `Samen.OperatorPlane.Suspension.suspended?/2` on the per-request deny path, and
  that check is FAIL-CLOSED: an unreachable suspension table is treated as
  "suspended", which would make every real `open/3` from the samen_web operator
  drill-in gate return `{:error, :operator_suspended}`. Provisioning the table
  (the SAME `osp_operator_suspension` schema as the samen_core test_repo /
  break_glass migration) lets an UNSUSPENDED operator open a session — the
  positive control the T150 gate proof needs — while keeping the suspension
  terminate-live-session semantics honest.
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
  end

  def down do
    drop(table(:osp_operator_suspension))
  end
end
