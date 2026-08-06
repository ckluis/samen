defmodule Samen.WebTest.Repo.Migrations.ImpersonationSessions do
  @moduledoc """
  T150 — provision the T4.1 masked-impersonation session table in the samen_web
  scratch host repo, so the framework OPERATOR per-tenant drill-in surfaces
  (`Samen.Web.Operator.{DeliverabilityLive,AutomationHealthLive,ActivityLive}`)
  can require a REAL `Samen.Impersonation` session (deny-on-read) instead of the
  old synthetic `impersonation: %{session_id: "operator-…"}` marker.

  `:impersonation_repo` is already `Samen.WebTest.Repo` (config/config.exs); this
  migration makes that pointer non-vacuous — the session row a drill-in gate
  consults + the tenant-visible ledger (`Impersonation.Sessions.list_for_org/2`)
  now live in the same scratch DB the render tests run against. Schema is byte-for-
  byte the samen_core test_repo `imp_impersonation_session` table (a host that
  mounts operator drill-ins needs this table; driftwood already carries it).
  """
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
