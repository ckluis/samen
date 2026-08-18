defmodule SamenCore.TestRepo.Migrations.CrmScopeFixtureArchivable do
  @moduledoc """
  ADR-040 §5.9 (T37c) — the CRM scope's adoption sub-item, mirrored onto the
  kernel's OWN CRM scope mount (`test/support/crm_scope_fixture.ex`, fresh
  `scc/scp/csp/sco/sca` abbrevs — the Lead-conversion TARGET for the SalesOps
  scope fixture, T48). `company`, `person` 🔒, `pipeline`, `opportunity`, and
  `attachment` flip `archivable true` (samen_core/lib/samen/scopes/crm/blueprint.ex);
  this fixture mount needs the same additive column every other CRM host got,
  or its own `create`s 42703 (`undefined_column ..._archived_at`) — this
  fixture is effectively a fifth CRM "host" alongside demo/driftwood/pawchart/
  samen_web. The former `activity` resource is not part of this migration —
  it was already destructively migrated into the canonical Work-scope `Task`
  and removed (ADR-041 §5, ruling M5, prior to T37c).

  The T36 substrate (ash_archival, ADR-037 §5.3 ADOPT) injects one abbrev-
  prefixed `<abbrev>_archived_at :utc_datetime_usec` column per adopting
  resource (NULL = live). No unique index exists on any of the five tables
  today, so §5.3's partial-index conversion has nothing to convert.

  Additive columns on already-catalogued resources → `catalog_sync/2`'s
  `only:` scoping, so `down` removes exactly these five `fld_field` rows.
  """
  use Samen.Migration

  def change do
    alter table(:scc_company) do
      add(:scc_archived_at, :utc_datetime_usec)
    end

    alter table(:scp_person) do
      add(:scp_archived_at, :utc_datetime_usec)
    end

    alter table(:csp_pipeline) do
      add(:csp_archived_at, :utc_datetime_usec)
    end

    alter table(:sco_opportunity) do
      add(:sco_archived_at, :utc_datetime_usec)
    end

    alter table(:sca_attachment) do
      add(:sca_archived_at, :utc_datetime_usec)
    end

    catalog_sync([SamenCore.Support.CrmScopeFixture.Company], only: [:archived_at])
    catalog_sync([SamenCore.Support.CrmScopeFixture.Person], only: [:archived_at])
    catalog_sync([SamenCore.Support.CrmScopeFixture.Pipeline], only: [:archived_at])
    catalog_sync([SamenCore.Support.CrmScopeFixture.Opportunity], only: [:archived_at])
    catalog_sync([SamenCore.Support.CrmScopeFixture.Attachment], only: [:archived_at])
  end
end
