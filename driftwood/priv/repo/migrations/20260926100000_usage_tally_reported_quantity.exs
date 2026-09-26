defmodule Driftwood.Repo.Migrations.UsageTallyReportedQuantity do
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

  @resources [Driftwood.Billing.Usage, Driftwood.Operator.Usage]

  def up do
    alter table(:fbu_usage) do
      add(:fbu_reported_quantity, :integer, null: false, default: 0)
    end

    create(constraint(:fbu_usage, :fbu_usage_reported_quantity_bounded,
      check: "fbu_reported_quantity >= 0 AND fbu_reported_quantity <= fbu_quantity"
    ))

    create(
      unique_index(:fbu_usage, [:fbu_org_id, :fbu_subscription_id, :fbu_metric, :fbu_period_start],
        name: "fbu_usage_unique_tally_index"
      )
    )

    alter table(:dpu_usage) do
      add(:dpu_reported_quantity, :integer, null: false, default: 0)
    end

    create(constraint(:dpu_usage, :dpu_usage_reported_quantity_bounded,
      check: "dpu_reported_quantity >= 0 AND dpu_reported_quantity <= dpu_quantity"
    ))

    create(
      unique_index(:dpu_usage, [:dpu_org_id, :dpu_subscription_id, :dpu_metric, :dpu_period_start],
        name: "dpu_usage_unique_tally_index"
      )
    )

    catalog_sync(@resources, only: [:reported_quantity])
  end

  def down do
    catalog_sync_down(@resources, only: [:reported_quantity])

    drop(index(:fbu_usage, [], name: "fbu_usage_unique_tally_index"))
    drop(constraint(:fbu_usage, :fbu_usage_reported_quantity_bounded))

    alter table(:fbu_usage) do
      remove(:fbu_reported_quantity)
    end

    drop(index(:dpu_usage, [], name: "dpu_usage_unique_tally_index"))
    drop(constraint(:dpu_usage, :dpu_usage_reported_quantity_bounded))

    alter table(:dpu_usage) do
      remove(:dpu_reported_quantity)
    end
  end
end
