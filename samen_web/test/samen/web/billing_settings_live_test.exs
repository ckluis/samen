defmodule Samen.Web.BillingSettingsLiveTest do
  @moduledoc """
  T26/B10 — `Samen.Web.Billing.SettingsLive`: the CONFIGURED-state composition of the
  shipped T20 checkout + T22 invoice history + T23 hosted payment-method portal, and the
  UNCONFIGURED honest "bring your billing" empty state (INV-4 spirit, ADR-038 §3.5).

  Done-criteria proved here:

    1. Configured-state: plan picker lists Plans, checkout launches (redirects to the
       T20 hosted session URL), payment method is the T23 hosted portal link (redirects,
       no card form), invoice history (T22) renders.
    2. Unconfigured-state: the EXACT honest empty-state copy, ZERO fake affordances (no
       plan card, no checkout/payment-method button, no invoice table, no fabricated
       "$0.00" plan).
  """
  use Samen.WebTest.DataCase, async: false

  alias Samen.Web.Billing.SettingsLive

  defmodule FakeProvider do
    @moduledoc "A vendor-free Samen.Billing.Provider double — hosted checkout + portal only."
    @behaviour Samen.Billing.Provider

    @impl true
    def configured?(config), do: Map.get(config, :configured, true)
    @impl true
    def create_checkout_session(_attrs, _config),
      do: {:ok, %{provider_session_id: "sess_fake_1", url: "https://checkout.fake.test/cs_fake_1"}}

    @impl true
    def create_portal_session(_attrs, _config), do: {:ok, %{url: "https://portal.fake.test/p_fake_1"}}
    @impl true
    def cancel_subscription(_id, _opts, _config), do: {:error, :not_implemented}
    @impl true
    def change_subscription(_id, _changes, _config), do: {:error, :not_implemented}
    @impl true
    def fetch_object(_kind, _id, _config), do: {:error, :not_found}
    @impl true
    def report_usage(_batch, _config), do: {:error, :not_implemented}
    @impl true
    def verify_and_parse_event(_body, _headers, _config), do: {:error, :not_implemented}
    @impl true
    def redact_payload(payload), do: payload
  end

  defp seed_billing_settings(org_id) do
    plan =
      Samen.WebTest.Billing.Plan
      |> Ash.Changeset.for_create(
        :create,
        %{org_id: org_id, name: "growth", label: "Growth", interval: :monthly, enabled: true},
        authorize?: false
      )
      |> Ash.create!()

    price =
      Samen.WebTest.Billing.Price
      |> Ash.Changeset.for_create(
        :create,
        %{
          org_id: org_id,
          plan_id: plan.id,
          unit_amount: Samen.Type.Money.from_cents(29_900, :USD),
          interval: :monthly,
          active: true,
          provider_price_ref: "price_fake_1"
        },
        authorize?: false
      )
      |> Ash.create!()

    customer =
      Samen.WebTest.Billing.Customer
      |> Ash.Changeset.for_create(
        :create,
        %{
          org_id: org_id,
          billing_name: "Settings Fixture Holdings",
          billing_email: "settings.fixture@example.test",
          status: :active,
          currency: "USD",
          provider_customer_ref: "cus_fake_1"
        },
        authorize?: false
      )
      |> Ash.create!()

    subscription =
      Samen.WebTest.Billing.Subscription
      |> Ash.Changeset.for_create(
        :create,
        %{
          org_id: org_id,
          customer_id: customer.id,
          plan_id: plan.id,
          status: :active,
          current_period_end: DateTime.add(DateTime.utc_now(), 30 * 86_400, :second)
        },
        authorize?: false
      )
      |> Ash.create!()

    invoice =
      Samen.WebTest.Billing.Invoice
      |> Ash.Changeset.for_create(
        :create,
        %{
          org_id: org_id,
          customer_id: customer.id,
          subscription_id: subscription.id,
          status: :open,
          amount_due_cents: 29_900,
          currency: "USD",
          due_date: DateTime.add(DateTime.utc_now(), 14 * 86_400, :second),
          hosted_invoice_url: "https://invoice.fake.test/inv_fake_1"
        },
        authorize?: false
      )
      |> Ash.create!()

    %{plan: plan, price: price, customer: customer, subscription: subscription, invoice: invoice}
  end

  # PP-5 (Batch 2 TENANT-ROLE): the billing mount carries the identity scope via the
  # `:identity_namespace` sibling-seam so the LiveView can resolve the caller's REAL
  # per-org membership role (User/Membership live under the Operator identity scope, not
  # the Billing scope). Driftwood wires this the same way in its router.
  defp billing_mount do
    Samen.Web.Mount.new(:billing, Samen.WebTest.Billing, Samen.WebTest.Repo,
      plane: Samen.Web.Plane.tenant(),
      labels: %{identity_namespace: Samen.WebTest.Operator}
    )
  end

  # Seed a real User + Membership (role) in `org_id` under the Operator identity scope,
  # returning the user — so the billing LiveView resolves a REAL role, not the synthetic
  # `:member`. Default admin (the positive control the existing tests rely on).
  defp seed_member!(org_id, role) do
    user =
      Samen.WebTest.Operator.User
      |> Ash.Changeset.for_create(:create, %{org_id: org_id, handle: "billing-#{role}"})
      |> Ash.create!(authorize?: false)

    Samen.WebTest.Operator.Membership
    |> Ash.Changeset.for_create(:create, %{org_id: org_id, user_id: user.id, role: role})
    |> Ash.create!(authorize?: false)

    user
  end

  defp mount_socket(org_id, opts \\ []) do
    role = Keyword.get(opts, :role, :admin)
    user = Keyword.get(opts, :user) || seed_member!(org_id, role)

    %Phoenix.LiveView.Socket{}
    |> Phoenix.Component.assign(:samen_mount, billing_mount())
    |> Phoenix.Component.assign(:samen_acting_as, false)
    |> Phoenix.Component.assign(:user_id, user.id)
    |> Phoenix.Component.assign(:return_to, "/billing/settings")
    |> Phoenix.Component.assign(:current_uri, "http://localhost/billing/settings?org=#{org_id}")
    |> SettingsLive.load(org_id)
  end

  defp html(socket), do: render_html(SettingsLive, socket.assigns)

  defp event(socket, name, params) do
    {:noreply, socket} = SettingsLive.handle_event(name, params, socket)
    socket
  end

  # ==========================================================================
  # 1. CONFIGURED — composes T20 checkout + T22 invoices + T23 payment-method portal
  # ==========================================================================

  describe "CONFIGURED: Samen.Billing.Provider.configured?/1 is true" do
    setup do
      org_id = Ash.UUID.generate()
      seed = seed_billing_settings(org_id)
      Application.put_env(:samen_core, :billing_provider, {FakeProvider, %{}})
      on_exit(fn -> Application.delete_env(:samen_core, :billing_provider) end)
      %{org_id: org_id, seed: seed}
    end

    test "plan picker lists Plans", %{org_id: org_id, seed: seed} do
      out = mount_socket(org_id) |> html()

      assert out =~ ~s(id="plan-picker")
      assert out =~ seed.plan.label
      assert out =~ "$299.00"
      assert out =~ ~s(id="checkout-#{seed.plan.id}")
    end

    test "checkout launches — redirects to the T20 hosted checkout session URL", %{org_id: org_id, seed: seed} do
      socket = mount_socket(org_id) |> event("checkout", %{"plan_id" => seed.plan.id})

      assert socket.redirected ==
               {:redirect, %{external: "https://checkout.fake.test/cs_fake_1", status: 302}}
    end

    test "payment method is the T23 hosted portal — real affordance, redirects, never a card form", %{
      org_id: org_id,
      seed: seed
    } do
      _ = seed
      out = mount_socket(org_id) |> html()

      assert out =~ ~s(id="manage-payment-method")
      refute out =~ "card_number"
      refute out =~ "cvc"
      refute out =~ ~s(type="text" name="card)

      socket = mount_socket(org_id) |> event("manage_payment_method", %{})

      assert socket.redirected ==
               {:redirect, %{external: "https://portal.fake.test/p_fake_1", status: 302}}
    end

    test "invoice history renders (T22, masked read reused unchanged)", %{org_id: org_id, seed: seed} do
      out = mount_socket(org_id) |> html()

      assert out =~ ~s(id="settings-invoice-history")
      assert out =~ ~s(id="settings-invoice-#{seed.invoice.id}")
      assert out =~ "View invoice"
      assert out =~ "Settings Fixture Holdings"
    end

    test "no customer yet — payment method affordance is absent, not a dead button", %{} do
      org_id = Ash.UUID.generate()

      Samen.WebTest.Billing.Plan
      |> Ash.Changeset.for_create(
        :create,
        %{org_id: org_id, name: "starter", label: "Starter", interval: :monthly, enabled: true},
        authorize?: false
      )
      |> Ash.create!()

      out = mount_socket(org_id) |> html()

      refute out =~ ~s(id="manage-payment-method")
      assert out =~ "Available after your first subscription."
    end
  end

  # ==========================================================================
  # 1b. PP-5 (Batch 2 TENANT-ROLE) — billing WRITES (subscribe / manage payment) are
  #     admin+ ONLY, by ROLE (not plane). Both directions, at the LiveView layer.
  # ==========================================================================

  describe "PP-5: billing writes are admin-gated by the REAL membership role" do
    setup do
      org_id = Ash.UUID.generate()
      seed = seed_billing_settings(org_id)
      Application.put_env(:samen_core, :billing_provider, {FakeProvider, %{}})
      on_exit(fn -> Application.delete_env(:samen_core, :billing_provider) end)
      %{org_id: org_id, seed: seed}
    end

    test "an ADMIN sees the Subscribe + Manage-payment affordances (positive control)", %{org_id: org_id} do
      out = mount_socket(org_id, role: :admin) |> html()

      assert out =~ ~s(class="checkout-plan")
      assert out =~ ~s(id="manage-payment-method")
      refute out =~ "billing-admin-only"
    end

    test "a MEMBER sees NO Subscribe / Manage-payment affordance — only the admin-only note", %{org_id: org_id} do
      out = mount_socket(org_id, role: :member) |> html()

      refute out =~ ~s(class="checkout-plan")
      refute out =~ ~s(id="manage-payment-method")
      assert out =~ "billing-admin-only"
    end

    test "a VIEWER sees NO Subscribe / Manage-payment affordance", %{org_id: org_id} do
      out = mount_socket(org_id, role: :viewer) |> html()

      refute out =~ ~s(class="checkout-plan")
      refute out =~ ~s(id="manage-payment-method")
    end

    test "a MEMBER who forces 'checkout' is DENIED at the handler — no redirect (by role, not plane)", %{
      org_id: org_id,
      seed: seed
    } do
      socket = mount_socket(org_id, role: :member) |> event("checkout", %{"plan_id" => seed.plan.id})

      refute socket.redirected
      assert socket.assigns.checkout_error =~ "admin"
    end

    test "a VIEWER who forces 'checkout' is DENIED at the handler — no redirect", %{org_id: org_id, seed: seed} do
      socket = mount_socket(org_id, role: :viewer) |> event("checkout", %{"plan_id" => seed.plan.id})

      refute socket.redirected
      assert socket.assigns.checkout_error =~ "admin"
    end

    test "a MEMBER who forces 'manage_payment_method' is DENIED at the handler — no redirect", %{org_id: org_id} do
      socket = mount_socket(org_id, role: :member) |> event("manage_payment_method", %{})

      refute socket.redirected
      assert socket.assigns.portal_error =~ "admin"
    end

    test "an ADMIN 'checkout' STILL redirects (the gate is a role gate, not a blanket block)", %{
      org_id: org_id,
      seed: seed
    } do
      socket = mount_socket(org_id, role: :admin) |> event("checkout", %{"plan_id" => seed.plan.id})

      assert socket.redirected ==
               {:redirect, %{external: "https://checkout.fake.test/cs_fake_1", status: 302}}
    end
  end

  # ==========================================================================
  # 2. UNCONFIGURED — the honest "bring your billing" empty state
  # ==========================================================================

  describe "UNCONFIGURED: no billing provider wired (INV-4 spirit)" do
    test "exact honest empty-state copy, zero fake affordances" do
      org_id = Ash.UUID.generate()
      # No Application.put_env(:samen_core, :billing_provider, ...) — left unwired.

      out = mount_socket(org_id) |> html()

      assert out =~ SettingsLive.not_configured_copy()
      assert out =~ "Billing is not configured"

      refute out =~ "plan-picker-card"
      refute out =~ "checkout-plan"
      refute out =~ ~s(id="manage-payment-method")
      refute out =~ ~s(id="settings-invoice-history")
      refute out =~ "Subscribe"
      refute out =~ "$0.00"
      refute out =~ "card_number"
    end

    test "a WIRED-but-unconfigured provider (configured?/1 false) is ALSO the honest empty state" do
      org_id = Ash.UUID.generate()
      Application.put_env(:samen_core, :billing_provider, {FakeProvider, %{configured: false}})
      on_exit(fn -> Application.delete_env(:samen_core, :billing_provider) end)

      out = mount_socket(org_id) |> html()

      assert out =~ SettingsLive.not_configured_copy()
      refute out =~ ~s(id="manage-payment-method")
      refute out =~ ~s(id="settings-invoice-history")
    end

    test "unconfigured checkout/portal events never reach a provider (fail-honest even if forced)" do
      org_id = Ash.UUID.generate()
      seed = seed_billing_settings(org_id)
      # billing_provider left unwired — a forced event must not crash and must not redirect.

      socket = mount_socket(org_id)
      assert socket.assigns.configured == false

      socket = event(socket, "checkout", %{"plan_id" => seed.plan.id})
      refute socket.redirected
      assert socket.assigns.checkout_error =~ "no price configured"
    end
  end
end
