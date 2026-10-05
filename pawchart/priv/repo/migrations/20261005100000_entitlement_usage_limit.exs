defmodule PawChart.Repo.Migrations.EntitlementUsageLimit do
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

  @resources [PawChart.Billing.Entitlement, PawChart.Operator.Entitlement]

  def up do
    alter table(:pbe_entitlement) do
      add(:pbe_metric, :text)
      add(:pbe_limit, :integer)
    end

    create(constraint(:pbe_entitlement, :pbe_entitlement_limit_non_negative,
      check: "pbe_limit IS NULL OR pbe_limit >= 0"
    ))

    alter table(:pme_entitlement) do
      add(:pme_metric, :text)
      add(:pme_limit, :integer)
    end

    create(constraint(:pme_entitlement, :pme_entitlement_limit_non_negative,
      check: "pme_limit IS NULL OR pme_limit >= 0"
    ))

    catalog_sync(@resources, only: [:metric, :limit])
  end

  def down do
    catalog_sync_down(@resources, only: [:metric, :limit])

    drop(constraint(:pbe_entitlement, :pbe_entitlement_limit_non_negative))

    alter table(:pbe_entitlement) do
      remove(:pbe_limit)
      remove(:pbe_metric)
    end

    drop(constraint(:pme_entitlement, :pme_entitlement_limit_non_negative))

    alter table(:pme_entitlement) do
      remove(:pme_limit)
      remove(:pme_metric)
    end
  end
end
