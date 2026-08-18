defmodule Samen.WebTest.Repo.Migrations.MountViewsScope do
  @moduledoc """
  Mounts the Views universal scope (G10 saved views, T58) into the samen_web test host's
  Postgres, and catalogs the resource in the SAME migration transaction (ADR-004
  catalog-in-tx). Mirrors `20260729120000_mount_tags_scope.exs` with the samen_web test
  host's own `wvs` abbrev.

  `wvs_params` is a jsonb bag (the serialized, non-secret view-state blob). Uniqueness is
  per `(org_id, owner_id, surface, name)` among LIVE rows — a user may reuse a view name
  across surfaces, but not twice on the same surface (the create/rename semantics).
  """
  use Samen.Migration

  @resources [
    Samen.WebTest.Views.SavedView
  ]

  def up do
    create table(:wvs_saved_view, primary_key: false) do
      add(:wvs_name, :text, null: false)
      add(:wvs_surface, :text, null: false)
      add(:wvs_view_type, :text, null: false, default: "table")
      add(:wvs_params, :map, null: false, default: fragment("'{}'::jsonb"))
      add(:wvs_owner_id, :uuid, null: false)
      add(:wvs_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:wvs_org_id, :uuid, null: false)
      add(:wvs_inserted_at, :utc_datetime, null: false)
      add(:wvs_updated_at, :utc_datetime, null: false)
    end

    create(index(:wvs_saved_view, [:wvs_org_id]))
    create(index(:wvs_saved_view, [:wvs_org_id, :wvs_owner_id]))

    create(
      unique_index(:wvs_saved_view, [:wvs_org_id, :wvs_owner_id, :wvs_surface, :wvs_name],
        name: :wvs_saved_view_owner_surface_name_index
      )
    )

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)
    drop(table(:wvs_saved_view))
  end
end
