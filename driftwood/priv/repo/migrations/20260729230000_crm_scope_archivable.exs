defmodule Driftwood.Repo.Migrations.CrmScopeArchivable do
  @moduledoc """
  ADR-040 §5.9 (T37c) — the CRM scope's adoption sub-item: `company`, `person` 🔒,
  `pipeline`, `opportunity`, and `attachment` flip `archivable true`
  (samen_core/lib/samen/scopes/crm/blueprint.ex), mounted here under Driftwood's
  fresh `fcm/fpr/fpp/fop/fat` abbrevs (`Driftwood.Crm`). The former `activity`
  resource is not part of this migration — it was already destructively
  migrated into the canonical Work-scope `Task` and removed (ADR-041 §5, ruling
  M5, prior to T37c).

  The T36 substrate (ash_archival, ADR-037 §5.3 ADOPT) injects one abbrev-
  prefixed `<abbrev>_archived_at :utc_datetime_usec` column per adopting
  resource (NULL = live). Driftwood mounts CRM ONCE (unlike Billing's tenant +
  operator double-mount) — no unique index exists on any of the five tables
  today, so §5.3's partial-index conversion has nothing to convert (the ADR's
  "the sweep may turn up nothing" case).

  Additive columns on already-catalogued resources → `catalog_sync/2`'s
  `only:` scoping, so `down` removes exactly these five `fld_field` rows.
  """
  use Samen.Migration

  def change do
    alter table(:fcm_company) do
      add(:fcm_archived_at, :utc_datetime_usec)
    end

    alter table(:fpr_person) do
      add(:fpr_archived_at, :utc_datetime_usec)
    end

    alter table(:fpp_pipeline) do
      add(:fpp_archived_at, :utc_datetime_usec)
    end

    alter table(:fop_opportunity) do
      add(:fop_archived_at, :utc_datetime_usec)
    end

    alter table(:fat_attachment) do
      add(:fat_archived_at, :utc_datetime_usec)
    end

    catalog_sync([Driftwood.Crm.Company], only: [:archived_at])
    catalog_sync([Driftwood.Crm.Person], only: [:archived_at])
    catalog_sync([Driftwood.Crm.Pipeline], only: [:archived_at])
    catalog_sync([Driftwood.Crm.Opportunity], only: [:archived_at])
    catalog_sync([Driftwood.Crm.Attachment], only: [:archived_at])
  end
end
