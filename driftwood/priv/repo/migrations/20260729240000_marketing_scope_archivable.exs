defmodule Driftwood.Repo.Migrations.MarketingScopeArchivable do
  @moduledoc """
  ADR-040 §5.9 (T37d) — the marketing scope's adoption sub-item, mirrored onto
  Driftwood's `fm*`-abbrev Marketing mount: `campaign`, `segment`, `subscriber`
  🔒, and `template` flip `archivable true`
  (samen_core/lib/samen/scopes/marketing/blueprint.ex). `send`, `email_event`,
  `suppression`, and `consent_event` are NOT part of this migration (excluded
  per the §5.9 roster — `suppression`'s exclusion is absolute).

  The T36 substrate injects one abbrev-prefixed `<abbrev>_archived_at
  :utc_datetime_usec` column per adopting resource (NULL = live); no unique
  index exists on `fmc_campaign`/`fmg_segment`/`fms_subscriber`/`fmt_template`
  today, so §5.3's partial-index conversion has nothing to convert.

  Additive columns on already-catalogued resources → `catalog_sync/2`'s
  `only:` scoping, so `down` removes exactly these four `fld_field` rows.
  """
  use Samen.Migration

  def change do
    alter table(:fmc_campaign) do
      add(:fmc_archived_at, :utc_datetime_usec)
    end

    alter table(:fmg_segment) do
      add(:fmg_archived_at, :utc_datetime_usec)
    end

    alter table(:fms_subscriber) do
      add(:fms_archived_at, :utc_datetime_usec)
    end

    alter table(:fmt_template) do
      add(:fmt_archived_at, :utc_datetime_usec)
    end

    catalog_sync([Driftwood.Marketing.Campaign], only: [:archived_at])
    catalog_sync([Driftwood.Marketing.Segment], only: [:archived_at])
    catalog_sync([Driftwood.Marketing.Subscriber], only: [:archived_at])
    catalog_sync([Driftwood.Marketing.Template], only: [:archived_at])
  end
end
