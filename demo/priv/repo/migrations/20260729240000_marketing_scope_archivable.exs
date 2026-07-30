defmodule Demo.Repo.Migrations.MarketingScopeArchivable do
  @moduledoc """
  ADR-040 §5.9 (T37d) — the marketing scope's adoption sub-item: `campaign`,
  `segment`, `subscriber` 🔒, and `template` flip `archivable true`
  (samen_core/lib/samen/scopes/marketing/blueprint.ex). `send`, `email_event`,
  `suppression`, and `consent_event` are NOT part of this migration — all four
  are excluded (send/email_event/consent_event are (L) append-only ledgers;
  `suppression` is the roster's absolute "never" exclusion — a hidden
  suppression row would be a compliance leak).

  The T36 substrate (ash_archival, ADR-037 §5.3 ADOPT) injects one abbrev-
  prefixed `<abbrev>_archived_at :utc_datetime_usec` column per adopting
  resource (NULL = live); no other DDL changes for this scope (§5.3: no unique
  index exists on `mca_campaign`/`msg_segment`/`msu_subscriber`/`mtp_template`
  today, so there is nothing to convert to partial form — the ADR's "the sweep
  may turn up nothing" case).

  Additive columns on already-catalogued resources → `catalog_sync/2`'s
  `only:` scoping, so `down` removes exactly these four `fld_field` rows.
  """
  use Samen.Migration

  def change do
    alter table(:mca_campaign) do
      add(:mca_archived_at, :utc_datetime_usec)
    end

    alter table(:msg_segment) do
      add(:msg_archived_at, :utc_datetime_usec)
    end

    alter table(:msu_subscriber) do
      add(:msu_archived_at, :utc_datetime_usec)
    end

    alter table(:mtp_template) do
      add(:mtp_archived_at, :utc_datetime_usec)
    end

    catalog_sync([Demo.MarketingScope.Campaign], only: [:archived_at])
    catalog_sync([Demo.MarketingScope.Segment], only: [:archived_at])
    catalog_sync([Demo.MarketingScope.Subscriber], only: [:archived_at])
    catalog_sync([Demo.MarketingScope.Template], only: [:archived_at])
  end
end
