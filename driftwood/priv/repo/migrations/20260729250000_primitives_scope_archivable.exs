defmodule Driftwood.Repo.Migrations.PrimitivesScopeArchivable do
  @moduledoc """
  ADR-040 §5.9 (T37e) — the Primitives scope's adoption sub-item, mirrored onto the
  Driftwood mount (abbrevs `ffl`/`fwh`/`fff`; see `Demo.Repo.Migrations.
  PrimitivesScopeArchivable` for the full rationale, identical here). `file`,
  `webhook`, `feature_flag` flip `archivable true`
  (samen_core/lib/samen/scopes/primitives/blueprint.ex). `notification`/
  `notification_preference`/`search_index` stay excluded.

  §5.3: no `unique_index` on `ffl_file` / `fwh_webhook` / `fff_feature_flag` — nothing
  to convert.
  """
  use Samen.Migration

  def change do
    alter table(:ffl_file) do
      add(:ffl_archived_at, :utc_datetime_usec)
    end

    alter table(:fwh_webhook) do
      add(:fwh_archived_at, :utc_datetime_usec)
    end

    alter table(:fff_feature_flag) do
      add(:fff_archived_at, :utc_datetime_usec)
    end

    catalog_sync([Driftwood.Primitives.File], only: [:archived_at])
    catalog_sync([Driftwood.Primitives.Webhook], only: [:archived_at])
    catalog_sync([Driftwood.Primitives.FeatureFlag], only: [:archived_at])
  end
end
