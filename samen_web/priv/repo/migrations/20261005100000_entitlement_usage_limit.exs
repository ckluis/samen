defmodule Samen.WebTest.Repo.Migrations.EntitlementUsageLimit do
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

  @resources [Samen.WebTest.Billing.Entitlement, Samen.WebTest.Operator.Entitlement]

  def up do
    alter table(:wbe_entitlement) do
      add(:wbe_metric, :text)
      add(:wbe_limit, :integer)
    end

    create(constraint(:wbe_entitlement, :wbe_entitlement_limit_non_negative,
      check: "wbe_limit IS NULL OR wbe_limit >= 0"
    ))

    alter table(:wpe_entitlement) do
      add(:wpe_metric, :text)
      add(:wpe_limit, :integer)
    end

    create(constraint(:wpe_entitlement, :wpe_entitlement_limit_non_negative,
      check: "wpe_limit IS NULL OR wpe_limit >= 0"
    ))

    catalog_sync(@resources, only: [:metric, :limit])
  end

  def down do
    catalog_sync_down(@resources, only: [:metric, :limit])

    drop(constraint(:wbe_entitlement, :wbe_entitlement_limit_non_negative))

    alter table(:wbe_entitlement) do
      remove(:wbe_limit)
      remove(:wbe_metric)
    end

    drop(constraint(:wpe_entitlement, :wpe_entitlement_limit_non_negative))

    alter table(:wpe_entitlement) do
      remove(:wpe_limit)
      remove(:wpe_metric)
    end
  end
end
