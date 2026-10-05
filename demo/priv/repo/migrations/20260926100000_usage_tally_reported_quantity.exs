defmodule Demo.Repo.Migrations.UsageTallyReportedQuantity do
  @moduledoc """
  T163 (ADR-051 P2): the `Usage` row becomes a DERIVED tally, recomputed from the
  `UsageEvent` ledger by `Samen.Billing.UsageTally.rebuild/5`.

    * `reported_quantity` — how much of `quantity` the provider has already been sent.
      The reporter sends only the delta, because the provider's metered-usage call
      increments. Bounded to `0..quantity` at the table too.
    * a unique `(org, subscription, metric, period_start)` index — the identity the
      rebuild upserts on, so one period has one tally.

  The column is re-catalogued in the same transaction (ADR-004 catalog-in-tx).
  """
  use Samen.Migration

  @resources [Demo.BillingScope.Usage]

  def up do
    alter table(:bus_usage) do
      add(:bus_reported_quantity, :integer, null: false, default: 0)
    end

    create(constraint(:bus_usage, :bus_usage_reported_quantity_bounded,
      check: "bus_reported_quantity >= 0 AND bus_reported_quantity <= bus_quantity"
    ))

    create(
      unique_index(:bus_usage, [:bus_org_id, :bus_subscription_id, :bus_metric, :bus_period_start],
        name: "bus_usage_unique_tally_index"
      )
    )

    catalog_sync(@resources, only: [:reported_quantity])
  end

  def down do
    catalog_sync_down(@resources, only: [:reported_quantity])

    drop(index(:bus_usage, [], name: "bus_usage_unique_tally_index"))
    drop(constraint(:bus_usage, :bus_usage_reported_quantity_bounded))

    alter table(:bus_usage) do
      remove(:bus_reported_quantity)
    end
  end
end
