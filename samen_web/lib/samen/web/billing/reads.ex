defmodule Samen.Web.Billing.Reads do
  @moduledoc """
  The framework Billing read layer for the inherited Billing pages
  (overview, invoices, plans).

  Promoted from the driftwood-local `Driftwood.BillingReads` (ADR-009 §3.3): resource +
  repo come from `Samen.Web.Mount`, so the SAME code reads Driftwood's Billing inside
  Driftwood and PawChart's Billing inside PawChart. PII fields on the Billing `Customer`
  (billing_name / billing_email) are resolved through `Samen.Api.PiiResolution.resolve/4`:

    * `plane: :tenant`  → CLEAR (the org reads its own customers);
    * `plane: :operator` → `%Masked{}` (→ ••••) by construction.

  ## MASKING INVARIANT

  Never calls `Samen.Vault.reveal/3`, never unwraps a `%Masked{}`, never has a
  "show plaintext" branch. Plaintext only reaches the LiveView if the resolver resolved
  it through the shared chokepoint.
  """

  require Ash.Query

  alias Samen.Web.Mount

  @doc "Read billing customers for `scope` with billing_name/billing_email plane-resolved."
  def customers(mount, scope) do
    Mount.resource(mount, Customer)
    |> Ash.Query.ensure_selected([:billing_name, :billing_email, :status, :currency, :custom])
    |> Ash.Query.sort(inserted_at: :asc)
    |> Ash.read!(scope: scope)
    |> resolve_pii(mount, Customer, scope)
  rescue
    _ -> []
  end

  @doc "Read active subscriptions for `scope`, joined to their (PII-resolved) customer + plan."
  def subscriptions(mount, scope) do
    subs =
      Mount.resource(mount, Subscription)
      |> Ash.Query.ensure_selected([:status, :customer_id, :plan_id, :current_period_start, :current_period_end])
      |> Ash.Query.sort(inserted_at: :asc)
      |> Ash.read!(scope: scope)

    custs_by_id = customers(mount, scope) |> Map.new(&{&1.id, &1})
    plans_by_id = plans(mount, scope) |> Map.new(&{&1.id, &1})

    Enum.map(subs, fn sub ->
      sub
      |> Map.put(:__customer__, Map.get(custs_by_id, sub.customer_id))
      |> Map.put(:__plan__, Map.get(plans_by_id, sub.plan_id))
    end)
  rescue
    _ -> []
  end

  @doc "Read billing invoices for `scope`, each joined to its PII-resolved customer."
  def invoices(mount, scope) do
    invs =
      Mount.resource(mount, Invoice)
      |> Ash.Query.ensure_selected([
        :status,
        :amount_due_cents,
        :amount_paid_cents,
        :currency,
        :due_date,
        :paid_at,
        :customer_id,
        :subscription_id
      ])
      |> Ash.Query.sort(inserted_at: :asc)
      |> Ash.read!(scope: scope)

    custs_by_id = customers(mount, scope) |> Map.new(&{&1.id, &1})

    Enum.map(invs, fn inv ->
      Map.put(inv, :__customer__, Map.get(custs_by_id, inv.customer_id))
    end)
  rescue
    _ -> []
  end

  @doc "Read Tier-0 billing plans for `scope`. Non-PII config rows."
  def plans(mount, scope) do
    Mount.resource(mount, Plan)
    |> Ash.Query.ensure_selected([:name, :label, :description, :interval, :enabled, :features])
    |> Ash.Query.sort(inserted_at: :asc)
    |> Ash.read!(scope: scope)
  rescue
    _ -> []
  end

  @doc "Read plans with their prices joined: `[%{plan: plan, prices: [price]}]`."
  def plans_with_prices(mount, scope) do
    all_plans = plans(mount, scope)

    prices =
      Mount.resource(mount, Price)
      |> Ash.Query.ensure_selected([:plan_id, :unit_amount_cents, :currency, :interval, :active])
      |> Ash.Query.sort(unit_amount_cents: :asc)
      |> Ash.read!(scope: scope)
      |> Enum.group_by(& &1.plan_id)

    Enum.map(all_plans, fn plan ->
      %{plan: plan, prices: Map.get(prices, plan.id, [])}
    end)
  rescue
    _ -> []
  end

  @doc "Non-PII billing metrics (mrr_cents, active_subs, outstanding_cents, collected_cents)."
  def metrics(mount, scope) do
    active_subs = count_active_subscriptions(mount, scope)
    mrr_cents = compute_mrr(mount, scope)
    {outstanding_cents, collected_cents} = invoice_amounts(mount, scope)

    %{
      active_subs: active_subs,
      mrr_cents: mrr_cents,
      outstanding_cents: outstanding_cents,
      collected_cents: collected_cents
    }
  end

  # -- private -----------------------------------------------------------------

  defp resolve_pii(records, mount, name, scope) do
    Samen.Api.PiiResolution.resolve(
      records,
      Mount.resource(mount, name),
      actor_of(scope),
      repo: mount.repo
    )
  rescue
    _ -> records
  end

  defp actor_of(%Samen.Scope{actor: actor}), do: actor
  defp actor_of(actor) when is_map(actor), do: actor
  defp actor_of(_), do: %{}

  defp count_active_subscriptions(mount, scope) do
    Mount.resource(mount, Subscription)
    |> Ash.Query.filter(status == :active)
    |> Ash.count!(scope: scope)
  rescue
    _ -> 0
  end

  defp compute_mrr(mount, scope) do
    subs =
      Mount.resource(mount, Subscription)
      |> Ash.Query.ensure_selected([:status, :plan_id])
      |> Ash.Query.filter(status == :active)
      |> Ash.read!(scope: scope)

    prices =
      Mount.resource(mount, Price)
      |> Ash.Query.ensure_selected([:plan_id, :unit_amount_cents, :interval])
      |> Ash.Query.filter(interval == :monthly and active == true)
      |> Ash.read!(scope: scope)
      |> Map.new(&{&1.plan_id, &1.unit_amount_cents})

    Enum.reduce(subs, 0, fn sub, acc -> acc + Map.get(prices, sub.plan_id, 0) end)
  rescue
    _ -> 0
  end

  defp invoice_amounts(mount, scope) do
    invs =
      Mount.resource(mount, Invoice)
      |> Ash.Query.ensure_selected([:status, :amount_due_cents, :amount_paid_cents, :paid_at])
      |> Ash.read!(scope: scope)

    now = DateTime.utc_now()
    month_start = %{now | day: 1, hour: 0, minute: 0, second: 0, microsecond: {0, 6}}

    Enum.reduce(invs, {0, 0}, fn inv, {out, coll} ->
      outstanding =
        if inv.status in [:open, :draft], do: out + (inv.amount_due_cents || 0), else: out

      collected =
        if inv.status == :paid and paid_this_month?(inv.paid_at, month_start) do
          coll + (inv.amount_paid_cents || 0)
        else
          coll
        end

      {outstanding, collected}
    end)
  rescue
    _ -> {0, 0}
  end

  defp paid_this_month?(nil, _month_start), do: false

  defp paid_this_month?(%DateTime{} = paid_at, month_start),
    do: DateTime.compare(paid_at, month_start) != :lt

  defp paid_this_month?(_other, _), do: false
end
