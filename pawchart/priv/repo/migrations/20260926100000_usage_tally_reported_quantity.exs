defmodule PawChart.Repo.Migrations.UsageTallyReportedQuantity do
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

  @resources [PawChart.Billing.Usage, PawChart.Operator.Usage]

  def up do
    alter table(:pbu_usage) do
      add(:pbu_reported_quantity, :integer, null: false, default: 0)
    end

    create(constraint(:pbu_usage, :pbu_usage_reported_quantity_bounded,
      check: "pbu_reported_quantity >= 0 AND pbu_reported_quantity <= pbu_quantity"
    ))

    create(
      unique_index(:pbu_usage, [:pbu_org_id, :pbu_subscription_id, :pbu_metric, :pbu_period_start],
        name: "pbu_usage_unique_tally_index"
      )
    )

    alter table(:pmu_usage) do
      add(:pmu_reported_quantity, :integer, null: false, default: 0)
    end

    create(constraint(:pmu_usage, :pmu_usage_reported_quantity_bounded,
      check: "pmu_reported_quantity >= 0 AND pmu_reported_quantity <= pmu_quantity"
    ))

    create(
      unique_index(:pmu_usage, [:pmu_org_id, :pmu_subscription_id, :pmu_metric, :pmu_period_start],
        name: "pmu_usage_unique_tally_index"
      )
    )

    catalog_sync(@resources, only: [:reported_quantity])
  end

  def down do
    catalog_sync_down(@resources, only: [:reported_quantity])

    drop(index(:pbu_usage, [], name: "pbu_usage_unique_tally_index"))
    drop(constraint(:pbu_usage, :pbu_usage_reported_quantity_bounded))

    alter table(:pbu_usage) do
      remove(:pbu_reported_quantity)
    end

    drop(index(:pmu_usage, [], name: "pmu_usage_unique_tally_index"))
    drop(constraint(:pmu_usage, :pmu_usage_reported_quantity_bounded))

    alter table(:pmu_usage) do
      remove(:pmu_reported_quantity)
    end
  end
end
