defmodule Samen.WebTest.Repo.Migrations.BillingPlanPriceArchivable do
  @moduledoc """
  ADR-040 §5.9 (T37a) — the billing scope's adoption sub-item: `Plan` and `Price`
  flip `archivable true` (samen_core/lib/samen/scopes/billing/blueprint.ex). The
  T36 substrate (ash_archival, ADR-037 §5.3 ADOPT) injects one abbrev-prefixed
  `<abbrev>_archived_at :utc_datetime_usec` column per adopting resource
  (NULL = live). samen_web's test host mounts Billing TWICE against the same
  Postgres (`Samen.WebTest.Billing`, `wbp`/`wbr`; and `Samen.WebTest.Operator`,
  ADR-010 §8's second mount, `wpp`/`wpr`) so both table pairs need the column.
  No unique index exists on any of the four tables today, so §5.3's
  partial-index conversion has nothing to convert (the ADR's "the sweep may
  turn up nothing" case).

  Additive columns on already-catalogued resources → `catalog_sync/2`'s `only:`
  scoping, so `down` removes exactly these four `fld_field` rows.
  """
  use Samen.Migration

  def change do
    alter table(:wbp_plan) do
      add(:wbp_archived_at, :utc_datetime_usec)
    end

    alter table(:wbr_price) do
      add(:wbr_archived_at, :utc_datetime_usec)
    end

    alter table(:wpp_plan) do
      add(:wpp_archived_at, :utc_datetime_usec)
    end

    alter table(:wpr_price) do
      add(:wpr_archived_at, :utc_datetime_usec)
    end

    catalog_sync([Samen.WebTest.Billing.Plan], only: [:archived_at])
    catalog_sync([Samen.WebTest.Billing.Price], only: [:archived_at])
    catalog_sync([Samen.WebTest.Operator.Plan], only: [:archived_at])
    catalog_sync([Samen.WebTest.Operator.Price], only: [:archived_at])
  end
end
