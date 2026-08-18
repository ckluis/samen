defmodule SamenCore.TestRepo.Migrations.MarketingScopeFixtureArchivable do
  @moduledoc """
  ADR-040 §5.9 (T37d) — the marketing scope's adoption sub-item, mirrored onto
  the kernel's OWN Marketing scope mount (`test/support/suppression_fixture.ex`,
  fresh `sxc/sxg/sxs/sxt/sxn/sxe/sxp/sxv` abbrevs — the ADR-014 §4 RP-D3
  fixture proving the suppression check is portable across mount abbrevs).
  `campaign`, `segment`, `subscriber` 🔒, and `template` flip `archivable true`
  (samen_core/lib/samen/scopes/marketing/blueprint.ex); this fixture mount
  needs the same additive column every other Marketing host got, or its own
  `create`s 42703 (`undefined_column ..._archived_at`) — this fixture is
  effectively a fifth/sixth Marketing "host" alongside demo/driftwood/
  pawchart/samen_web (mirrors T37c's `crm_scope_fixture_archivable.exs`
  precedent for the analogous CRM kernel fixture).

  `send`, `email_event`, `suppression`, and `consent_event` are NOT part of
  this migration — excluded per the §5.9 roster (`suppression`'s exclusion is
  absolute).

  The T36 substrate injects one abbrev-prefixed `<abbrev>_archived_at
  :utc_datetime_usec` column per adopting resource (NULL = live); no unique
  index exists on any of the four tables today, so §5.3's partial-index
  conversion has nothing to convert.

  Additive columns on already-catalogued resources → `catalog_sync/2`'s
  `only:` scoping, so `down` removes exactly these four `fld_field` rows.
  """
  use Samen.Migration

  def change do
    alter table(:sxc_campaign) do
      add(:sxc_archived_at, :utc_datetime_usec)
    end

    alter table(:sxg_segment) do
      add(:sxg_archived_at, :utc_datetime_usec)
    end

    alter table(:sxs_subscriber) do
      add(:sxs_archived_at, :utc_datetime_usec)
    end

    alter table(:sxt_template) do
      add(:sxt_archived_at, :utc_datetime_usec)
    end

    catalog_sync([SamenCore.Support.SuppressionFixture.Campaign], only: [:archived_at])
    catalog_sync([SamenCore.Support.SuppressionFixture.Segment], only: [:archived_at])
    catalog_sync([SamenCore.Support.SuppressionFixture.Subscriber], only: [:archived_at])
    catalog_sync([SamenCore.Support.SuppressionFixture.Template], only: [:archived_at])
  end
end
