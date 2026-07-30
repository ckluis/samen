defmodule Samen.WebTest.Repo.Migrations.MarketingScopeArchivable do
  @moduledoc """
  ADR-040 §5.9 (T37d) — the marketing scope's adoption sub-item, mirrored onto
  the samen_web test-support `wm*`-abbrev Marketing mount: `campaign`,
  `segment`, `subscriber` 🔒, and `template` flip `archivable true`
  (samen_core/lib/samen/scopes/marketing/blueprint.ex). `send`, `email_event`,
  `suppression`, and `consent_event` are NOT part of this migration (excluded
  per the §5.9 roster — `suppression`'s exclusion is absolute).

  The T36 substrate injects one abbrev-prefixed `<abbrev>_archived_at
  :utc_datetime_usec` column per adopting resource (NULL = live); no unique
  index exists on `wmc_campaign`/`wmg_segment`/`wms_subscriber`/`wmt_template`
  today, so §5.3's partial-index conversion has nothing to convert.

  Additive columns on already-catalogued resources → `catalog_sync/2`'s
  `only:` scoping, so `down` removes exactly these four `fld_field` rows.
  """
  use Samen.Migration

  def change do
    alter table(:wmc_campaign) do
      add(:wmc_archived_at, :utc_datetime_usec)
    end

    alter table(:wmg_segment) do
      add(:wmg_archived_at, :utc_datetime_usec)
    end

    alter table(:wms_subscriber) do
      add(:wms_archived_at, :utc_datetime_usec)
    end

    alter table(:wmt_template) do
      add(:wmt_archived_at, :utc_datetime_usec)
    end

    catalog_sync([Samen.WebTest.Marketing.Campaign], only: [:archived_at])
    catalog_sync([Samen.WebTest.Marketing.Segment], only: [:archived_at])
    catalog_sync([Samen.WebTest.Marketing.Subscriber], only: [:archived_at])
    catalog_sync([Samen.WebTest.Marketing.Template], only: [:archived_at])
  end
end
