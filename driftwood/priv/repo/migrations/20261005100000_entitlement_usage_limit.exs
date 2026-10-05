defmodule Driftwood.Repo.Migrations.EntitlementUsageLimit do
  @moduledoc """
  T163 (ADR-051 P3): an `Entitlement` row may carry a numeric usage limit, read by
  `Samen.Billing.Quota.within_limit?/4`.

    * `metric` — the usage metric the row limits (the same bounded set as `Usage`).
    * `limit` — the most of that metric allowed per billing period, MIRRORED from the
      provider's plan, never computed. NULL = unlimited. Non-negative at the table too.

  Both columns are nullable, so every existing row stays a plain feature grant. They
  are catalogued in the same transaction (ADR-004 catalog-in-tx).
  """
  use Samen.Migration

  @resources [Driftwood.Billing.Entitlement, Driftwood.Operator.Entitlement]

  def up do
    alter table(:fbe_entitlement) do
      add(:fbe_metric, :text)
      add(:fbe_limit, :integer)
    end

    create(constraint(:fbe_entitlement, :fbe_entitlement_limit_non_negative,
      check: "fbe_limit IS NULL OR fbe_limit >= 0"
    ))

    alter table(:dpe_entitlement) do
      add(:dpe_metric, :text)
      add(:dpe_limit, :integer)
    end

    create(constraint(:dpe_entitlement, :dpe_entitlement_limit_non_negative,
      check: "dpe_limit IS NULL OR dpe_limit >= 0"
    ))

    catalog_sync(@resources, only: [:metric, :limit])
  end

  def down do
    catalog_sync_down(@resources, only: [:metric, :limit])

    drop(constraint(:fbe_entitlement, :fbe_entitlement_limit_non_negative))

    alter table(:fbe_entitlement) do
      remove(:fbe_limit)
      remove(:fbe_metric)
    end

    drop(constraint(:dpe_entitlement, :dpe_entitlement_limit_non_negative))

    alter table(:dpe_entitlement) do
      remove(:dpe_limit)
      remove(:dpe_metric)
    end
  end
end
