defmodule Samen.WebTest.Repo.Migrations.UsageTallyReportedQuantity do
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

  @resources [Samen.WebTest.Billing.Usage, Samen.WebTest.Operator.Usage]

  def up do
    alter table(:wbu_usage) do
      add(:wbu_reported_quantity, :integer, null: false, default: 0)
    end

    create(constraint(:wbu_usage, :wbu_usage_reported_quantity_bounded,
      check: "wbu_reported_quantity >= 0 AND wbu_reported_quantity <= wbu_quantity"
    ))

    create(
      unique_index(:wbu_usage, [:wbu_org_id, :wbu_subscription_id, :wbu_metric, :wbu_period_start],
        name: "wbu_usage_unique_tally_index"
      )
    )

    alter table(:wpu_usage) do
      add(:wpu_reported_quantity, :integer, null: false, default: 0)
    end

    create(constraint(:wpu_usage, :wpu_usage_reported_quantity_bounded,
      check: "wpu_reported_quantity >= 0 AND wpu_reported_quantity <= wpu_quantity"
    ))

    create(
      unique_index(:wpu_usage, [:wpu_org_id, :wpu_subscription_id, :wpu_metric, :wpu_period_start],
        name: "wpu_usage_unique_tally_index"
      )
    )

    catalog_sync(@resources, only: [:reported_quantity])
  end

  def down do
    catalog_sync_down(@resources, only: [:reported_quantity])

    drop(index(:wbu_usage, [], name: "wbu_usage_unique_tally_index"))
    drop(constraint(:wbu_usage, :wbu_usage_reported_quantity_bounded))

    alter table(:wbu_usage) do
      remove(:wbu_reported_quantity)
    end

    drop(index(:wpu_usage, [], name: "wpu_usage_unique_tally_index"))
    drop(constraint(:wpu_usage, :wpu_usage_reported_quantity_bounded))

    alter table(:wpu_usage) do
      remove(:wpu_reported_quantity)
    end
  end
end
