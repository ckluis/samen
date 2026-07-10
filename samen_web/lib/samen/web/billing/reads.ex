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

  ## A3 read-bounding (WS-A design §1.1 "read! elimination")

  Every list page reads through a `*_page/3` built on `Samen.Web.Reads.page!/3`
  (BOUNDED BY CONSTRUCTION — `limit(page_size + 1)`, hostile page sizes clamped);
  every remaining lookup/join read carries an explicit `limit(#{200})`. Metrics are
  DB aggregates (`Ash.count`/`Ash.sum`) — no row set is transferred, bounded by
  construction.

  ## A3 write side (sanctioned domain actions only)

  The billing blueprint defines `defaults([:read, :destroy, create: :*, update: :*])`
  on every resource; this module only exposes those. Plan / Price / Invoice /
  Subscription writes are ADMIN-gated by the kernel (`RoleAtLeast :admin`), so the
  tenant-plane write path uses `write_scope/2` — a same-org role elevation that
  PRESERVES the plane marker (see the function doc; the elevation can never bypass
  `Samen.Pii.WriteGuard`). Customer writes are member-gated and use the plain scope.

  ## MASKING INVARIANT

  Never calls `Samen.Vault.reveal/3`, never unwraps a `%Masked{}`, never has a
  "show plaintext" branch. Plaintext only reaches the LiveView if the resolver resolved
  it through the shared chokepoint.
  """

  require Ash.Query

  alias Samen.Web.Mount

  # Bounded lookup reads (form selects, join maps). Single-org fan-outs, not hot lists.
  @detail_limit 200

  @doc """
  Read billing customers for `scope` with billing_name/billing_email plane-resolved.
  BOUNDED to #{@detail_limit} rows (A3 read-bounding) — this is the lookup read (the
  invoice form's customer select / the subscription list's customer-name join).
  """
  def customers(mount, scope) do
    Mount.resource(mount, Customer)
    |> Ash.Query.ensure_selected([:billing_name, :billing_email, :status, :currency, :custom])
    |> Ash.Query.sort(inserted_at: :asc)
    |> Ash.Query.limit(@detail_limit)
    |> Ash.read!(scope: scope)
    |> resolve_pii(mount, Customer, scope)
  rescue
    _ -> []
  end

  @doc """
  Read active subscriptions for `scope`, joined to their (PII-resolved) customer + plan.
  BOUNDED to #{@detail_limit} rows; the Overview page itself reads through the
  paginated `subscriptions_page/3`.
  """
  def subscriptions(mount, scope) do
    subs =
      Mount.resource(mount, Subscription)
      |> Ash.Query.ensure_selected([:status, :customer_id, :plan_id, :current_period_start, :current_period_end])
      |> Ash.Query.sort(inserted_at: :asc)
      |> Ash.Query.limit(@detail_limit)
      |> Ash.read!(scope: scope)

    join_subscriptions(subs, mount, scope)
  rescue
    _ -> []
  end

  @doc """
  Read ONE keyset page of subscriptions for `scope` — the `ListLive` reads contract
  (`(mount, scope, %ListState{}) -> %Page{}`, ADR-016 §3), built on
  `Samen.Web.Reads.page!/3` so the read is BOUNDED BY CONSTRUCTION. Each item is
  joined to its customer (PII plane-resolved: tenant clear / operator ••••) + plan
  AFTER paging. Sort fields are bounded, non-vaulted attributes. On any read error
  the page is EMPTY — never unbounded, never a plaintext downgrade.
  """
  def subscriptions_page(mount, scope, state) do
    page =
      Mount.resource(mount, Subscription)
      |> Ash.Query.ensure_selected([
        :status,
        :customer_id,
        :plan_id,
        :current_period_start,
        :current_period_end
      ])
      |> Samen.Web.Reads.page!(state, scope: scope, filter_fields: [])

    %{page | items: join_subscriptions(page.items, mount, scope)}
  rescue
    _ -> %Samen.Web.Page{items: [], page_size: Samen.Web.Reads.bounded_page_size(state.page_size)}
  end

  @doc """
  Read billing invoices for `scope`, each joined to its PII-resolved customer.
  BOUNDED to #{@detail_limit} rows; the Invoices page itself reads through the
  paginated `invoices_page/3`.
  """
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
      |> Ash.Query.limit(@detail_limit)
      |> Ash.read!(scope: scope)

    join_invoices(invs, mount, scope)
  rescue
    _ -> []
  end

  @doc """
  Read ONE keyset page of invoices for `scope` — the `ListLive` reads contract, built
  on `Samen.Web.Reads.page!/3` (BOUNDED BY CONSTRUCTION). The invoice carries no PII;
  the joined customer's billing_name is plane-resolved AFTER paging (tenant clear /
  operator ••••). On any read error the page is EMPTY.
  """
  def invoices_page(mount, scope, state) do
    page =
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
      |> Samen.Web.Reads.page!(state, scope: scope, filter_fields: [:currency])

    %{page | items: join_invoices(page.items, mount, scope)}
  rescue
    _ -> %Samen.Web.Page{items: [], page_size: Samen.Web.Reads.bounded_page_size(state.page_size)}
  end

  @doc """
  Read Tier-0 billing plans for `scope`. Non-PII config rows. BOUNDED to
  #{@detail_limit} rows; the Plans page itself reads through `plans_page/3`.
  """
  def plans(mount, scope) do
    Mount.resource(mount, Plan)
    |> Ash.Query.ensure_selected([:name, :label, :description, :interval, :enabled, :features])
    |> Ash.Query.sort(inserted_at: :asc)
    |> Ash.Query.limit(@detail_limit)
    |> Ash.read!(scope: scope)
  rescue
    _ -> []
  end

  @doc """
  Read ONE keyset page of billing plans for `scope` — the `ListLive` reads contract,
  built on `Samen.Web.Reads.page!/3` (BOUNDED BY CONSTRUCTION). Plans are non-PII
  Tier-0 config rows; sort/filter fields are bounded plain attributes. On any read
  error the page is EMPTY.
  """
  def plans_page(mount, scope, state) do
    Mount.resource(mount, Plan)
    |> Ash.Query.ensure_selected([:name, :label, :description, :interval, :enabled, :features])
    |> Samen.Web.Reads.page!(state, scope: scope, filter_fields: [:name, :label])
  rescue
    _ -> %Samen.Web.Page{items: [], page_size: Samen.Web.Reads.bounded_page_size(state.page_size)}
  end

  @doc "Read plans with their prices joined: `[%{plan: plan, prices: [price]}]`. BOUNDED."
  def plans_with_prices(mount, scope) do
    all_plans = plans(mount, scope)
    prices = prices_by_plan(mount, scope)

    Enum.map(all_plans, fn plan ->
      %{plan: plan, prices: Map.get(prices, plan.id, [])}
    end)
  rescue
    _ -> []
  end

  @doc "plan_id → [price] map (non-PII config rows, BOUNDED) for joining prices to a plan page."
  def prices_by_plan(mount, scope) do
    Mount.resource(mount, Price)
    |> Ash.Query.ensure_selected([:plan_id, :unit_amount_cents, :currency, :interval, :active])
    |> Ash.Query.sort(unit_amount_cents: :asc)
    |> Ash.Query.limit(@detail_limit)
    |> Ash.read!(scope: scope)
    |> Enum.group_by(& &1.plan_id)
  rescue
    _ -> %{}
  end

  @doc """
  Non-PII billing metrics (mrr_cents, active_subs, outstanding_cents, collected_cents).
  Computed as DB aggregates (`Ash.count`/`Ash.sum`) — no row set is transferred, so the
  read is bounded by construction (A3 read-bounding: this replaced unbounded
  subscription/invoice `read!`s).
  """
  def metrics(mount, scope) do
    %{
      active_subs: count_active_subscriptions(mount, scope),
      mrr_cents: compute_mrr(mount, scope),
      outstanding_cents: outstanding_cents(mount, scope),
      collected_cents: collected_cents(mount, scope)
    }
  end

  @doc """
  Non-PII invoice metrics for the Invoices page cards — count / paid / overdue /
  outstanding_cents, all DB aggregates (bounded by construction).
  """
  def invoice_metrics(mount, scope) do
    now = DateTime.utc_now()

    %{
      count: count_resource(Mount.resource(mount, Invoice), scope),
      paid:
        Mount.resource(mount, Invoice)
        |> Ash.Query.filter(status == :paid)
        |> count_resource(scope),
      overdue:
        Mount.resource(mount, Invoice)
        |> Ash.Query.filter(status == :open and due_date < ^now)
        |> count_resource(scope),
      outstanding_cents: outstanding_cents(mount, scope)
    }
  end

  # -- A3 write side (sanctioned defaults only) ---------------------------------

  @doc """
  The tenant-ADMIN write scope for the kernel's admin-gated Billing config writes
  (Plan / Price / Invoice / Subscription carry `RoleAtLeast :admin`; the mount's
  plane scope is a `:member`, per `Samen.Web.Plane.scope/2`).

  Same-org role elevation ONLY — the chat-disclosure precedent (`Samen.Web.Chat`),
  with one hardening: the elevation PRESERVES every plane marker (`plane`, `kind`,
  `impersonation`) from `Mount.scope/2`. An operator-plane mount elevated here still
  carries `plane: :operator`, so `Samen.Pii.WriteGuard` (MC-1 / Invariant L1) rejects
  a vaulted-PII write exactly as before — the elevation raises RBAC rank, never the
  masking plane. `OrgScope` still confines the write to `org_id`.
  """
  def write_scope(mount, org_id) do
    %Samen.Scope{actor: actor} = Mount.scope(mount, org_id)
    %Samen.Scope{actor: Map.put(actor, :role, :admin)}
  end

  @doc "Destroy one billing plan for `scope` (A3 CRUD wiring). `:ok` or `{:error, reason}`."
  def delete_plan(mount, scope, id), do: delete_record(mount, scope, Plan, id)

  @doc "Destroy one invoice for `scope` (A3 CRUD wiring). `:ok` or `{:error, reason}`."
  def delete_invoice(mount, scope, id), do: delete_record(mount, scope, Invoice, id)

  @doc "Destroy one subscription for `scope` (A3 CRUD wiring). `:ok` or `{:error, reason}`."
  def delete_subscription(mount, scope, id), do: delete_record(mount, scope, Subscription, id)

  @doc """
  Toggle a plan's `enabled` flag (the "plan change" edit — the blueprint's sanctioned
  `update: :*`). Goes through Ash so OrgScope + the admin role gate apply; this module
  adds NO policy of its own. `{:ok, plan}` or `{:error, reason}`.
  """
  def toggle_plan(mount, scope, id) do
    record =
      Mount.resource(mount, Plan)
      |> Ash.Query.filter(id == ^id)
      |> Ash.Query.limit(1)
      |> Ash.read_one!(scope: scope)

    case record do
      nil ->
        {:error, :not_found}

      plan ->
        plan
        |> Ash.Changeset.for_update(:update, %{enabled: !plan.enabled}, scope: scope)
        |> Ash.update()
    end
  rescue
    e -> {:error, e}
  end

  # -- private -----------------------------------------------------------------

  defp delete_record(mount, scope, name, id) do
    record =
      Mount.resource(mount, name)
      |> Ash.Query.filter(id == ^id)
      |> Ash.Query.limit(1)
      |> Ash.read_one!(scope: scope)

    case record do
      nil -> {:error, :not_found}
      record -> Ash.destroy(record, scope: scope)
    end
  rescue
    e -> {:error, e}
  end

  defp join_subscriptions(subs, mount, scope) do
    custs_by_id = customers(mount, scope) |> Map.new(&{&1.id, &1})
    plans_by_id = plans(mount, scope) |> Map.new(&{&1.id, &1})

    Enum.map(subs, fn sub ->
      sub
      |> Map.put(:__customer__, Map.get(custs_by_id, sub.customer_id))
      |> Map.put(:__plan__, Map.get(plans_by_id, sub.plan_id))
    end)
  end

  defp join_invoices(invs, mount, scope) do
    custs_by_id = customers(mount, scope) |> Map.new(&{&1.id, &1})

    Enum.map(invs, fn inv ->
      Map.put(inv, :__customer__, Map.get(custs_by_id, inv.customer_id))
    end)
  end

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
    |> count_resource(scope)
  end

  # MRR = Σ over active monthly prices of (active-sub count on that plan × unit amount).
  # The price read is a bounded config read (≤ @detail_limit rows); the sub side is a
  # DB COUNT per plan — no subscription row set is ever transferred.
  defp compute_mrr(mount, scope) do
    Mount.resource(mount, Price)
    |> Ash.Query.ensure_selected([:plan_id, :unit_amount_cents, :interval])
    |> Ash.Query.filter(interval == :monthly and active == true)
    |> Ash.Query.limit(@detail_limit)
    |> Ash.read!(scope: scope)
    |> Enum.reduce(0, fn price, acc ->
      subs_on_plan =
        Mount.resource(mount, Subscription)
        |> Ash.Query.filter(status == :active and plan_id == ^price.plan_id)
        |> count_resource(scope)

      acc + subs_on_plan * (price.unit_amount_cents || 0)
    end)
  rescue
    _ -> 0
  end

  defp outstanding_cents(mount, scope) do
    Mount.resource(mount, Invoice)
    |> Ash.Query.filter(status in [:open, :draft])
    |> sum_resource(:amount_due_cents, scope)
  end

  defp collected_cents(mount, scope) do
    now = DateTime.utc_now()
    month_start = %{now | day: 1, hour: 0, minute: 0, second: 0, microsecond: {0, 6}}

    Mount.resource(mount, Invoice)
    |> Ash.Query.filter(status == :paid and paid_at >= ^month_start)
    |> sum_resource(:amount_paid_cents, scope)
  end

  defp count_resource(resource_or_query, scope) do
    Ash.count!(resource_or_query, scope: scope)
  rescue
    _ -> 0
  end

  defp sum_resource(query, field, scope) do
    Ash.sum!(query, field, scope: scope) || 0
  rescue
    _ -> 0
  end
end
