defmodule Samen.WebTest.Repo.Migrations.MountOperatorScopeAssignment do
  @moduledoc """
  T84 (ADR-044 §16.5 #1, ruling R-A) — mounts the operator-account ASSIGNMENT
  blueprint (`Samen.Fleet.Assignment`) into the samen_web test host's Postgres,
  mirroring `20260807010000_mount_fleet_scope.exs` with this host's own `woa` abbrev.

  The data source `scope_of/2`'s real reader (`scope_from_assignments/4`) and the R-B
  drill-in scope gate (`Samen.Web.Operator.Impersonation.gate/3`) read. Token-blind:
  `woa_operator_id`/`woa_account_org_id` are bounded uuids, `woa_app_scope` a bounded
  lowercase slug — no name, no PII (INV-2 / NoPiiColumns).
  """
  use Samen.Migration

  @resources [Samen.WebTest.OperatorScope.Assignment]

  def up do
    create table(:woa_assignment, primary_key: false) do
      add(:woa_operator_id, :uuid, null: false)
      add(:woa_app_scope, :text, null: false)
      add(:woa_account_org_id, :uuid, null: false)

      add(:woa_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:woa_org_id, :uuid)
      add(:woa_inserted_at, :utc_datetime, null: false)
      add(:woa_updated_at, :utc_datetime, null: false)
    end

    # The `:unique_grant` identity — one grant per (operator, product, account); also the
    # concurrency guard against a double-insert on re-grant.
    create(
      unique_index(:woa_assignment, [:woa_operator_id, :woa_app_scope, :woa_account_org_id],
        name: :woa_assignment_unique_grant_index
      )
    )

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)
    drop(table(:woa_assignment))
  end
end
