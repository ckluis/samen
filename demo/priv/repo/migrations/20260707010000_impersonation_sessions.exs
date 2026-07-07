defmodule Demo.Repo.Migrations.ImpersonationSessions do
  @moduledoc "T4.1 masked-impersonation session table for the demo app (mirrors the samen_core test_repo migration)."
  use Ecto.Migration

  def up do
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
  end

  def down do
    drop(table(:imp_impersonation_session))
  end
end
