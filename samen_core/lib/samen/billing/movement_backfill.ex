defmodule Samen.Billing.MovementBackfill do
  @moduledoc """
  Day-one movement reconciliation (WS-B / G7; ADR-017 §4 "Backfill honesty").

  Movements only exist from the `SubscriptionMovement` change-hook FORWARD — a
  subscription that was created before the ledger existed has no `mov` row, so its
  MRR would not reconcile on day one. `from_snapshot/1` seeds ONE synthetic `:new`
  movement per currently-revenue-active subscription, so the opening MRR reconciles
  from install.

  ## Disclosed going-forward-only

  This is EXPLICITLY a going-forward reconciliation, NOT a fabricated history: it
  emits a single `:new` row per active sub with `reason: :backfill_snapshot` and
  `occurred_at = now` (or a supplied `:as_of`) — it does NOT invent the sub's true
  original signup date, upgrades, or downgrades (pre-install history is DISCLOSED
  absent, design §7). The `:backfill_snapshot` reason marks these rows so a reader
  can distinguish reconciliation seeds from captured movements.

  ## Idempotent

  A subscription that ALREADY has any `mov` row is skipped — running the backfill
  twice does not double-seed. Only revenue-active subscriptions
  (`:active | :trialing | :past_due`) with no prior movement are seeded; an inactive
  sub contributes 0 MRR and needs no seed.

  ## Usage (an install/upgrade one-shot, per host)

      Samen.Billing.MovementBackfill.from_snapshot(
        org_id: org.id,
        subscription_resource: Demo.BillingScope.Subscription,
        event_resource: Demo.BillingScope.SubscriptionEvent,
        price_resource: Demo.BillingScope.Price
      )
      # => {:ok, %{seeded: n, skipped: m, failed: f}}

  Returns a summary. A subscription whose existing-movement read or seed fails is NOT seeded (never a wrong-MRR
  seed), is counted in `failed` and reported (`write=movement_backfill_row`), and the run goes on, so one poison row
  can neither stop the backfill for good nor vanish silently; the run is safe to repeat and a re-run retries exactly
  those rows. `{:error, :unavailable}` (reported, never a zero summary) is only for a failed read of the snapshot itself
  (the prices or the active subscriptions).
  """

  require Ash.Query

  alias Samen.Billing.MovementClassifier

  @doc """
  Seed one synthetic `:new` movement per revenue-active subscription with no prior
  `mov` row, for the given org. Returns `{:ok, %{seeded:, skipped:, failed:}}` (`skipped`: already has a row;
  `failed`: unreadable or unseedable, reported) or `{:error, :unavailable}` when the snapshot itself cannot be read.

  Required opts:

    * `:org_id` — the org to backfill (scopes the read + the appended rows).
    * `:subscription_resource` — the host `Billing.Subscription` module.
    * `:event_resource` — the host `Billing.SubscriptionEvent` (`mov`) module.
    * `:price_resource` — the host `Billing.Price` module (MRR source).

  Optional:

    * `:as_of` — the `occurred_at` timestamp for seeded rows (default: now).
  """
  @spec from_snapshot(keyword()) ::
          {:ok, %{seeded: non_neg_integer(), skipped: non_neg_integer(), failed: non_neg_integer()}}
          | {:error, :unavailable}
  def from_snapshot(opts) do
    org_id = Keyword.fetch!(opts, :org_id) |> to_string()
    subscription_resource = Keyword.fetch!(opts, :subscription_resource)
    event_resource = Keyword.fetch!(opts, :event_resource)
    price_resource = Keyword.fetch!(opts, :price_resource)
    # T121: keep microsecond resolution on `occurred_at` (the ledger column is now
    # `:utc_datetime_usec`) so backfilled rows share the movement ledger's strict
    # total-order guarantee; truncating to :second would re-introduce tied keys.
    as_of = Keyword.get(opts, :as_of, DateTime.utc_now())

    snapshot(org_id, subscription_resource, event_resource, price_resource, as_of)
  end

  # A missing required opt raised above (a caller bug, never an outage); only a failed read of the snapshot is
  # `{:error, :unavailable}`.
  defp snapshot(org_id, subscription_resource, event_resource, price_resource, as_of) do
    prices_by_plan = monthly_prices_by_plan(price_resource, org_id)
    active = active_subscriptions(subscription_resource, org_id)

    {seeded, skipped, failed} =
      Enum.reduce(active, {0, 0, 0}, fn sub, {seeded, skipped, failed} ->
        case seed_one(event_resource, org_id, sub, prices_by_plan, as_of) do
          :seeded -> {seeded + 1, skipped, failed}
          :skipped -> {seeded, skipped + 1, failed}
          :failed -> {seeded, skipped, failed + 1}
        end
      end)

    {:ok, %{seeded: seeded, skipped: skipped, failed: failed}}
  rescue
    # ONE honest answer for a failed read of the snapshot itself (the price or the active-subscription read; neither
    # rescues on its own): `{:error, :unavailable}` and on record, never `{:ok, %{seeded: 0, skipped: 0}}` and never a
    # seed priced at 0 MRR because the price read failed. A failure confined to ONE subscription is handled per row
    # by `seed_one/5`.
    e ->
      Samen.Observability.Failure.report_write(:movement_backfill, org_id, e)
      {:error, :unavailable}
  end

  # One subscription: seed it, skip it (it already has a movement), or count it failed. A failure here is the
  # row's own (its movement read or its append), reported, and never stops the run.
  defp seed_one(event_resource, org_id, sub, prices_by_plan, as_of) do
    if has_movement?(event_resource, org_id, sub.id) do
      :skipped
    else
      :ok = seed_new(event_resource, org_id, sub, prices_by_plan, as_of)
      :seeded
    end
  rescue
    e ->
      Samen.Observability.Failure.report_write(:movement_backfill_row, org_id, e)
      :failed
  end

  defp active_subscriptions(subscription_resource, org_id) do
    active = MovementClassifier.active_statuses()

    subscription_resource
    |> Ash.Query.ensure_selected([:status, :plan_id, :customer_id, :org_id])
    |> Ash.Query.filter(org_id == ^org_id)
    |> Ash.Query.filter(status in ^active)
    |> Ash.read!(authorize?: false)
  end

  # Org-pinned (S15): the subscription is unique already, but the explicit org filter
  # makes the read a genuine tenant-scoped read the ReadScopeLint can prove.
  defp has_movement?(event_resource, org_id, subscription_id) do
    event_resource
    |> Ash.Query.filter(org_id == ^org_id and subscription_id == ^subscription_id)
    |> Ash.Query.limit(1)
    |> Ash.read!(authorize?: false)
    |> Enum.any?()
  end

  defp seed_new(event_resource, org_id, sub, prices_by_plan, as_of) do
    mrr = Map.get(prices_by_plan, sub.plan_id, 0)

    # Classify nil → active to get the canonical :new movement (delta = +mrr).
    {:ok, movement} =
      MovementClassifier.classify(nil, %{status: sub.status, mrr_cents: mrr}, prior_active?: false)

    event_resource
    |> Ash.Changeset.for_create(:append, %{
      org_id: org_id,
      subscription_id: sub.id,
      customer_id: Map.get(sub, :customer_id),
      plan_id: sub.plan_id,
      from_plan_id: nil,
      kind: movement.kind,
      mrr_delta_cents: movement.delta_cents,
      mrr_before_cents: movement.before_cents,
      mrr_after_cents: movement.after_cents,
      from_status: nil,
      to_status: sub.status,
      reason: :backfill_snapshot,
      occurred_at: as_of
    })
    |> Ash.create!(authorize?: false)

    :ok
  end

  # ADR-036 §4.5(1): Price.unit_amount_cents is now the Money attribute
  # Price.unit_amount — select it and extract minor units via
  # Samen.Type.Money.cents/1 so the downstream mrr_delta_cents math is unchanged.
  defp monthly_prices_by_plan(price_resource, org_id) do
    price_resource
    |> Ash.Query.ensure_selected([:plan_id, :unit_amount, :interval, :active, :org_id])
    |> Ash.Query.filter(org_id == ^org_id)
    |> Ash.Query.filter(interval == :monthly and active == true)
    |> Ash.read!(authorize?: false)
    |> Map.new(&{&1.plan_id, Samen.Type.Money.cents(&1.unit_amount)})
  end
end
