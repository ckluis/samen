defmodule PawChart.Repo.Migrations.PrimitivesScopeArchivable do
  @moduledoc """
  ADR-040 §5.9 (T37e) — the Primitives scope's adoption sub-item, mirrored onto the
  PawChart mount (abbrevs `vfl`/`vwh`/`vff`; see `Demo.Repo.Migrations.
  PrimitivesScopeArchivable` for the full rationale, identical here). `file`,
  `webhook`, `feature_flag` flip `archivable true`
  (samen_core/lib/samen/scopes/primitives/blueprint.ex). `notification`/
  `notification_preference`/`search_index` stay excluded.

  §5.3: no `unique_index` on `vfl_file` / `vwh_webhook` / `vff_feature_flag` — nothing
  to convert.
  """
  use Samen.Migration

  def change do
    alter table(:vfl_file) do
      add(:vfl_archived_at, :utc_datetime_usec)
    end

    alter table(:vwh_webhook) do
      add(:vwh_archived_at, :utc_datetime_usec)
    end

    alter table(:vff_feature_flag) do
      add(:vff_archived_at, :utc_datetime_usec)
    end

    catalog_sync([PawChart.Primitives.File], only: [:archived_at])
    catalog_sync([PawChart.Primitives.Webhook], only: [:archived_at])
    catalog_sync([PawChart.Primitives.FeatureFlag], only: [:archived_at])
  end
end
