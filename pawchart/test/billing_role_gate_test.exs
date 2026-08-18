defmodule PawChart.BillingRoleGateTest do
  @moduledoc """
  PP-5 (Batch 2 TENANT-ROLE, now ACTIVE on pawchart via Batch 5a) + the `:identity_namespace`
  enumerating guard (the Batch-2 residual, closed here).

  Because pawchart NOW wires `identity_namespace: PawChart.Operator` on its tenant Billing mount
  (`@current_org_labels`), `Samen.Web.Billing.SettingsLive` resolves the caller's REAL per-org
  Membership role off the `PawChart.Operator.{User,Membership}` spine — so a clinic ADMIN can
  subscribe / open the payment portal and a plain MEMBER cannot. Before Batch 5a pawchart wired
  no `:identity_namespace`, so the role resolved fail-closed (silent denial for everyone).

  Two proofs:
    1. ROLE GATE — over pawchart's REAL router billing mount: admin can checkout (redirects),
       member/viewer cannot (handler refuses, no redirect).
    2. `:identity_namespace` ENUMERATING GUARD (mirrors `Samen.Web.TenantAuthnCoverageTest`):
       pawchart's role-gated billing mount WIRES `:identity_namespace` to an identity-materializing
       namespace; a refutability twin (the SAME mount with the label STRIPPED) resolves the SAME
       seeded admin fail-CLOSED — proving the label is load-bearing, not vacuous.
  """
  use PawChart.DataCase, async: false

  alias Samen.Web.Billing.SettingsLive
  alias Samen.Web.Mount

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

  # The REAL pawchart tenant Billing mount, extracted off the compiled router (so a router that
  # DROPS :identity_namespace — the Batch-5a sabotage — flips these assertions).
  defp router_billing_mount do
    {_path, mount} =
      PawChartWeb.Router.__routes__()
      |> Enum.filter(&Map.has_key?(&1.metadata, :phoenix_live_view))
      |> Enum.map(fn route -> {route.path, mount_of(route)} end)
      |> Enum.reject(fn {_path, m} -> is_nil(m) end)
      |> Enum.find(fn {_path, m} -> m.scope_kind == :billing end)

    mount
  end

  defp mount_of(%{metadata: %{phoenix_live_view: {_view, _action, _opts, live_session}}}) do
    case get_in(live_session, [:extra, :session]) do
      %{"samen_mount" => raw} -> Mount.from_session(raw)
      _ -> nil
    end
  end

  defp mount_of(_), do: nil

  defp seed_billing_settings(org_id) do
    plan =
      PawChart.Billing.Plan
      |> Ash.Changeset.for_create(:create, %{org_id: org_id, name: "vet_pro", label: "Vet Pro", interval: :monthly, enabled: true}, authorize?: false)
      |> Ash.create!()

    PawChart.Billing.Price
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

    PawChart.Billing.Customer
    |> Ash.Changeset.for_create(
      :create,
      %{
        org_id: org_id,
        billing_name: "Happy Paws Holdings",
        billing_email: "billing@happypaws.example",
        status: :active,
        currency: "USD",
        provider_customer_ref: "cus_fake_1"
      },
      authorize?: false
    )
    |> Ash.create!()

    %{plan: plan}
  end

  # Seed a real User + Membership (role) in `org_id` under the PawChart.Operator identity spine.
  defp seed_member!(org_id, role) do
    user =
      PawChart.Operator.User
      |> Ash.Changeset.for_create(:create, %{org_id: org_id, handle: "billing-#{role}-#{System.unique_integer([:positive])}"})
      |> Ash.create!(authorize?: false)

    PawChart.Operator.Membership
    |> Ash.Changeset.for_create(:create, %{org_id: org_id, user_id: user.id, role: role})
    |> Ash.create!(authorize?: false)

    user
  end

  defp mount_socket(mount, org_id, user) do
    %Phoenix.LiveView.Socket{}
    |> Phoenix.Component.assign(:samen_mount, mount)
    |> Phoenix.Component.assign(:samen_acting_as, false)
    |> Phoenix.Component.assign(:user_id, user.id)
    |> Phoenix.Component.assign(:return_to, "/billing/settings")
    |> Phoenix.Component.assign(:current_uri, "http://localhost/billing/settings?org=#{org_id}")
    |> SettingsLive.load(org_id)
  end

  defp event(socket, name, params) do
    {:noreply, socket} = SettingsLive.handle_event(name, params, socket)
    socket
  end

  # ==========================================================================
  # 1. ROLE GATE — admin can subscribe, member/viewer cannot (REAL router mount).
  # ==========================================================================

  describe "PP-5: billing writes are admin-gated by the REAL membership role (pawchart wired)" do
    setup do
      org_id = Ash.UUID.generate()
      seed = seed_billing_settings(org_id)
      Application.put_env(:samen_core, :billing_provider, {FakeProvider, %{}})
      on_exit(fn -> Application.delete_env(:samen_core, :billing_provider) end)
      %{org_id: org_id, seed: seed, mount: router_billing_mount()}
    end

    test "an ADMIN resolves the admin billing actor (positive control)", %{org_id: org_id, mount: mount} do
      admin = seed_member!(org_id, :admin)
      socket = mount_socket(mount, org_id, admin)
      assert socket.assigns.billing_admin? == true
    end

    test "an ADMIN 'checkout' redirects to the hosted session (the gate is a role gate, not a block)", %{
      org_id: org_id,
      seed: seed,
      mount: mount
    } do
      admin = seed_member!(org_id, :admin)
      socket = mount_socket(mount, org_id, admin) |> event("checkout", %{"plan_id" => seed.plan.id})

      assert socket.redirected == {:redirect, %{external: "https://checkout.fake.test/cs_fake_1", status: 302}}
    end

    test "a MEMBER is NOT a billing admin and a forced 'checkout' is DENIED — no redirect", %{
      org_id: org_id,
      seed: seed,
      mount: mount
    } do
      member = seed_member!(org_id, :member)
      socket = mount_socket(mount, org_id, member)
      assert socket.assigns.billing_admin? == false

      socket = event(socket, "checkout", %{"plan_id" => seed.plan.id})
      refute socket.redirected
      assert socket.assigns.checkout_error =~ "admin"
    end

    test "a MEMBER forced 'manage_payment_method' is DENIED — no redirect", %{org_id: org_id, mount: mount} do
      member = seed_member!(org_id, :member)
      socket = mount_socket(mount, org_id, member) |> event("manage_payment_method", %{})

      refute socket.redirected
      assert socket.assigns.portal_error =~ "admin"
    end

    test "a VIEWER is NOT a billing admin", %{org_id: org_id, mount: mount} do
      viewer = seed_member!(org_id, :viewer)
      socket = mount_socket(mount, org_id, viewer)
      assert socket.assigns.billing_admin? == false
    end
  end

  # ==========================================================================
  # 2. :identity_namespace ENUMERATING GUARD (closes the Batch-2 residual).
  # ==========================================================================

  describe ":identity_namespace coverage guard — pawchart's role-gated billing mount is WIRED" do
    test "GREEN: pawchart's tenant billing mount wires :identity_namespace to an identity-materializing namespace" do
      mount = router_billing_mount()

      ns = Mount.label(mount, :identity_namespace, nil)

      assert ns == PawChart.Operator,
             "pawchart's billing mount must wire :identity_namespace so the role-gated billing " <>
               "write surface resolves the REAL membership role (else the role fails closed silently)"

      # The wired namespace actually materializes Membership (the role source) — the billing mount
      # itself is a Billing scope, so the role is resolved through the sibling identity mount the
      # `:identity_namespace` label names.
      identity = Mount.new(:settings, ns, mount.repo)
      assert Mount.resource(identity, Membership) == PawChart.Operator.Membership
      assert Ash.Resource.Info.resource?(PawChart.Operator.Membership)
    end

    test "REFUTABILITY: the SAME billing mount with :identity_namespace STRIPPED resolves a seeded admin fail-CLOSED" do
      org_id = Ash.UUID.generate()
      _ = seed_billing_settings(org_id)
      Application.put_env(:samen_core, :billing_provider, {FakeProvider, %{}})
      on_exit(fn -> Application.delete_env(:samen_core, :billing_provider) end)

      admin = seed_member!(org_id, :admin)

      # WIRED mount → admin resolves as billing admin (the guarantee).
      wired = router_billing_mount()
      assert mount_socket(wired, org_id, admin).assigns.billing_admin? == true

      # STRIPPED mount (no :identity_namespace) → the Billing namespace materializes no Membership,
      # so the SAME admin resolves NO role → billing writes fail CLOSED. Proves the label is
      # load-bearing (the GREEN guard is non-vacuous).
      stripped = %{wired | labels: Map.delete(wired.labels, :identity_namespace)}
      assert mount_socket(stripped, org_id, admin).assigns.billing_admin? == false
    end
  end
end
