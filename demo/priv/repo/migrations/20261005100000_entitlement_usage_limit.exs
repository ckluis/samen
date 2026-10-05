defmodule Demo.Repo.Migrations.EntitlementUsageLimit do
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

  @resources [Demo.BillingScope.Entitlement]

  def up do
    alter table(:ben_entitlement) do
      add(:ben_metric, :text)
      add(:ben_limit, :integer)
    end

    create(constraint(:ben_entitlement, :ben_entitlement_limit_non_negative,
      check: "ben_limit IS NULL OR ben_limit >= 0"
    ))

    catalog_sync(@resources, only: [:metric, :limit])
  end

  def down do
    catalog_sync_down(@resources, only: [:metric, :limit])

    drop(constraint(:ben_entitlement, :ben_entitlement_limit_non_negative))

    alter table(:ben_entitlement) do
      remove(:ben_limit)
      remove(:ben_metric)
    end
  end
end
