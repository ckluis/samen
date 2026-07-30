defmodule Demo.Repo.Migrations.BillingPlanPriceArchivable do
  @moduledoc """
  ADR-040 §5.9 (T37a) — the billing scope's adoption sub-item: `Plan` and `Price`
  flip `archivable true` (samen_core/lib/samen/scopes/billing/blueprint.ex). The
  T36 substrate (ash_archival, ADR-037 §5.3 ADOPT) injects one abbrev-prefixed
  `<abbrev>_archived_at :utc_datetime_usec` column per adopting resource
  (NULL = live); no other DDL changes for this scope (§5.3: no unique index
  exists on `bpl_plan`/`bpr_price` today, so there is nothing to convert to
  partial form — the ADR's "the sweep may turn up nothing" case).

  Additive columns on already-catalogued resources → `catalog_sync/2`'s `only:`
  scoping, so `down` removes exactly these two `fld_field` rows.
  """
  use Samen.Migration

  def change do
    alter table(:bpl_plan) do
      add(:bpl_archived_at, :utc_datetime_usec)
    end

    alter table(:bpr_price) do
      add(:bpr_archived_at, :utc_datetime_usec)
    end

    catalog_sync([Demo.BillingScope.Plan], only: [:archived_at])
    catalog_sync([Demo.BillingScope.Price], only: [:archived_at])
  end
end
