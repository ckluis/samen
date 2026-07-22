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

  # The bounded feature-key allowlist — the single source of truth for the plan +
  # entitlement editor's FAIL-CLOSED feature validation. Mirrors, by construction, the
  # Entitlement `feature` one_of AND the intended Plan `features` map keys (blueprint
  # §Entitlement / §Plan). The Entitlement resource's one_of is the KERNEL suspenders
  # (Ash refuses an out-of-set atom); the Plan `features` attribute is a plain `:map`,
  # so Ash does NOT guard its keys — this allowlist is the load-bearing web seam that
  # keeps arbitrary keys out of a plan's entitlement map (proven refutable by
  # scripts/sabotages/26-f7-plan-editor-admin-gate-bypass.patch).
  @feature_keys ~w(basic advanced_reporting api_access custom_domains sso audit_log
                   priority_support unlimited_seats custom_metric)a

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
    # ADR-036 §4.5(3): unit_amount_cents/currency were dropped by the H1 Money
    # migration; unit_amount is now the money_with_currency composite (sortable
    # via Postgres's default composite comparison — same-currency price lists
    # degenerate to an amount sort, as this call site always assumed).
    Mount.resource(mount, Price)
    |> Ash.Query.ensure_selected([:plan_id, :unit_amount, :interval, :active])
    |> Ash.Query.sort(unit_amount: :asc)
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

  @doc """
  The bounded feature-key allowlist (the Entitlement `feature` one_of + the intended
  Plan `features` map keys). The editor UI reads this to render its feature checkboxes;
  the write side validates every feature against it (fail-closed). Single source of truth.
  """
  def feature_keys, do: @feature_keys

  @doc """
  Read the Tier-0 feature entitlements for `scope` (non-PII config rows). BOUNDED to
  #{@detail_limit} rows. On any read error the list is EMPTY.
  """
  def entitlements(mount, scope) do
    Mount.resource(mount, Entitlement)
    |> Ash.Query.ensure_selected([:feature, :granted, :expires_at, :subscription_id, :plan_id])
    |> Ash.Query.sort(inserted_at: :asc)
    |> Ash.Query.limit(@detail_limit)
    |> Ash.read!(scope: scope)
  rescue
    _ -> []
  end

  @doc """
  Create a billing Plan through the sanctioned `create: :*` action. Admin-gated by the
  kernel (`RoleAtLeast :admin`) — pass an admin write scope (`write_scope/2`); this
  module adds NO policy of its own. The `features` entitlement map is FAIL-CLOSED
  validated against `feature_keys/0`: an unknown key is REFUSED and NOTHING is written
  (Ash does not guard plain-`:map` keys, so this is the load-bearing seam). `{:ok, plan}`
  or `{:error, reason}`.
  """
  def create_plan(mount, scope, attrs) do
    with {:ok, attrs} <- validate_feature_attrs(attrs) do
      Mount.resource(mount, Plan)
      |> Ash.Changeset.for_create(:create, attrs, scope: scope)
      |> Ash.create()
    end
  rescue
    e -> {:error, e}
  end

  @doc """
  Update a billing Plan (name/label/description/interval/enabled and the `features`
  entitlement map) through the sanctioned `update: :*` action. Admin-gated; the
  `features` map is FAIL-CLOSED validated exactly as in `create_plan/4`. `{:ok, plan}`
  or `{:error, reason}`.
  """
  def update_plan(mount, scope, id, attrs) do
    with {:ok, attrs} <- validate_feature_attrs(attrs) do
      update_record(mount, scope, Plan, id, attrs)
    end
  rescue
    e -> {:error, e}
  end

  @doc "Create a Price for a plan through the sanctioned `create: :*` action (admin-gated)."
  def create_price(mount, scope, attrs) do
    Mount.resource(mount, Price)
    |> Ash.Changeset.for_create(:create, attrs, scope: scope)
    |> Ash.create()
  rescue
    e -> {:error, e}
  end

  @doc "Update a Price through the sanctioned `update: :*` action (admin-gated)."
  def update_price(mount, scope, id, attrs), do: update_record(mount, scope, Price, id, attrs)

  @doc """
  Grant a bounded feature Entitlement on a subscription through the sanctioned
  create/update action. Admin-gated (`write_scope/2`). The `feature` is FAIL-CLOSED
  validated against `feature_keys/0` (belt; the resource's `feature` one_of is the
  kernel suspenders). Idempotent per subscription+feature: an existing row is flipped
  to granted (`update: :*`), otherwise a new row is created. `attrs` keys (atom or
  string): `subscription_id` (required), `feature` (required), `plan_id`, `expires_at`.
  `{:ok, entitlement}` or `{:error, reason}`.
  """
  def grant_entitlement(mount, scope, attrs) do
    with {:ok, feature} <- validate_feature(fetch(attrs, :feature)) do
      set_entitlement(mount, scope, attrs, feature, true)
    end
  rescue
    e -> {:error, e}
  end

  @doc """
  Revoke a feature Entitlement on a subscription — flips `granted` to false through the
  sanctioned `update: :*` action (admin-gated). Same fail-closed feature validation.
  `{:ok, entitlement}` or `{:error, reason}`.
  """
  def revoke_entitlement(mount, scope, attrs) do
    with {:ok, feature} <- validate_feature(fetch(attrs, :feature)) do
      set_entitlement(mount, scope, attrs, feature, false)
    end
  rescue
    e -> {:error, e}
  end

  # -- private -----------------------------------------------------------------

  # FAIL-CLOSED plan-features validation (the load-bearing web seam — Ash does not
  # guard plain-`:map` keys). Missing `features` → attrs unchanged; an unknown key →
  # refuse with `{:error, {:invalid_feature, key}}` so NOTHING is written.
  defp validate_feature_attrs(attrs) do
    case fetch_features(attrs) do
      :none ->
        {:ok, attrs}

      {:ok, features} when is_map(features) ->
        case Enum.find(Map.keys(features), &(not valid_feature_key?(&1))) do
          nil -> {:ok, attrs}
          bad -> {:error, {:invalid_feature, to_string(bad)}}
        end

      {:ok, _} ->
        {:error, :invalid_features}
    end
  end

  defp fetch_features(attrs) when is_map(attrs) do
    cond do
      Map.has_key?(attrs, :features) -> {:ok, Map.get(attrs, :features)}
      Map.has_key?(attrs, "features") -> {:ok, Map.get(attrs, "features")}
      true -> :none
    end
  end

  defp fetch_features(_), do: :none

  defp valid_feature_key?(key) when is_atom(key), do: key in @feature_keys

  defp valid_feature_key?(key) when is_binary(key),
    do: Enum.any?(@feature_keys, &(Atom.to_string(&1) == key))

  defp valid_feature_key?(_), do: false

  # FAIL-CLOSED single-feature validation. Returns the canonical atom on success. An
  # out-of-set / missing feature is refused BEFORE any write.
  defp validate_feature(nil), do: {:error, :missing_feature}

  defp validate_feature(feature) when is_atom(feature) do
    if feature in @feature_keys, do: {:ok, feature}, else: {:error, {:invalid_feature, feature}}
  end

  defp validate_feature(feature) when is_binary(feature) do
    case Enum.find(@feature_keys, &(Atom.to_string(&1) == feature)) do
      nil -> {:error, {:invalid_feature, feature}}
      atom -> {:ok, atom}
    end
  end

  defp validate_feature(other), do: {:error, {:invalid_feature, other}}

  defp set_entitlement(mount, scope, attrs, feature, granted) do
    sub_id = fetch(attrs, :subscription_id)

    existing =
      Mount.resource(mount, Entitlement)
      |> Ash.Query.filter(subscription_id == ^sub_id and feature == ^feature)
      |> Ash.Query.limit(1)
      |> Ash.read_one!(scope: scope)

    mutable =
      %{granted: granted}
      |> maybe_put(:plan_id, fetch(attrs, :plan_id))
      |> maybe_put(:expires_at, fetch(attrs, :expires_at))

    case existing do
      nil ->
        create_attrs =
          mutable
          |> Map.put(:feature, feature)
          |> Map.put(:subscription_id, sub_id)
          |> Map.put(:org_id, fetch(attrs, :org_id) || scope_org(scope))

        Mount.resource(mount, Entitlement)
        |> Ash.Changeset.for_create(:create, create_attrs, scope: scope)
        |> Ash.create()

      ent ->
        ent
        |> Ash.Changeset.for_update(:update, mutable, scope: scope)
        |> Ash.update()
    end
  end

  # Read-then-update through the sanctioned `update: :*` action (admin-gated by the
  # kernel; the read is member-visible but the update policy holds).
  defp update_record(mount, scope, name, id, attrs) do
    record =
      Mount.resource(mount, name)
      |> Ash.Query.filter(id == ^id)
      |> Ash.Query.limit(1)
      |> Ash.read_one!(scope: scope)

    case record do
      nil ->
        {:error, :not_found}

      record ->
        record
        |> Ash.Changeset.for_update(:update, attrs, scope: scope)
        |> Ash.update()
    end
  rescue
    e -> {:error, e}
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp fetch(attrs, key) when is_map(attrs),
    do: Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))

  defp fetch(_, _), do: nil

  defp scope_org(%Samen.Scope{actor: %{org_id: org}}), do: org
  defp scope_org(_), do: nil

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
    # ADR-036 §4.5(3): unit_amount_cents was dropped by the H1 Money migration;
    # unit_amount is now the money_with_currency composite — extract minor units
    # via Samen.Type.Money.cents/1, keeping the integer-cents accumulator unchanged.
    Mount.resource(mount, Price)
    |> Ash.Query.ensure_selected([:plan_id, :unit_amount, :interval])
    |> Ash.Query.filter(interval == :monthly and active == true)
    |> Ash.Query.limit(@detail_limit)
    |> Ash.read!(scope: scope)
    |> Enum.reduce(0, fn price, acc ->
      subs_on_plan =
        Mount.resource(mount, Subscription)
        |> Ash.Query.filter(status == :active and plan_id == ^price.plan_id)
        |> count_resource(scope)

      acc + subs_on_plan * Samen.Type.Money.cents(price.unit_amount)
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
