defmodule Demo.Repo.Migrations.CrmScopeArchivable do
  @moduledoc """
  ADR-040 §5.9 (T37c) — the CRM scope's adoption sub-item: `company`, `person` 🔒,
  `pipeline`, `opportunity`, and `attachment` flip `archivable true`
  (samen_core/lib/samen/scopes/crm/blueprint.ex). The former `activity` resource
  is not part of this migration — it was destructively migrated into the
  canonical Work-scope `Task` and removed before T37c ran (ADR-041 §5, T97).

  The T36 substrate (ash_archival, ADR-037 §5.3 ADOPT) injects one abbrev-
  prefixed `<abbrev>_archived_at :utc_datetime_usec` column per adopting
  resource (NULL = live); no other DDL changes for this scope (§5.3: no
  unique index exists on `cmp_company`/`per_person`/`pip_pipeline`/
  `opp_opportunity`/`att_attachment` today, so there is nothing to convert to
  partial form — the ADR's "the sweep may turn up nothing" case).

  Additive columns on already-catalogued resources → `catalog_sync/2`'s
  `only:` scoping, so `down` removes exactly these five `fld_field` rows.
  """
  use Samen.Migration

  def change do
    alter table(:cmp_company) do
      add(:cmp_archived_at, :utc_datetime_usec)
    end

    alter table(:per_person) do
      add(:per_archived_at, :utc_datetime_usec)
    end

    alter table(:pip_pipeline) do
      add(:pip_archived_at, :utc_datetime_usec)
    end

    alter table(:opp_opportunity) do
      add(:opp_archived_at, :utc_datetime_usec)
    end

    alter table(:att_attachment) do
      add(:att_archived_at, :utc_datetime_usec)
    end

    catalog_sync([Demo.CrmScope.Company], only: [:archived_at])
    catalog_sync([Demo.CrmScope.Person], only: [:archived_at])
    catalog_sync([Demo.CrmScope.Pipeline], only: [:archived_at])
    catalog_sync([Demo.CrmScope.Opportunity], only: [:archived_at])
    catalog_sync([Demo.CrmScope.Attachment], only: [:archived_at])
  end
end
