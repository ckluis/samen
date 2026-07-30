defmodule Driftwood.Repo.Migrations.BillingPlanPriceArchivable do
  @moduledoc """
  ADR-040 §5.9 (T37a) — the billing scope's adoption sub-item: `Plan` and `Price`
  flip `archivable true` (samen_core/lib/samen/scopes/billing/blueprint.ex). The
  T36 substrate (ash_archival, ADR-037 §5.3 ADOPT) injects one abbrev-prefixed
  `<abbrev>_archived_at :utc_datetime_usec` column per adopting resource
  (NULL = live). Driftwood mounts Billing TWICE against the same Postgres
  (`Driftwood.Billing` — the vertical's own tenant mount, `fbp`/`fbr`; and
  `Driftwood.Operator` — the SaaS's own book-of-business mirror, `dpp`/`dpr`)
  so both table pairs need the column. No unique index exists on any of the
  four tables today, so §5.3's partial-index conversion has nothing to convert
  (the ADR's "the sweep may turn up nothing" case).

  Additive columns on already-catalogued resources → `catalog_sync/2`'s `only:`
  scoping, so `down` removes exactly these four `fld_field` rows.
  """
  use Samen.Migration

  def change do
    alter table(:fbp_plan) do
      add(:fbp_archived_at, :utc_datetime_usec)
    end

    alter table(:fbr_price) do
      add(:fbr_archived_at, :utc_datetime_usec)
    end

    alter table(:dpp_plan) do
      add(:dpp_archived_at, :utc_datetime_usec)
    end

    alter table(:dpr_price) do
      add(:dpr_archived_at, :utc_datetime_usec)
    end

    catalog_sync([Driftwood.Billing.Plan], only: [:archived_at])
    catalog_sync([Driftwood.Billing.Price], only: [:archived_at])
    catalog_sync([Driftwood.Operator.Plan], only: [:archived_at])
    catalog_sync([Driftwood.Operator.Price], only: [:archived_at])
  end
end
