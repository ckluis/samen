defmodule SamenCore.TestRepo.Migrations.PrimitivesScopeFixtureArchivable do
  @moduledoc """
  ADR-040 §5.9 (T37e) — the Primitives scope's adoption sub-item, mirrored onto the
  samen_core kernel test fixture that mounts `Samen.Scopes.Primitives`
  (`SamenCore.Support.NotificationFixture`, abbrevs `nef`/`nwh`/`ngf`; a 5th mount
  discovered the same way T37c found CRM's own kernel fixture — this domain is
  deliberately NOT in `:ash_domains`, so it is invisible to a repo-wide `grep` for
  `Scopes.Primitives.Blueprint` unless the test suite itself is run). `file`,
  `webhook`, `feature_flag` flip `archivable true`
  (samen_core/lib/samen/scopes/primitives/blueprint.ex) — this migration mirrors
  `Demo.Repo.Migrations.PrimitivesScopeArchivable` (identical rationale: no
  `unique_index` on any of the three tables, nothing to convert).
  """
  use Samen.Migration

  def change do
    alter table(:nef_file) do
      add(:nef_archived_at, :utc_datetime_usec)
    end

    alter table(:nwh_webhook) do
      add(:nwh_archived_at, :utc_datetime_usec)
    end

    alter table(:ngf_feature_flag) do
      add(:ngf_archived_at, :utc_datetime_usec)
    end

    catalog_sync([SamenCore.Support.NotificationFixture.File], only: [:archived_at])
    catalog_sync([SamenCore.Support.NotificationFixture.Webhook], only: [:archived_at])
    catalog_sync([SamenCore.Support.NotificationFixture.FeatureFlag], only: [:archived_at])
  end
end
