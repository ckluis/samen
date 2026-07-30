defmodule Samen.Billing.SubscriptionMovement do
  @moduledoc """
  An Ash change that appends ONE `Billing.SubscriptionEvent` (`mov`) row per
  subscription create/update — the subscription-movement capture seam (WS-B / G7;
  ADR-017 §2), modeled on the proven `Samen.Notifications.StatusChange` seam that
  `Invoice` already uses.

  Attached by the `Billing.Subscription` blueprint as:

      change({Samen.Billing.SubscriptionMovement,
        event_resource: Demo.BillingScope.SubscriptionEvent,
        plan_resource: Demo.BillingScope.Plan,
        price_resource: Demo.BillingScope.Price})

  ## Bulk writes (B1 gate note)

  This change runs `after_action`, which forces a NON-atomic strategy: an
  `Ash.bulk_update` on Subscription under the default `:atomic` strategy fails
  closed (`{:error, ...}`, no rows written, no movement missed). Bulk
  subscription mutations must pass an explicit `strategy: :stream` (or
  `:atomic_batches`) — those paths both write AND capture the movement.

  ## Semantics

    * Fires on every subscription create/update, in an `after_action` hook.
    * Resolves the subscription's contributed MRR BEFORE and AFTER the write:
      `mrr_cents = monthly active price of the plan` when the state is revenue-active
      (`:active | :trialing | :past_due`), else `0`. The BEFORE state comes from the
      changeset's original data (an update) or is `nil` (a create).
    * Classifies `(before, after)` via the pure `Samen.Billing.MovementClassifier`
      → a bounded `kind` + signed `mrr_delta_cents` + before/after cents.
    * Appends one `mov` row with those values + the from/to status pair + the plan
      refs + `occurred_at`. A `:reactivation` is distinguished from `:new` by whether
      a prior movement row shows this subscription was ever revenue-active.

  ## Best-effort by contract (the A4 emit pattern)

  This is BEST-EFFORT, exactly like `StatusChange` → `Engine.emit/1`: an append
  failure (event resource unwired, DB hiccup, unresolvable org) NEVER aborts the
  primary subscription write. The subscription state is the load-bearing fact; the
  `mov` row rides alongside. All work is wrapped so nothing here can raise into the
  transaction result.

  A `:noop` movement (no revenue change — e.g. a `past_due → active` cure at the same
  price, or a metadata-only update) is STILL recorded as a `:noop` row, so the ledger
  is a complete audit trail of every subscription mutation; the reconciliation sum is
  unaffected (`:noop` delta is 0).

  ## PII discipline

  Every value written is a bounded id (uuid), an enum, a signed integer, or a
  timestamp. No subject PII enters a `mov` row by construction (the resource carries
  no PII columns; ADR-017 §3).
  """
  use Ash.Resource.Change

  require Ash.Query

  alias Samen.Billing.MovementClassifier

  @impl true
  def change(changeset, opts, _context) do
    Ash.Changeset.after_action(changeset, fn changeset, record ->
      maybe_append(changeset, record, opts)
      {:ok, record}
    end)
  end

  # Best-effort append. Nothing here may abort the primary write.
  defp maybe_append(changeset, record, opts) do
    event_resource = Keyword.fetch!(opts, :event_resource)
    price_resource = Keyword.get(opts, :price_resource)

    org_id = org_id_of(changeset, record)

    if is_binary(org_id) do
      prices_by_plan = monthly_prices_by_plan(price_resource, org_id)

      after_state = state_of(record.status, record.plan_id, prices_by_plan)
      before_state = before_state_of(changeset, prices_by_plan)

      from_plan_id = changeset_original(changeset, :plan_id)
      prior_active? = prior_active?(event_resource, record.id, org_id)

      case MovementClassifier.classify(before_state, after_state, prior_active?: prior_active?) do
        {:ok, movement} ->
          append_row(event_resource, org_id, record, movement, before_state, after_state,
            from_plan_id: from_plan_id,
            reason: reason_for(before_state, after_state)
          )

        {:error, _reason} ->
          :ok
      end
    end

    :ok
  rescue
    # Best-effort belt: introspection/classification/append never aborts the write.
    _ -> :ok
  catch
    _, _ -> :ok
  end

  # Resolve the subscription's contributed MRR for a {status, plan_id} — the plan's
  # monthly active price when revenue-active, else 0. Returns a classifier state map.
  defp state_of(status, plan_id, prices_by_plan) do
    mrr =
      if status in MovementClassifier.active_statuses() do
        Map.get(prices_by_plan, plan_id, 0)
      else
        0
      end

    %{status: status, mrr_cents: mrr}
  end

  # The BEFORE state: from the changeset's original record (an update) or nil (create).
  defp before_state_of(changeset, prices_by_plan) do
    case changeset.action_type do
      :create ->
        nil

      _ ->
        old_status = changeset_original(changeset, :status)
        old_plan_id = changeset_original(changeset, :plan_id)

        if is_nil(old_status) do
          nil
        else
          state_of(old_status, old_plan_id, prices_by_plan)
        end
    end
  end

  # Read an attribute's ORIGINAL (pre-change) value from the changeset data.
  defp changeset_original(changeset, key) do
    case changeset.data do
      %{^key => %Ash.NotLoaded{}} -> nil
      %{^key => value} -> value
      _ -> nil
    end
  end

  # Was this subscription EVER revenue-active before (any prior mov row that moved it
  # onto the book)? Distinguishes :reactivation from :new.
  defp prior_active?(event_resource, subscription_id, _org_id) do
    event_resource
    |> Ash.Query.filter(subscription_id == ^subscription_id)
    |> Ash.Query.filter(kind in [:new, :reactivation])
    |> Ash.Query.limit(1)
    |> Ash.read!(authorize?: false)
    |> case do
      [] -> false
      _ -> true
    end
  rescue
    _ -> false
  end

  # Monthly active prices keyed by plan_id, for this org — the MRR source.
  defp monthly_prices_by_plan(nil, _org_id), do: %{}

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
  rescue
    _ -> %{}
  end

  # A price/plan change while active is a :price_change reason; else a status change.
  defp reason_for(before_state, after_state) do
    cond do
      is_nil(before_state) ->
        :status_change

      MovementClassifier.active?(before_state) and MovementClassifier.active?(after_state) ->
        :price_change

      true ->
        :status_change
    end
  end

  defp append_row(event_resource, org_id, record, movement, before_state, after_state, extra) do
    event_resource
    |> Ash.Changeset.for_create(:append, %{
      org_id: org_id,
      subscription_id: record.id,
      customer_id: Map.get(record, :customer_id),
      plan_id: Map.get(record, :plan_id),
      from_plan_id: Keyword.get(extra, :from_plan_id),
      kind: movement.kind,
      mrr_delta_cents: movement.delta_cents,
      mrr_before_cents: movement.before_cents,
      mrr_after_cents: movement.after_cents,
      from_status: status_of(before_state),
      to_status: status_of(after_state),
      reason: Keyword.get(extra, :reason, :status_change),
      # T121: microsecond `occurred_at` (NOT truncated to :second) so movements
      # appended within the same wall-clock second carry distinct business-time
      # instants — the ledger read (`occurred_at` ordering) is then a strict total
      # order that respects chronology. Truncating here would collapse a rapid
      # lifecycle's movements to one tied key and re-introduce the non-total sort.
      occurred_at: DateTime.utc_now()
    })
    |> Ash.create!(authorize?: false)

    :ok
  rescue
    _ -> :ok
  end

  defp status_of(nil), do: nil
  defp status_of(%{status: status}), do: status

  # The owning org id — from the changeset attributes, the returned record, or (an
  # update whose loaded struct deselected org_id) a narrow re-select by primary key.
  # `nil` (unresolvable) skips the append rather than failing the write. Mirrors the
  # StatusChange org resolution.
  defp org_id_of(changeset, record) do
    Enum.find_value(
      [
        fn -> Ash.Changeset.get_attribute(changeset, :org_id) end,
        fn -> Map.get(record, :org_id) end,
        fn ->
          record.__struct__
          |> Ash.Query.ensure_selected([:org_id])
          |> Ash.Query.filter(id == ^record.id)
          |> Ash.read_one!(authorize?: false)
          |> Map.get(:org_id)
        end
      ],
      fn resolve ->
        case resolve.() do
          %Ash.NotLoaded{} -> nil
          nil -> nil
          value -> to_string(value)
        end
      end
    )
  rescue
    _ -> nil
  end
end
