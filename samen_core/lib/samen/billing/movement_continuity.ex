defmodule Samen.Billing.MovementContinuity do
  @moduledoc """
  The `mov` ledger-continuity check (kernel phase C review, S4).

  `Samen.Billing.SubscriptionMovement` is best-effort: when a price or prior-movement read, the
  classifier or the append fails, NO row is written and the only record is a failure report. A
  deterministic failure therefore drops every later movement, and nothing else notices. The ledger
  already carries the means to notice — every row holds `mrr_before_cents` and `mrr_after_cents` —
  so a skipped movement shows as a broken chain. This module reads the ledger and reports it.

  For each subscription, its rows in the ledger's total order (`inserted_at`, `occurred_at`, `id`):

    * `chain_break` — a row's `mrr_before_cents` is not the previous row's `mrr_after_cents`
    * `bad_origin` — the first row does not start from 0 (a `:new` and a `:backfill_snapshot` seed both do)
    * `stale_tail` — the last `mrr_after_cents` is not the subscription's current MRR (its monthly active
      price when revenue-active, else 0), the tail of a skipped latest movement. A price edited outside a
      subscription write also lands here: that revenue change is not in the ledger either
    * `unseeded` — a revenue-active subscription with no row at all (a skipped create), repaired by
      `Samen.Billing.MovementBackfill.from_snapshot/1`

  `violations/1` returns value-free strings (the subscription id, the class and the position or the two
  amounts of cents — never a name or a customer). It reads; it repairs nothing. A failed read raises, so
  the verifier cannot pass over a ledger it could not read.

  Required opts: `:subscription_resource`, `:event_resource`, `:price_resource`. Optional: `:org_id`
  (default: every org).
  """

  require Ash.Query

  alias Samen.Billing.MovementClassifier

  @spec violations(keyword()) :: [String.t()]
  def violations(opts) do
    subscription_resource = Keyword.fetch!(opts, :subscription_resource)
    event_resource = Keyword.fetch!(opts, :event_resource)
    price_resource = Keyword.fetch!(opts, :price_resource)
    org_id = Keyword.get(opts, :org_id)

    prices = prices_by_org_plan(price_resource, org_id)
    rows = rows_by_subscription(event_resource, org_id)

    subscription_resource
    |> read_subscriptions(org_id)
    |> Enum.flat_map(fn sub ->
      current = current_mrr(sub, prices)
      check(sub.id, Map.get(rows, sub.id, []), current)
    end)
    |> Enum.sort()
  end

  # The pure chain check for one subscription: `rows` in ledger order, `current` its live MRR.
  @doc false
  def check(id, [], current) when current > 0,
    do: ["subscription #{id}: unseeded (revenue-active at #{current} cents, no ledger row)"]

  def check(_id, [], _current), do: []

  def check(id, [first | _] = rows, current) do
    origin = if first.mrr_before_cents == 0, do: [], else: ["subscription #{id}: bad_origin (first row starts from #{first.mrr_before_cents} cents)"]

    breaks =
      rows
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {[prev, next], i} ->
        if next.mrr_before_cents == prev.mrr_after_cents,
          do: [],
          else: ["subscription #{id}: chain_break at row #{i + 1} (before #{next.mrr_before_cents} != previous after #{prev.mrr_after_cents})"]
      end)

    last = List.last(rows)

    tail =
      if last.mrr_after_cents == current,
        do: [],
        else: ["subscription #{id}: stale_tail (ledger ends at #{last.mrr_after_cents} cents, current MRR #{current})"]

    origin ++ breaks ++ tail
  end

  # Ledger rows whose subscription no longer exists are history, not a violation (the ledger outlives the
  # mutable subscription): only subscriptions that exist are walked, so such rows are not reported.

  defp current_mrr(sub, prices) do
    if sub.status in MovementClassifier.active_statuses(),
      do: Map.get(prices, {sub.org_id, sub.plan_id}, 0),
      else: 0
  end

  defp read_subscriptions(resource, org_id) do
    resource
    |> Ash.Query.ensure_selected([:status, :plan_id, :org_id])
    |> scope_org(org_id)
    |> Ash.read!(authorize?: false)
  end

  defp rows_by_subscription(event_resource, org_id) do
    event_resource
    |> Ash.Query.ensure_selected([:subscription_id, :mrr_before_cents, :mrr_after_cents, :occurred_at, :inserted_at, :org_id])
    |> scope_org(org_id)
    |> Ash.Query.sort(inserted_at: :asc, occurred_at: :asc, id: :asc)
    |> Ash.read!(authorize?: false)
    |> Enum.group_by(& &1.subscription_id)
  end

  defp prices_by_org_plan(price_resource, org_id) do
    price_resource
    |> Ash.Query.ensure_selected([:plan_id, :unit_amount, :interval, :active, :org_id])
    |> Ash.Query.filter(interval == :monthly and active == true)
    |> scope_org(org_id)
    |> Ash.read!(authorize?: false)
    |> Map.new(&{{&1.org_id, &1.plan_id}, Samen.Type.Money.cents(&1.unit_amount)})
  end

  defp scope_org(query, nil), do: query
  defp scope_org(query, org_id), do: Ash.Query.filter(query, org_id == ^org_id)
end
