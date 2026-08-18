defmodule Samen.Web.IdentityNamespaceCoverageTest do
  @moduledoc """
  Residual A (Batch 7) — the framework-wide `:identity_namespace` ENUMERATING guard.

  Batch 2 (PP-5) made the tenant-plane Billing writes admin-gated by the caller's REAL per-org
  `Membership` role, resolved through the `:identity_namespace` sibling-mount seam (the billing
  mount's own Billing scope materializes no `Membership`). Batch 5a wired the label on pawchart
  and added a pawchart-SCOPED guard (`PawChart.BillingRoleGateTest`). This test closes the class
  the way `Samen.Web.TenantAuthnCoverageTest` closed the `:authn` class: an ENUMERATING guard,
  off REAL compiled routers, asserting the SECURITY PROPERTY for EVERY role-gated billing mount —

      every host billing mount either WIRES :identity_namespace at an identity-materializing
      namespace (→ the real role resolves), OR resolves FAIL-CLOSED by construction (no admin).

  There is no third bucket: a role-gated billing mount can never be "unlabeled yet resolve an
  admin" (the fail-OPEN hole). A future vertical that forgets the label ships billing silently
  non-functional (safe), and is caught here rather than in production.

  Paired red/control (anti-tautology, `Samen.RedPath` spirit):
    * GREEN — a WIRED billing mount (label → `Samen.WebTest.Operator`, which materializes
      `Membership`) resolves a seeded admin as `billing_admin?: true`.
    * PROPERTY — enumerated across BOTH shapes, every billing mount satisfies the disjunction
      above; the UNWIRED mount fails closed for the SAME seeded admin (safe-because-denied).
    * REFUTABILITY — the WIRED mount with `:identity_namespace` STRIPPED resolves the same admin
      FAIL-CLOSED: proves the GREEN is produced by the label, not vacuously true.
  """
  use Samen.WebTest.DataCase, async: false

  alias Samen.Web.Billing.SettingsLive
  alias Samen.Web.Mount
  alias Samen.WebTest.BillingRole.{UnwiredBillingRouter, WiredBillingRouter}

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

  setup do
    Application.put_env(:samen_core, :billing_provider, {FakeProvider, %{}})
    on_exit(fn -> Application.delete_env(:samen_core, :billing_provider) end)
    :ok
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

    Samen.WebTest.Billing.Customer
    |> Ash.Changeset.for_create(
      :create,
      %{
        org_id: org_id,
        billing_name: "Coverage Fixture Holdings",
        billing_email: "coverage.fixture@example.test",
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
      Samen.WebTest.Operator.User
      |> Ash.Changeset.for_create(:create, %{org_id: org_id, handle: "billing-#{role}-#{System.unique_integer([:positive])}"})
      |> Ash.create!(authorize?: false)

    Samen.WebTest.Operator.Membership
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

  # `billing_admin?` a seeded admin resolves against this mount (the observable security
  # outcome of the `:identity_namespace` seam: true = real role resolved, false = fail-closed).
  defp admin_resolves?(mount, org_id, admin), do: mount_socket(mount, org_id, admin).assigns.billing_admin?

  # Enumerate the tenant Billing mount off a compiled router (never hand-built).
  defp billing_mount(router) do
    {_path, mount} =
      router.__routes__()
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

  # Does this billing mount's `:identity_namespace` point at a namespace that materializes
  # `Membership` (the role source)? This is the "WIRED" branch of the class disjunction.
  defp wired_to_membership?(mount) do
    case Mount.label(mount, :identity_namespace, nil) do
      ns when is_atom(ns) and not is_nil(ns) ->
        Ash.Resource.Info.resource?(Mount.resource(Mount.new(:settings, ns, mount.repo), Membership))

      _ ->
        false
    end
  end

  # ==========================================================================
  # GREEN — the WIRED billing mount resolves the real admin role.
  # ==========================================================================

  describe "GREEN: a billing mount that WIRES :identity_namespace resolves the real per-org role" do
    test "a WIRED mount → a seeded ADMIN is a billing admin (the role resolves)" do
      org_id = Ash.UUID.generate()
      _ = seed_billing_settings(org_id)
      admin = seed_member!(org_id, :admin)

      assert admin_resolves?(billing_mount(WiredBillingRouter), org_id, admin) == true
    end

    test "a WIRED mount → a seeded MEMBER is NOT a billing admin (role gate, not plane gate)" do
      org_id = Ash.UUID.generate()
      _ = seed_billing_settings(org_id)
      member = seed_member!(org_id, :member)

      assert admin_resolves?(billing_mount(WiredBillingRouter), org_id, member) == false
    end
  end

  # ==========================================================================
  # PROPERTY — every enumerated billing mount WIRES or fail-closes (no fail-open).
  # ==========================================================================

  describe "the class property — every role-gated billing mount WIRES :identity_namespace OR fails closed" do
    test "ENUMERATED across both shapes: each billing mount either wires membership OR denies a seeded admin" do
      org_id = Ash.UUID.generate()
      _ = seed_billing_settings(org_id)
      admin = seed_member!(org_id, :admin)

      mounts = [billing_mount(WiredBillingRouter), billing_mount(UnwiredBillingRouter)]

      # Non-vacuous: the enumeration found REAL billing mounts of BOTH postures.
      assert length(mounts) == 2
      assert Enum.all?(mounts, &match?(%Mount{scope_kind: :billing}, &1))
      assert Enum.any?(mounts, &wired_to_membership?/1)
      refute Enum.all?(mounts, &wired_to_membership?/1)

      for mount <- mounts do
        wired? = wired_to_membership?(mount)
        admin? = admin_resolves?(mount, org_id, admin)

        # The security property: WIRED ⇒ the admin role resolves; NOT wired ⇒ fail-closed.
        # In particular there is NO mount that is unlabeled yet resolves an admin (fail-OPEN).
        assert wired? == admin?,
               "billing mount broke the :identity_namespace property (wired?=#{wired?}, " <>
                 "admin_resolved?=#{admin?}) — either a WIRED mount failed to resolve the role, " <>
                 "or an UNWIRED mount resolved an admin (the fail-OPEN hole)"
      end
    end

    test "the UNWIRED mount fails CLOSED for a seeded admin (safe-because-denied, not fail-open)" do
      org_id = Ash.UUID.generate()
      _ = seed_billing_settings(org_id)
      admin = seed_member!(org_id, :admin)

      unwired = billing_mount(UnwiredBillingRouter)
      refute wired_to_membership?(unwired)
      assert admin_resolves?(unwired, org_id, admin) == false
    end
  end

  # ==========================================================================
  # REFUTABILITY — stripping the label flips the WIRED mount fail-closed.
  # ==========================================================================

  test "REFUTABILITY: the WIRED mount with :identity_namespace STRIPPED denies the same seeded admin" do
    org_id = Ash.UUID.generate()
    _ = seed_billing_settings(org_id)
    admin = seed_member!(org_id, :admin)

    wired = billing_mount(WiredBillingRouter)
    assert admin_resolves?(wired, org_id, admin) == true

    stripped = %{wired | labels: Map.delete(wired.labels, :identity_namespace)}
    refute wired_to_membership?(stripped)
    assert admin_resolves?(stripped, org_id, admin) == false
  end
end
