defmodule PawChart.Repo.Migrations.MarketingScopeArchivable do
  @moduledoc """
  ADR-040 §5.9 (T37d) — the marketing scope's adoption sub-item, mirrored onto
  PawChart's `vm*`-abbrev Marketing mount: `campaign`, `segment`, `subscriber`
  🔒, and `template` flip `archivable true`
  (samen_core/lib/samen/scopes/marketing/blueprint.ex). `send`, `email_event`,
  `suppression`, and `consent_event` are NOT part of this migration (excluded
  per the §5.9 roster — `suppression`'s exclusion is absolute).

  The T36 substrate injects one abbrev-prefixed `<abbrev>_archived_at
  :utc_datetime_usec` column per adopting resource (NULL = live); no unique
  index exists on `vmc_campaign`/`vmg_segment`/`vms_subscriber`/`vmt_template`
  today, so §5.3's partial-index conversion has nothing to convert.

  Additive columns on already-catalogued resources → `catalog_sync/2`'s
  `only:` scoping, so `down` removes exactly these four `fld_field` rows.
  """
  use Samen.Migration

  def change do
    alter table(:vmc_campaign) do
      add(:vmc_archived_at, :utc_datetime_usec)
    end

    alter table(:vmg_segment) do
      add(:vmg_archived_at, :utc_datetime_usec)
    end

    alter table(:vms_subscriber) do
      add(:vms_archived_at, :utc_datetime_usec)
    end

    alter table(:vmt_template) do
      add(:vmt_archived_at, :utc_datetime_usec)
    end

    catalog_sync([PawChart.Marketing.Campaign], only: [:archived_at])
    catalog_sync([PawChart.Marketing.Segment], only: [:archived_at])
    catalog_sync([PawChart.Marketing.Subscriber], only: [:archived_at])
    catalog_sync([PawChart.Marketing.Template], only: [:archived_at])
  end
end
