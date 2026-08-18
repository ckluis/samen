defmodule PawChart.Repo.Migrations.CrmScopeArchivable do
  @moduledoc """
  ADR-040 §5.9 (T37c) — the CRM scope's adoption sub-item: `company`, `person` 🔒,
  `pipeline`, `opportunity`, and `attachment` flip `archivable true`
  (samen_core/lib/samen/scopes/crm/blueprint.ex), mounted here under PawChart's
  fresh `vca/vcb/vcc/vcd/vcf` abbrevs (`PawChart.Crm`). The former `activity`
  resource (`vce`) is not part of this migration — it was already destructively
  migrated into the canonical Work-scope `Task` and removed (ADR-041 §5, ruling
  M5, prior to T37c).

  The T36 substrate (ash_archival, ADR-037 §5.3 ADOPT) injects one abbrev-
  prefixed `<abbrev>_archived_at :utc_datetime_usec` column per adopting
  resource (NULL = live). No unique index exists on any of the five tables
  today, so §5.3's partial-index conversion has nothing to convert (the ADR's
  "the sweep may turn up nothing" case).

  Additive columns on already-catalogued resources → `catalog_sync/2`'s
  `only:` scoping, so `down` removes exactly these five `fld_field` rows.
  """
  use Samen.Migration

  def change do
    alter table(:vca_company) do
      add(:vca_archived_at, :utc_datetime_usec)
    end

    alter table(:vcb_person) do
      add(:vcb_archived_at, :utc_datetime_usec)
    end

    alter table(:vcc_pipeline) do
      add(:vcc_archived_at, :utc_datetime_usec)
    end

    alter table(:vcd_opportunity) do
      add(:vcd_archived_at, :utc_datetime_usec)
    end

    alter table(:vcf_attachment) do
      add(:vcf_archived_at, :utc_datetime_usec)
    end

    catalog_sync([PawChart.Crm.Company], only: [:archived_at])
    catalog_sync([PawChart.Crm.Person], only: [:archived_at])
    catalog_sync([PawChart.Crm.Pipeline], only: [:archived_at])
    catalog_sync([PawChart.Crm.Opportunity], only: [:archived_at])
    catalog_sync([PawChart.Crm.Attachment], only: [:archived_at])
  end
end
