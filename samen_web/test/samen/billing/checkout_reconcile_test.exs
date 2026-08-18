defmodule Samen.Web.Billing.CheckoutReconcileTest do
  @moduledoc """
  T20/B2 — the REAL Ash-resource write path for hosted-checkout reconciliation.

  `samen_core`'s `Samen.Billing.Checkout` + `Samen.Billing.AshCheckoutMirror` are
  resource-module-agnostic (no host, no vendor). This test proves them against REAL
  Ash resources + a real Postgres DB — `samen_web`'s own `Samen.WebTest.Billing` mounted
  test domain (zero new migrations, zero new abbrevs: the eight Billing resources are
  already materialized + migrated for this test host) — satisfying the task's explicit
  requirement that checkout activation lands on the EXISTING billing Ash resources, not
  on `Samen.Billing.FakeMirror`/`FakeCheckoutMirror` (the hermetic proof for routing +
  idempotency lives in `samen_core/test/billing_checkout_test.exs` and
  `samen_stripe/test/checkout_test.exs`; THIS file is the one place done-criterion 1
  ("creates/activates Subscription + Entitlement") is proven against a real Subscription
  + Entitlement row).
  """
  use Samen.WebTest.DataCase, async: false

  alias Samen.Billing.{AshCheckoutMirror, Checkout, ProviderEvent}
  alias Samen.WebTest.Billing.{Customer, Entitlement, Plan, Subscription}

  defmodule TestProvider do
    @moduledoc "A vendor-free Samen.Billing.Provider double serving an injected snapshot."
    @behaviour Samen.Billing.Provider

    @impl true
    def configured?(_config), do: true
    @impl true
    def fetch_object(:subscription, id, %{snapshot: snap}), do: {:ok, Map.put(snap, :provider_subscription_id, id)}
    def fetch_object(_kind, _id, _config), do: {:error, :not_found}
    @impl true
    def create_checkout_session(_a, _c), do: {:error, :not_implemented}
    @impl true
    def create_portal_session(_a, _c), do: {:error, :not_implemented}
    @impl true
    def cancel_subscription(_i, _o, _c), do: {:error, :not_implemented}
    @impl true
    def change_subscription(_i, _ch, _c), do: {:error, :not_implemented}
    @impl true
    def report_usage(_b, _c), do: {:error, :not_implemented}
    @impl true
    def verify_and_parse_event(_r, _h, _c), do: {:error, :not_implemented}
    @impl true
    def redact_payload(p), do: p
  end

  @ref_config %{
    subscription: Subscription,
    entitlement: Entitlement,
    plan: Plan,
    customer: Customer,
    subscription_ref_attr: :provider_subscription_ref,
    customer_ref_attr: :provider_customer_ref
  }

  defp seed_plan(org_id, features) do
    Plan
    |> Ash.Changeset.for_create(
      :create,
      %{org_id: org_id, name: "growth", label: "Growth", interval: :monthly, enabled: true, features: features},
      authorize?: false
    )
    |> Ash.create!()
  end

  defp checkout_completed_event(sub_id, org_id, plan_id, customer_ref) do
    %ProviderEvent{
      provider: :fake,
      event_id: "evt_checkout_#{System.unique_integer([:positive])}",
      kind: :checkout_completed,
      occurred_at: ~U[2026-07-10 00:00:00Z],
      provider_refs: %{subscription_id: sub_id, org_id: org_id, plan_id: plan_id, customer_id: customer_ref},
      payload: %{}
    }
  end

  defp checkout_expired_event(sub_id, org_id) do
    %ProviderEvent{
      provider: :fake,
      event_id: "evt_expired_#{System.unique_integer([:positive])}",
      kind: :checkout_expired,
      occurred_at: ~U[2026-07-10 00:00:00Z],
      provider_refs: %{subscription_id: sub_id, org_id: org_id},
      payload: %{}
    }
  end

  defp reconcile_opts(snapshot) do
    [
      provider: TestProvider,
      provider_config: %{snapshot: snapshot},
      checkout_mirror: AshCheckoutMirror,
      checkout_mirror_ref: @ref_config
    ]
  end

  defp snapshot(overrides \\ %{}) do
    Map.merge(
      %{
        provider_customer_id: "cus_real_1",
        status: :active,
        current_period_start: ~U[2026-07-01 00:00:00Z],
        current_period_end: ~U[2026-08-01 00:00:00Z]
      },
      overrides
    )
  end

  defp count_subscriptions(org_id) do
    Subscription |> Ash.Query.ensure_selected([:org_id]) |> Ash.read!(authorize?: false) |> Enum.count(&(&1.org_id == org_id))
  end

  defp count_entitlements(org_id) do
    Entitlement |> Ash.Query.ensure_selected([:org_id]) |> Ash.read!(authorize?: false) |> Enum.count(&(&1.org_id == org_id))
  end

  # ---------------------------------------------------------------------------
  # Done-criterion 1 — success creates/activates a REAL Subscription + Entitlement
  # ---------------------------------------------------------------------------

  test "checkout_completed creates a real Subscription + one Entitlement row per granted feature" do
    org_id = Ash.UUID.generate()
    plan = seed_plan(org_id, %{"advanced_reporting" => true, "api_access" => true, "sso" => false})
    sub_id = "sub_real_#{System.unique_integer([:positive])}"

    event = checkout_completed_event(sub_id, org_id, plan.id, "cus_real_1")

    assert {:ok, :applied, applied} = Checkout.reconcile(event, reconcile_opts(snapshot()))

    subscription = applied.subscription
    assert subscription.org_id == org_id
    assert subscription.plan_id == plan.id
    assert subscription.provider_subscription_ref == sub_id
    assert subscription.status == :active

    # The subscription is a REAL row, independently readable.
    raw = Ash.get!(Subscription, subscription.id, authorize?: false)
    assert raw.provider_subscription_ref == sub_id

    # Entitlements: exactly the TRUE features, never the false one.
    granted_features = applied.entitlements |> Enum.map(& &1.feature) |> Enum.sort()
    assert granted_features == [:advanced_reporting, :api_access]

    for ent <- applied.entitlements do
      assert ent.subscription_id == subscription.id
      assert ent.granted == true
    end

    # A real Customer row was created (opaque ref only — no PII invented).
    customer = Ash.get!(Customer, subscription.customer_id, authorize?: false)
    assert customer.provider_customer_ref == "cus_real_1"
    assert customer.status == :active
  end

  test "an EXISTING customer (same org + provider ref) is reused, not duplicated" do
    org_id = Ash.UUID.generate()
    plan = seed_plan(org_id, %{"basic" => true})

    existing_customer =
      Customer
      |> Ash.Changeset.for_create(:create, %{org_id: org_id, provider_customer_ref: "cus_existing"}, authorize?: false)
      |> Ash.create!()

    sub_id = "sub_reuse_#{System.unique_integer([:positive])}"
    event = checkout_completed_event(sub_id, org_id, plan.id, "cus_existing")

    assert {:ok, :applied, applied} =
             Checkout.reconcile(event, reconcile_opts(snapshot(%{provider_customer_id: "cus_existing"})))

    assert applied.subscription.customer_id == existing_customer.id
  end

  # ---------------------------------------------------------------------------
  # Done-criterion 1 — cancel (expired) leaves state UNCHANGED
  # ---------------------------------------------------------------------------

  test "checkout_expired (the cancel webhook) creates NOTHING — Subscription/Entitlement counts unchanged" do
    org_id = Ash.UUID.generate()
    _plan = seed_plan(org_id, %{"basic" => true})
    before_subs = count_subscriptions(org_id)
    before_ents = count_entitlements(org_id)

    sub_id = "sub_expired_#{System.unique_integer([:positive])}"
    event = checkout_expired_event(sub_id, org_id)

    assert {:ok, :expired} = Checkout.reconcile(event, reconcile_opts(snapshot()))

    assert count_subscriptions(org_id) == before_subs
    assert count_entitlements(org_id) == before_ents
  end

  # ---------------------------------------------------------------------------
  # Done-criterion 2 — idempotent: success delivered twice ⇒ ONE real Subscription row
  # ---------------------------------------------------------------------------

  test "the SAME checkout.completed event reconciled twice creates exactly ONE Subscription row" do
    org_id = Ash.UUID.generate()
    plan = seed_plan(org_id, %{"basic" => true})
    sub_id = "sub_idem_#{System.unique_integer([:positive])}"
    event = checkout_completed_event(sub_id, org_id, plan.id, "cus_idem_1")

    assert {:ok, :applied, _} = Checkout.reconcile(event, reconcile_opts(snapshot()))
    assert {:ok, :duplicate} = Checkout.reconcile(event, reconcile_opts(snapshot()))

    matches =
      Subscription
      |> Ash.Query.ensure_selected([:org_id, :provider_subscription_ref])
      |> Ash.read!(authorize?: false)
      |> Enum.filter(&(&1.provider_subscription_ref == sub_id))

    assert length(matches) == 1
  end
end
