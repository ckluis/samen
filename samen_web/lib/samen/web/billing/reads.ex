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
  alias Samen.Web.Reads.Guard

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
  def customers(mount, scope), do: customers_result(mount, scope) |> Guard.value([])

  @doc "Tagged sibling of `customers/2` (WP6): `{:ok, rows}` or `{:error, :unavailable | :forbidden}`; an outage is not an empty list."
  def customers_result(mount, scope), do: Guard.run(:billing_customers, scope, fn -> fetch_customers(mount, scope) end)

  defp fetch_customers(mount, scope) do
    Mount.resource(mount, Customer)
    |> Ash.Query.ensure_selected([:billing_name, :billing_email, :status, :currency, :custom])
    |> Ash.Query.sort(inserted_at: :asc)
    |> Ash.Query.limit(@detail_limit)
    |> Ash.read!(scope: scope)
    |> resolve_pii(mount, Customer, scope)
  end

  @doc """
  Read active subscriptions for `scope`, joined to their (PII-resolved) customer + plan.
  BOUNDED to #{@detail_limit} rows; the Overview page itself reads through the
  paginated `subscriptions_page/3`.
  """
  def subscriptions(mount, scope), do: subscriptions_result(mount, scope) |> Guard.value([])

  @doc "Tagged sibling of `subscriptions/2` (WP6); same contract as `customers_result/2`."
  def subscriptions_result(mount, scope), do: Guard.run(:billing_subscriptions, scope, fn -> fetch_subscriptions(mount, scope) end)

  defp fetch_subscriptions(mount, scope) do
    subs =
      Mount.resource(mount, Subscription)
      |> Ash.Query.ensure_selected([:status, :customer_id, :plan_id, :current_period_start, :current_period_end])
      |> Ash.Query.sort(inserted_at: :asc)
      |> Ash.Query.limit(@detail_limit)
      |> Ash.read!(scope: scope)

    join_subscriptions(subs, mount, scope)
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
    Guard.page(:billing_subscriptions_page, scope, state, fn -> fetch_subscriptions_page(mount, scope, state) end)
  end

  defp fetch_subscriptions_page(mount, scope, state) do
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
  end

  @doc """
  Read billing invoices for `scope`, each joined to its PII-resolved customer.
  BOUNDED to #{@detail_limit} rows; the Invoices page itself reads through the
  paginated `invoices_page/3`.
  """
  def invoices(mount, scope), do: invoices_result(mount, scope) |> Guard.value([])

  @doc "Tagged sibling of `invoices/2` (WP6); same contract as `customers_result/2`."
  def invoices_result(mount, scope), do: Guard.run(:billing_invoices, scope, fn -> fetch_invoices(mount, scope) end)

  defp fetch_invoices(mount, scope) do
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
  end

  @doc """
  Read ONE keyset page of invoices for `scope` — the `ListLive` reads contract, built
  on `Samen.Web.Reads.page!/3` (BOUNDED BY CONSTRUCTION). The invoice carries no PII;
  the joined customer's billing_name is plane-resolved AFTER paging (tenant clear /
  operator ••••). On any read error the page is EMPTY.

  Selects the T22/B4+B6 tax + hosted-link fields alongside the existing amount/status
  columns — `tax_amount_cents`/`tax_lines` mirror verbatim (nil/[] when the provider
  computed no tax, never a fabricated `0`); `hosted_invoice_url`/`hosted_receipt_url`
  are the provider's hosted pages (rendered TENANT-SIDE ONLY, ADR-038 §3.5 — see
  `Samen.Web.Billing.InvoicesLive`'s render).
  """
  def invoices_page(mount, scope, state) do
    Guard.page(:billing_invoices_page, scope, state, fn -> fetch_invoices_page(mount, scope, state) end)
  end

  defp fetch_invoices_page(mount, scope, state) do
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
        :subscription_id,
        :tax_amount_cents,
        :hosted_invoice_url,
        :hosted_receipt_url
      ])
      |> Samen.Web.Reads.page!(state, scope: scope, filter_fields: [:currency])

    %{page | items: join_invoices(page.items, mount, scope)}
  end

  @doc """
  Read Tier-0 billing plans for `scope`. Non-PII config rows. BOUNDED to
  #{@detail_limit} rows; the Plans page itself reads through `plans_page/3`.
  """
  def plans(mount, scope), do: plans_result(mount, scope) |> Guard.value([])

  @doc "Tagged sibling of `plans/2` (WP6); same contract as `customers_result/2`."
  def plans_result(mount, scope), do: Guard.run(:billing_plans, scope, fn -> fetch_plans(mount, scope) end)

  defp fetch_plans(mount, scope) do
    Mount.resource(mount, Plan)
    |> Ash.Query.ensure_selected([:name, :label, :description, :interval, :enabled, :features])
    |> Ash.Query.sort(inserted_at: :asc)
    |> Ash.Query.limit(@detail_limit)
    |> Ash.read!(scope: scope)
  end

  @doc """
  Read ONE keyset page of billing plans for `scope` — the `ListLive` reads contract,
  built on `Samen.Web.Reads.page!/3` (BOUNDED BY CONSTRUCTION). Plans are non-PII
  Tier-0 config rows; sort/filter fields are bounded plain attributes. On any read
  error the page is EMPTY.

  ADR-040 §5.8 (T37h) — `state.show_archived` (the `Samen.Web.ListLive` archived-
  filter toggle) switches the base query to the `:archived` read (Plan IS
  `archivable: true`, T37a). `Samen.Archival.OnlyArchived` backs that read — it is a
  TRASH view (archived rows ONLY), not a union with the live set — so the toggle is
  "View: live | archived", a filter switch, matching the substrate's own trash/
  restore convention (§5.2). `false` (the default) is the plain default read —
  byte-identical to pre-T37h behavior.
  """
  def plans_page(mount, scope, state) do
    Guard.page(:billing_plans_page, scope, state, fn -> fetch_plans_page(mount, scope, state) end)
  end

  defp fetch_plans_page(mount, scope, state) do
    base = Mount.resource(mount, Plan)
    base = if state.show_archived, do: Ash.Query.for_read(base, :archived), else: base

    base
    |> Ash.Query.ensure_selected([:name, :label, :description, :interval, :enabled, :features, :archived_at])
    |> Samen.Web.Reads.page!(state, scope: scope, filter_fields: [:name, :label])
  end

  @doc "Read plans with their prices joined: `[%{plan: plan, prices: [price]}]`. BOUNDED."
  def plans_with_prices(mount, scope), do: plans_with_prices_result(mount, scope) |> Guard.value([])

  @doc "Tagged sibling of `plans_with_prices/2` (WP6); same contract as `customers_result/2`."
  def plans_with_prices_result(mount, scope) do
    Guard.run(:billing_plans_with_prices, scope, fn ->
      prices = fetch_prices_by_plan(mount, scope)

      Enum.map(fetch_plans(mount, scope), fn plan ->
        %{plan: plan, prices: Map.get(prices, plan.id, [])}
      end)
    end)
  end

  @doc """
  plan_id → [price] map (non-PII config rows, BOUNDED) for joining prices to a plan page.

  Selects `:provider_price_ref` alongside the display fields — T26/B10 needs it as the
  `price_ref` a checkout session names (ADR-038 §3.1 `create_checkout_session`); the
  attribute is the SAME T18-documented opaque vendor cross-reference `provider_customer_ref`
  already is (non-PII, public?: true on the Price blueprint), referenced under its
  CURRENT name per the billing-blueprint collision-group rule (T106 owns the rename).
  """
  def prices_by_plan(mount, scope), do: prices_by_plan_result(mount, scope) |> Guard.value(%{})

  @doc "Tagged sibling of `prices_by_plan/2` (WP6); same contract as `customers_result/2`."
  def prices_by_plan_result(mount, scope), do: Guard.run(:billing_prices_by_plan, scope, fn -> fetch_prices_by_plan(mount, scope) end)

  defp fetch_prices_by_plan(mount, scope) do
    # ADR-036 §4.5(3): unit_amount_cents/currency were dropped by the H1 Money
    # migration; unit_amount is now the money_with_currency composite (sortable
    # via Postgres's default composite comparison — same-currency price lists
    # degenerate to an amount sort, as this call site always assumed).
    Mount.resource(mount, Price)
    |> Ash.Query.ensure_selected([:plan_id, :unit_amount, :interval, :active, :provider_price_ref])
    |> Ash.Query.sort(unit_amount: :asc)
    |> Ash.Query.limit(@detail_limit)
    |> Ash.read!(scope: scope)
    |> Enum.group_by(& &1.plan_id)
  end

  @doc """
  Non-PII billing metrics (mrr_cents, active_subs, outstanding_cents, collected_cents).
  Computed as DB aggregates (`Ash.count`/`Ash.sum`) — no row set is transferred, so the
  read is bounded by construction (A3 read-bounding: this replaced unbounded
  subscription/invoice `read!`s).
  """
  def metrics(mount, scope) do
    {stats, _failed} = metrics_status(mount, scope)
    stats
  end

  @doc """
  `metrics/2` plus WHICH of its four numbers could not be read (WP6): `{stats, failed}` where
  `failed` is a subset of `[:active_subs, :mrr_cents, :outstanding_cents, :collected_cents]`. A
  failed number is `0` in `stats` (the legacy value) but is named in `failed`, so its tile shows
  an error instead of a confident `$0.00`. Each number is its own guarded read.
  """
  def metrics_status(mount, scope) do
    parts = [
      active_subs: Guard.run(:billing_metric_active_subs, scope, fn -> count_active_subscriptions(mount, scope) end),
      mrr_cents: Guard.run(:billing_metric_mrr, scope, fn -> compute_mrr(mount, scope) end),
      outstanding_cents: Guard.run(:billing_metric_outstanding, scope, fn -> outstanding_cents(mount, scope) end),
      collected_cents: Guard.run(:billing_metric_collected, scope, fn -> collected_cents(mount, scope) end)
    ]

    split_status(parts)
  end

  @doc """
  Non-PII invoice metrics for the Invoices page cards — count / paid / overdue /
  outstanding_cents, all DB aggregates (bounded by construction).
  """
  def invoice_metrics(mount, scope) do
    {stats, _failed} = invoice_metrics_status(mount, scope)
    stats
  end

  @doc "`invoice_metrics/2` plus the keys that could not be read (WP6); same contract as `metrics_status/2`."
  def invoice_metrics_status(mount, scope) do
    now = DateTime.utc_now()

    parts = [
      count: Guard.run(:billing_invoice_metric_count, scope, fn -> count_resource(Mount.resource(mount, Invoice), scope) end),
      paid:
        Guard.run(:billing_invoice_metric_paid, scope, fn ->
          Mount.resource(mount, Invoice)
          |> Ash.Query.filter(status == :paid)
          |> count_resource(scope)
        end),
      overdue:
        Guard.run(:billing_invoice_metric_overdue, scope, fn ->
          Mount.resource(mount, Invoice)
          |> Ash.Query.filter(status == :open and due_date < ^now)
          |> count_resource(scope)
        end),
      outstanding_cents: Guard.run(:billing_metric_outstanding, scope, fn -> outstanding_cents(mount, scope) end)
    ]

    split_status(parts)
  end

  defp split_status(parts) do
    {Map.new(parts, fn {key, result} -> {key, Guard.value(result, 0)} end),
     for({key, result} <- parts, Guard.unavailable?(result), do: key)}
  end

  # -- A3 write side (sanctioned defaults only) ---------------------------------

  @doc """
  The tenant-ADMIN write scope for the kernel's admin-gated Billing config writes
  (Plan / Price / Invoice / Subscription carry `RoleAtLeast :admin`; the mount's
  plane scope is a `:member`, per `Samen.Web.Plane.scope/2`).

  ADR-045 §4.4 (S1a) — delegates to `Samen.Web.TenantRole.admin_scope/3`: the disarmed dev
  posture keeps `:admin` byte-for-byte; an ARMED host derives the principal's REAL
  `Identity.Membership` role (fail-closed `:member`, never `:admin`) so an ordinary member no
  longer self-elevates. The elevation still PRESERVES every plane marker (`plane`, `kind`,
  `impersonation`) from `Mount.scope/2` — an operator-plane mount keeps `plane: :operator`, so
  `Samen.Pii.WriteGuard` (MC-1 / Invariant L1) rejects a vaulted-PII write exactly as before, the
  elevation raises RBAC rank only, and `OrgScope` still confines the write to `org_id`.
  """
  def write_scope(mount, org_id, principal \\ nil),
    do: Samen.Web.TenantRole.admin_scope(mount, org_id, principal)

  @doc """
  The `Samen.Web.ListLive` `restore` elevator (ADR-040 §5.8, T37h) — the archived-Plan restore is
  `RoleAtLeast :admin`-gated, stricter than the plain list `scope` reads use. `(scope, socket)`:
  re-derives the tenant-ADMIN scope for the list's org through `Samen.Web.TenantRole.admin_scope/3`
  using the socket's pinned principal, so ADR-045 §4.4 (S1a) governs it exactly as every other
  write path — disarmed → `:admin`; armed → the REAL `Identity.Membership` role, fail-closed
  `:member`.
  """
  def restore_admin_scope(%Samen.Scope{actor: %{org_id: org_id}}, socket) when is_binary(org_id) do
    Samen.Web.TenantRole.admin_scope(
      socket.assigns.samen_mount,
      org_id,
      socket.assigns[:samen_tenant_principal]
    )
  end

  def restore_admin_scope(scope, _socket), do: scope

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
  Read the usage tallies for `scope` (T163 / ADR-051 P4), newest period first. Each row
  is a `Usage` tally DERIVED from the insert-only ledger (`Samen.Billing.UsageTally`):
  `metric`, `quantity`, `reported_quantity` and the period. Quantities only, never a
  price (ADR-051 D2: money is mirrored from the provider, never computed here). Non-PII.
  BOUNDED to #{@detail_limit} rows. On any read error the list is EMPTY.
  """
  def usage(mount, scope), do: usage_result(mount, scope) |> Guard.value([])

  @doc "Tagged sibling of `usage/2` (WP6); same contract as `customers_result/2`."
  def usage_result(mount, scope), do: Guard.run(:billing_usage, scope, fn -> fetch_usage(mount, scope) end)

  defp fetch_usage(mount, scope) do
    Mount.resource(mount, Usage)
    |> Ash.Query.ensure_selected([:metric, :quantity, :reported_quantity, :period_start, :period_end, :subscription_id])
    |> Ash.Query.sort(period_start: :desc, metric: :asc)
    |> Ash.Query.limit(@detail_limit)
    |> Ash.read!(scope: scope)
  end

  @doc """
  Read the Tier-0 feature entitlements for `scope` (non-PII config rows). BOUNDED to
  #{@detail_limit} rows. On any read error the list is EMPTY.
  """
  def entitlements(mount, scope), do: entitlements_result(mount, scope) |> Guard.value([])

  @doc "Tagged sibling of `entitlements/2` (WP6); same contract as `customers_result/2`."
  def entitlements_result(mount, scope), do: Guard.run(:billing_entitlements, scope, fn -> fetch_entitlements(mount, scope) end)

  defp fetch_entitlements(mount, scope) do
    Mount.resource(mount, Entitlement)
    |> Ash.Query.ensure_selected([:feature, :granted, :expires_at, :subscription_id, :plan_id])
    |> Ash.Query.sort(inserted_at: :asc)
    |> Ash.Query.limit(@detail_limit)
    |> Ash.read!(scope: scope)
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
    custs_by_id = fetch_customers(mount, scope) |> Map.new(&{&1.id, &1})
    plans_by_id = fetch_plans(mount, scope) |> Map.new(&{&1.id, &1})
    prices = fetch_prices_by_plan(mount, scope)

    Enum.map(subs, fn sub ->
      sub
      |> Map.put(:__customer__, Map.get(custs_by_id, sub.customer_id))
      |> Map.put(:__plan__, Map.get(plans_by_id, sub.plan_id))
      |> Map.put(:__mrr_cents__, plan_mrr_cents(Map.get(prices, sub.plan_id, [])))
    end)
  end

  # The plan's REAL monthly recurring amount in cents, from its active price: a monthly price is
  # itself, an annual one is a twelfth (rounded). `nil` when the plan has no active recurring
  # price we can normalise (none, one-time, weekly/daily) — the UI shows "—", never a guess.
  defp plan_mrr_cents(prices) do
    Enum.find_value(prices, fn price ->
      cents = Samen.Type.Money.cents(price.unit_amount)

      case {price.active, price.interval} do
        {true, :monthly} -> cents
        {true, :annual} -> div(cents + 6, 12)
        _ -> nil
      end
    end)
  end

  defp join_invoices(invs, mount, scope) do
    custs_by_id = fetch_customers(mount, scope) |> Map.new(&{&1.id, &1})

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
    e ->
      # Fail-closed (no plaintext downgrade), but not silent: a resolver outage is logged.
      Guard.report(:billing_resolve_pii, scope, e)
      records
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

  # Raising on purpose: every caller is inside a `Guard.run/3` (a failed aggregate is an error
  # tile, never a confident zero).
  defp count_resource(resource_or_query, scope), do: Ash.count!(resource_or_query, scope: scope)

  defp sum_resource(query, field, scope), do: Ash.sum!(query, field, scope: scope) || 0
end
