defmodule Samen.WebTest.Repo.Migrations.PrimitivesScopeArchivable do
  @moduledoc """
  ADR-040 §5.9 (T37e) — the Primitives scope's adoption sub-item, on the samen_web
  test host mount (abbrevs `wnf`/`wnw`/`wng`; see `Demo.Repo.Migrations.
  PrimitivesScopeArchivable` for the full rationale, identical here). `file`,
  `webhook`, `feature_flag` flip `archivable true`
  (samen_core/lib/samen/scopes/primitives/blueprint.ex). `notification`/
  `notification_preference`/`search_index` stay excluded.

  §5.3: no `unique_index` on `wnf_file` / `wnw_webhook` / `wng_feature_flag` —
  nothing to convert.
  """
  use Samen.Migration

  def change do
    alter table(:wnf_file) do
      add(:wnf_archived_at, :utc_datetime_usec)
    end

    alter table(:wnw_webhook) do
      add(:wnw_archived_at, :utc_datetime_usec)
    end

    alter table(:wng_feature_flag) do
      add(:wng_archived_at, :utc_datetime_usec)
    end

    catalog_sync([Samen.WebTest.Primitives.File], only: [:archived_at])
    catalog_sync([Samen.WebTest.Primitives.Webhook], only: [:archived_at])
    catalog_sync([Samen.WebTest.Primitives.FeatureFlag], only: [:archived_at])
  end
end
