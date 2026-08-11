defmodule Driftwood.BillingIdentityNamespaceTest do
  @moduledoc """
  Residual A (Batch 7) — driftwood's real-router parity for the `:identity_namespace`
  enumerating guard (pawchart's `PawChart.BillingRoleGateTest` is the pawchart-side twin;
  `Samen.Web.IdentityNamespaceCoverageTest` is the framework-wide class-closer).

  Driftwood's tenant Billing mount WIRES `identity_namespace: Driftwood.Operator` (over
  `@current_org_labels`), so `Samen.Web.Billing.SettingsLive` resolves the caller's REAL per-org
  `Membership` role off the `Driftwood.Operator.{User,Membership}` spine — a clinic/broker ADMIN
  can subscribe / open the payment portal and a plain MEMBER cannot. Absent the label the billing
  mount's own `Driftwood.Billing` namespace materializes no `Membership`, so the role resolves
  FAIL-CLOSED (silent denial for everyone) — safe, but billing is silently non-functional.

  The mount is deserialized off `DriftwoodWeb.Router` (the REAL compiled router), so a router that
  DROPS `:identity_namespace` (the Batch-7 sabotage) flips these assertions — driftwood passes
  because it is WIRED, never by exclusion.

  Paired proofs (anti-tautology):
    * GREEN (wiring) — the real billing mount wires `:identity_namespace` to an
      identity-materializing namespace (`Driftwood.Operator` → `Membership`).
    * GREEN (live) — a seeded ADMIN resolves `billing_admin?: true`; a MEMBER resolves false.
    * REFUTABILITY — the SAME mount with the label STRIPPED resolves the seeded admin fail-CLOSED,
      proving the label is load-bearing (the GREEN is non-vacuous).
  """
  use Driftwood.DataCase, async: false

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

  # The REAL driftwood tenant Billing mount, extracted off the compiled router.
  defp router_billing_mount do
    {_path, mount} =
      DriftwoodWeb.Router.__routes__()
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
      Driftwood.Billing.Plan
      |> Ash.Changeset.for_create(:create, %{org_id: org_id, name: "freight_pro", label: "Freight Pro", interval: :monthly, enabled: true}, authorize?: false)
      |> Ash.create!()

    Driftwood.Billing.Price
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

    Driftwood.Billing.Customer
    |> Ash.Changeset.for_create(
      :create,
      %{
        org_id: org_id,
        billing_name: "Blue Ridge Logistics",
        billing_email: "billing@blueridge.example",
        status: :active,
        currency: "USD",
        provider_customer_ref: "cus_fake_1"
      },
      authorize?: false
    )
    |> Ash.create!()

    %{plan: plan}
  end

  defp seed_member!(org_id, role) do
    user =
      Driftwood.Operator.User
      |> Ash.Changeset.for_create(:create, %{org_id: org_id, handle: "billing-#{role}-#{System.unique_integer([:positive])}"})
      |> Ash.create!(authorize?: false)

    Driftwood.Operator.Membership
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

  describe "driftwood's role-gated billing mount WIRES :identity_namespace" do
    test "GREEN: the real router billing mount wires :identity_namespace to an identity-materializing namespace" do
      mount = router_billing_mount()

      ns = Mount.label(mount, :identity_namespace, nil)

      assert ns == Driftwood.Operator,
             "driftwood's billing mount must wire :identity_namespace so the role-gated billing " <>
               "write surface resolves the REAL membership role (else the role fails closed silently)"

      identity = Mount.new(:settings, ns, mount.repo)
      assert Mount.resource(identity, Membership) == Driftwood.Operator.Membership
      assert Ash.Resource.Info.resource?(Driftwood.Operator.Membership)
    end

    test "GREEN (live): a seeded ADMIN resolves as a billing admin; a MEMBER does not" do
      org_id = Ash.UUID.generate()
      _ = seed_billing_settings(org_id)
      Application.put_env(:samen_core, :billing_provider, {FakeProvider, %{}})
      on_exit(fn -> Application.delete_env(:samen_core, :billing_provider) end)

      admin = seed_member!(org_id, :admin)
      member = seed_member!(org_id, :member)

      mount = router_billing_mount()
      assert mount_socket(mount, org_id, admin).assigns.billing_admin? == true
      assert mount_socket(mount, org_id, member).assigns.billing_admin? == false
    end

    test "REFUTABILITY: the SAME billing mount with :identity_namespace STRIPPED resolves a seeded admin fail-CLOSED" do
      org_id = Ash.UUID.generate()
      _ = seed_billing_settings(org_id)
      Application.put_env(:samen_core, :billing_provider, {FakeProvider, %{}})
      on_exit(fn -> Application.delete_env(:samen_core, :billing_provider) end)

      admin = seed_member!(org_id, :admin)

      wired = router_billing_mount()
      assert mount_socket(wired, org_id, admin).assigns.billing_admin? == true

      stripped = %{wired | labels: Map.delete(wired.labels, :identity_namespace)}
      assert mount_socket(stripped, org_id, admin).assigns.billing_admin? == false
    end
  end
end
