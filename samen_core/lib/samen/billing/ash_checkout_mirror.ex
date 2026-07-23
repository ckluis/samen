defmodule Samen.Billing.AshCheckoutMirror do
  @moduledoc """
  The REAL `Samen.Billing.CheckoutMirror` implementation (T20/B2): writes onto the
  EXISTING billing Ash resources materialized by `Samen.Scopes.Billing` (Customer,
  Plan, Subscription, Entitlement) — no new columns, no new migration.

  Resource-module-agnostic AND vendor-field-agnostic (INV-4: this file names no
  vendor — the concrete resource modules AND the provider's external-reference
  attribute names are BOTH resolved from the `ref` map, never hardcoded here, exactly
  like `Samen.Billing.WebhookDispatch` resolves `:billing_provider`/`:billing_mirror`
  from host config):

      config :samen_core, :billing_checkout_mirror,
        {Samen.Billing.AshCheckoutMirror,
         %{
           subscription: MyApp.BillingScope.Subscription,
           entitlement: MyApp.BillingScope.Entitlement,
           plan: MyApp.BillingScope.Plan,
           customer: MyApp.BillingScope.Customer,
           # The blueprint's provider-ref attribute names — a documented, pre-existing
           # vendor-branded carve-out on the RESOURCE (see
           # samen_core/lib/samen/scopes/billing/blueprint.ex's moduledoc NOTE); this
           # module never names the vendor itself, only accepts whatever atom the HOST
           # config supplies (e.g. the blueprint's current provider-branded attribute
           # name for each resource).
           subscription_ref_attr: :vendor_subscription_id_field,
           customer_ref_attr: :vendor_customer_id_field
         }}

  ## Writes are framework-system writes (`authorize?: false`)

  Like `Samen.Billing.SubscriptionMovement` and the notifications `StatusChange` seam,
  this is a webhook-triggered background write, not a user action — it authorizes
  itself (there is no tenant actor on a webhook request) exactly like those two
  precedents, never bypassing `Samen.Policy.OrgScope` reads by construction (every
  query explicitly filters on `org_id`).

  ## Idempotency (done-criterion 2)

  `activate/2` re-checks `subscription_exists?/2` immediately before the write (belt +
  suspenders over `Samen.Billing.Checkout.reconcile/2`'s own pre-check): the reconciler's
  check avoids a wasted `fetch_object/3` round-trip on a known replay; THIS check is the
  actual write-time guard against a race between two concurrent deliveries of the same
  event (the reconciler's read and this module's read are not in the same transaction —
  a real unique index on the subscription's ref attribute would close that window fully;
  none exists yet on the blueprint, a documented risk, see the task summary).

  ## Customer resolution

  A checkout's authoritative snapshot customer ref (or the session's `customer_ref`) is
  looked up by `(org_id, customer_ref_attr)`; absent a match, a bare Customer row is
  created (opaque ref only — `billing_name`/`billing_email` stay nil; PII enrollment is
  a separate, later action, never invented here).

  ## Entitlements

  One Entitlement row per `plan.features` key with a `true` value, mapped through
  `String.to_existing_atom/1` (never a fabricated atom — an unrecognized feature key is
  silently skipped rather than crashing the activation).
  """

  @behaviour Samen.Billing.CheckoutMirror

  @impl true
  def subscription_exists?(ref, provider_subscription_id) do
    subscription_resource = Map.fetch!(ref, :subscription)
    ref_attr = Map.fetch!(ref, :subscription_ref_attr)

    subscription_resource
    |> Ash.Query.filter_input(%{Atom.to_string(ref_attr) => provider_subscription_id})
    |> Ash.Query.limit(1)
    |> Ash.read(authorize?: false)
    |> case do
      {:ok, [_ | _]} -> {:ok, true}
      {:ok, []} -> {:ok, false}
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, e}
  end

  @impl true
  def activate(ref, %{org_id: org_id, snapshot: snapshot} = attrs) do
    sub_ref_attr = Map.fetch!(ref, :subscription_ref_attr)
    provider_subscription_id = Map.fetch!(snapshot, :provider_subscription_id)

    with {:ok, false} <- subscription_exists?(ref, provider_subscription_id),
         {:ok, plan} <- resolve_plan(Map.fetch!(ref, :plan), org_id, Map.get(attrs, :plan_id)),
         {:ok, customer} <- resolve_customer(ref, org_id, snapshot, attrs) do
      create_subscription_and_entitlements(
        Map.fetch!(ref, :subscription),
        Map.fetch!(ref, :entitlement),
        sub_ref_attr,
        org_id,
        plan,
        customer,
        snapshot
      )
    else
      {:ok, true} -> {:ok, :duplicate}
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, e}
  end

  # ---------------------------------------------------------------------------

  defp resolve_plan(_plan_resource, _org_id, nil), do: {:error, :missing_plan_ref}

  defp resolve_plan(plan_resource, org_id, plan_id) do
    plan_resource
    |> Ash.Query.filter_input(%{"id" => plan_id})
    |> Ash.Query.ensure_selected([:org_id, :features])
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, %{org_id: ^org_id} = plan} -> {:ok, plan}
      {:ok, %{}} -> {:error, :plan_org_mismatch}
      {:ok, nil} -> {:error, :plan_not_found}
      {:error, reason} -> {:error, {:plan_not_found, reason}}
    end
  end

  defp resolve_customer(ref, org_id, snapshot, attrs) do
    case Map.get(snapshot, :provider_customer_id) || Map.get(attrs, :customer_ref) do
      nil ->
        {:error, :missing_customer_ref}

      provider_customer_id ->
        find_or_create_customer(ref, org_id, provider_customer_id)
    end
  end

  defp find_or_create_customer(ref, org_id, provider_customer_id) do
    customer_resource = Map.fetch!(ref, :customer)
    ref_attr = Map.fetch!(ref, :customer_ref_attr)

    customer_resource
    |> Ash.Query.filter_input(%{
      "org_id" => org_id,
      Atom.to_string(ref_attr) => provider_customer_id
    })
    |> Ash.Query.limit(1)
    |> Ash.read(authorize?: false)
    |> case do
      {:ok, [customer]} ->
        {:ok, customer}

      {:ok, []} ->
        customer_resource
        |> Ash.Changeset.for_create(
          :create,
          %{org_id: org_id, status: :active} |> Map.put(ref_attr, provider_customer_id),
          authorize?: false
        )
        |> Ash.create()

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_subscription_and_entitlements(
         subscription_resource,
         entitlement_resource,
         sub_ref_attr,
         org_id,
         plan,
         customer,
         snapshot
       ) do
    sub_attrs =
      %{
        org_id: org_id,
        customer_id: customer.id,
        plan_id: plan.id,
        status: Map.get(snapshot, :status) || :active,
        current_period_start: Map.get(snapshot, :current_period_start),
        current_period_end: Map.get(snapshot, :current_period_end),
        trial_end: Map.get(snapshot, :trial_end),
        cancel_at: Map.get(snapshot, :cancel_at),
        cancelled_at: Map.get(snapshot, :cancelled_at)
      }
      |> Map.put(sub_ref_attr, Map.fetch!(snapshot, :provider_subscription_id))

    with {:ok, subscription} <-
           subscription_resource
           |> Ash.Changeset.for_create(:create, sub_attrs, authorize?: false)
           |> Ash.create(),
         # org_id is not selected by default on the created struct (same caveat
         # Samen.Billing.SubscriptionMovement's org_id_of/2 works around) — force it.
         {:ok, subscription} <- Ash.load(subscription, [:org_id], authorize?: false) do
      entitlements = create_entitlements(entitlement_resource, org_id, subscription, plan)
      {:ok, %{subscription: subscription, entitlements: entitlements}}
    end
  end

  defp create_entitlements(entitlement_resource, org_id, subscription, plan) do
    (plan.features || %{})
    |> Enum.filter(fn {_key, granted} -> granted == true end)
    |> Enum.map(fn {feature_key, _} -> safe_feature_atom(feature_key) end)
    |> Enum.reject(&is_nil/1)
    |> Enum.map(fn feature ->
      entitlement_resource
      |> Ash.Changeset.for_create(
        :create,
        %{
          org_id: org_id,
          subscription_id: subscription.id,
          plan_id: plan.id,
          feature: feature,
          granted: true
        },
        authorize?: false
      )
      |> Ash.create!()
    end)
  end

  defp safe_feature_atom(key) when is_atom(key), do: key

  defp safe_feature_atom(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

  defp safe_feature_atom(_), do: nil
end
