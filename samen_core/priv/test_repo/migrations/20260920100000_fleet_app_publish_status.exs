defmodule SamenCore.TestRepo.Migrations.FleetAppPublishStatus do
  @moduledoc """
  T166 / ADR-050 §4.1 — `sfa_publish_status`: the per-app OPT-IN to the PUBLIC
  status page, added to the samen_core test-suite mount of the fleet blueprint
  (`test/support/fleet_fixture.ex`).

  Additive and backward-compatible: a nullable column with `DEFAULT false`, so
  every pre-existing row reads `false` (Postgres fills the default in place) and
  the old binary keeps running against the new schema. The safety property is
  carried by that default — an app that existed before this column was published
  by nobody, and the migration does not publish it either.

  `catalog_sync(..., only: [:publish_status])` writes just this column's
  `fld_field` row so `mix samen.verify.catalog_parity` stays green without the
  table entry's reverse orphaning the other columns (the F2 additive-column
  scoping the macro documents).

  Not a `pii_` column and not vault-routed: `publish_status` is a boolean the
  OPERATOR sets, INV-2 untouched.
  """
  use Samen.Migration

  @resources [SamenCore.Support.FleetFixture.App]

  def up do
    alter table(:sfa_app) do
      add(:sfa_publish_status, :boolean, null: false, default: false)
    end

    catalog_sync(@resources, only: [:publish_status])
  end

  def down do
    catalog_sync_down(@resources, only: [:publish_status])

    alter table(:sfa_app) do
      remove(:sfa_publish_status)
    end
  end
end
