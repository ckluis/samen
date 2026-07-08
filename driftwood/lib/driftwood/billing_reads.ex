defmodule Driftwood.BillingReads do
  @moduledoc """
  The Billing read layer for the inherited Billing pages
  (/billing, /billing/invoices, /billing/plans).

  All reads go through Ash so OrgScope + vault masking apply. PII fields on
  `Driftwood.Billing.Customer` (billing_name / billing_email) are vault-routed
  scalar PII and are resolved through `Samen.Api.PiiResolution.resolve/4` —
  the same shared resolver used by `Driftwood.CrmReads.contacts/1`:

    * on `plane: :tenant` (the broker's own console) the org reads its OWN
      customers' billing_name/billing_email in CLEAR — no reveal grant needed
      (the tenant-as-owner rule; §external-surface :707);
    * on `plane: :operator` (impersonation or operator-key) the SAME fields
      render `%Masked{}` (→ ••••) by construction of the resolver.

  A scope without a plane resolves to the default masked posture (fail-safe).

  ## MASKING INVARIANT

  This module NEVER calls `Samen.Vault.reveal/3`, NEVER pattern-matches a
  vault token out of a `%Masked{}`, and NEVER introduces a "show plaintext"
  code path. Plaintext only reaches the LiveView if the PiiResolution resolver
  already resolved it through the shared chokepoint.
  """

  require Ash.Query

  @doc """
  Read all billing customers for the given scope with PII resolved.

  Returns a list of `Driftwood.Billing.Customer` structs with
  `billing_name` / `billing_email` plane-resolved:
    * tenant plane  → plaintext (the org reads its own customers in the clear)
    * operator plane → %Masked{} (••••) under impersonation
  """
  def customers(scope) do
    Driftwood.Billing.Customer
    |> Ash.Query.ensure_selected([:billing_name, :billing_email, :status, :currency, :custom])
    |> Ash.Query.sort(inserted_at: :asc)
    |> Ash.read!(scope: scope)
    |> resolve_customer_pii(scope)
  rescue
    _ -> []
  end

  @doc """
  Read all active billing subscriptions for the given scope, preloaded with
  their customer and plan. Non-PII (FKs only; customer PII lives on
  `billing_name`/`billing_email` resolved separately).

  Returns a list of `Driftwood.Billing.Subscription` structs each
  carrying a `__customer__` and `__plan__` field for display (loaded inline).
  """
  def subscriptions(scope) do
    subs =
      Driftwood.Billing.Subscription
      |> Ash.Query.ensure_selected([:status, :customer_id, :plan_id, :current_period_start, :current_period_end])
      |> Ash.Query.sort(inserted_at: :asc)
      |> Ash.read!(scope: scope)

    # Resolve customers (with PII) and plans in one pass.
    custs_by_id =
      customers(scope)
      |> Map.new(&{&1.id, &1})

    plans_by_id =
      plans(scope)
      |> Map.new(&{&1.id, &1})

    Enum.map(subs, fn sub ->
      sub
      |> Map.put(:__customer__, Map.get(custs_by_id, sub.customer_id))
      |> Map.put(:__plan__, Map.get(plans_by_id, sub.plan_id))
    end)
  rescue
    _ -> []
  end

  @doc """
  Read all billing invoices for the given scope. No PII on the invoice itself —
  the customer FK is an opaque UUID. The customer's billing_name is resolved
  separately and joined by customer_id.

  Returns a list of `Driftwood.Billing.Invoice` structs each carrying a
  `__customer__` field (with PII resolved per the scope's plane).
  """
  def invoices(scope) do
    invs =
      Driftwood.Billing.Invoice
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

    custs_by_id =
      customers(scope)
      |> Map.new(&{&1.id, &1})

    Enum.map(invs, fn inv ->
      Map.put(inv, :__customer__, Map.get(custs_by_id, inv.customer_id))
    end)
  rescue
    _ -> []
  end

  @doc """
  Read all Tier-0 billing plans with their prices for the given scope.

  Returns a list of `%{plan: Plan, prices: [Price]}` maps.
  Plans are non-PII config rows (admin-gated writes). No PII resolution needed.
  """
  def plans(scope) do
    Driftwood.Billing.Plan
    |> Ash.Query.ensure_selected([:name, :label, :description, :interval, :enabled, :features])
    |> Ash.Query.sort(inserted_at: :asc)
    |> Ash.read!(scope: scope)
  rescue
    _ -> []
  end

  @doc """
  Read plans with their associated prices (joined inline). Returns
  `[%{plan: plan, prices: [price]}]`.
  """
  def plans_with_prices(scope) do
    all_plans = plans(scope)

    prices =
      Driftwood.Billing.Price
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

  @doc """
  Billing metrics for the summary cards on /billing:
    * mrr_cents          — MRR = sum of active subscription plan prices (monthly)
    * active_subs        — count of active subscriptions
    * outstanding_cents  — sum of open invoice amount_due_cents
    * collected_cents    — sum of paid invoice amount_paid_cents (this month)

  All non-PII counts and sums. An error in one metric returns 0 for that metric.
  """
  def metrics(scope) do
    active_subs = count_active_subscriptions(scope)
    mrr_cents = compute_mrr(scope)
    {outstanding_cents, collected_cents} = invoice_amounts(scope)

    %{
      active_subs: active_subs,
      mrr_cents: mrr_cents,
      outstanding_cents: outstanding_cents,
      collected_cents: collected_cents
    }
  end

  # -- private -----------------------------------------------------------------

  # Resolve PII fields on Customer records through the shared tenant-plane resolver.
  # Fail-safe: on any resolver error the fields stay %Masked{} (no plaintext downgrade).
  defp resolve_customer_pii(records, scope) do
    Samen.Api.PiiResolution.resolve(
      records,
      Driftwood.Billing.Customer,
      actor_of(scope),
      repo: Driftwood.Repo
    )
  rescue
    _ -> records
  end

  defp actor_of(%Samen.Scope{actor: actor}), do: actor
  defp actor_of(actor) when is_map(actor), do: actor
  defp actor_of(_), do: %{}

  defp count_active_subscriptions(scope) do
    Driftwood.Billing.Subscription
    |> Ash.Query.filter(status == :active)
    |> Ash.count!(scope: scope)
  rescue
    _ -> 0
  end

  # MRR: sum the unit_amount_cents of the monthly price for active subscriptions.
  # We join subscriptions → plan → prices (monthly) to get a dollar amount.
  defp compute_mrr(scope) do
    subs =
      Driftwood.Billing.Subscription
      |> Ash.Query.ensure_selected([:status, :plan_id])
      |> Ash.Query.filter(status == :active)
      |> Ash.read!(scope: scope)

    prices =
      Driftwood.Billing.Price
      |> Ash.Query.ensure_selected([:plan_id, :unit_amount_cents, :interval])
      |> Ash.Query.filter(interval == :monthly and active == true)
      |> Ash.read!(scope: scope)
      |> Map.new(&{&1.plan_id, &1.unit_amount_cents})

    Enum.reduce(subs, 0, fn sub, acc ->
      acc + Map.get(prices, sub.plan_id, 0)
    end)
  rescue
    _ -> 0
  end

  # Returns {outstanding_cents, collected_cents_this_month}.
  defp invoice_amounts(scope) do
    invs =
      Driftwood.Billing.Invoice
      |> Ash.Query.ensure_selected([:status, :amount_due_cents, :amount_paid_cents, :paid_at])
      |> Ash.read!(scope: scope)

    now = DateTime.utc_now()
    month_start = %{now | day: 1, hour: 0, minute: 0, second: 0, microsecond: {0, 6}}

    Enum.reduce(invs, {0, 0}, fn inv, {out, coll} ->
      outstanding =
        if inv.status in [:open, :draft] do
          out + (inv.amount_due_cents || 0)
        else
          out
        end

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

  defp paid_this_month?(%DateTime{} = paid_at, month_start) do
    DateTime.compare(paid_at, month_start) != :lt
  end

  defp paid_this_month?(_other, _), do: false
end
