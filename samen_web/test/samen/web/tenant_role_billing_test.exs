defmodule Samen.Web.TenantRoleBillingTest.FakeProvider do
  @moduledoc false
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

defmodule Samen.Web.TenantRoleBillingTest do
  @moduledoc """
  ADR-045 §4.4 residual (the `:member` default), Billing: the overview, invoices, plans, dunning, usage and settings pages
  act with the role the signed-in person's ACTIVE membership resolves to (`Samen.Web.TenantActor`), never `Plane.scope/2`'s
  fixed `:member`.

  Driven with a REAL spine login (`POST /login`) and the REAL tenant gate (`Samen.WebTest.RoleHarness`); every refusal is
  paired with a positive control.

  Policy (the blueprint): reads are not role-gated. `Subscription`, `Plan`, `Price`, `Invoice`, `Payment` and `Entitlement`
  writes are `RoleAtLeast :admin`. `Customer` only checks the org in the kernel, so the PAGE requires a member to create a
  customer (the rank of every other tenant write of these surfaces). Subscribing and the payment-method portal are admin's
  (the settings page's own rule).
  """
  use Samen.WebTest.DataCase, async: false

  alias Samen.Web.Billing.{DunningLive, InvoicesLive, OverviewLive, PlansLive, SettingsLive, UsageLive}
  alias Samen.WebTest.RoleHarness, as: H
  alias Samen.WebTest.SpineAccounts
  alias Samen.Web.TenantRoleBillingTest.FakeProvider

  setup do
    H.setup_accounts()
  end

  defp html(view, socket), do: render_html(view, socket.assigns)

  # -- seeds (system context) ---------------------------------------------------------------------------------

  defp customer!(org_id, name \\ "Probe Customer Co") do
    Samen.WebTest.Billing.Customer
    |> Ash.Changeset.for_create(:create, %{org_id: org_id, billing_name: name, status: :active, provider_customer_ref: "cus_1"}, authorize?: false)
    |> Ash.create!()
  end

  defp plan!(org_id, name) do
    Samen.WebTest.Billing.Plan
    |> Ash.Changeset.for_create(:create, %{org_id: org_id, name: name, label: "Plan #{name}", interval: :monthly, enabled: true}, authorize?: false)
    |> Ash.create!()
  end

  defp subscription!(org_id, customer, plan) do
    Samen.WebTest.Billing.Subscription
    |> Ash.Changeset.for_create(:create, %{org_id: org_id, customer_id: customer.id, plan_id: plan.id, status: :active}, authorize?: false)
    |> Ash.create!()
  end

  defp invoice!(org_id, customer) do
    Samen.WebTest.Billing.Invoice
    |> Ash.Changeset.for_create(:create, %{org_id: org_id, customer_id: customer.id, status: :open, amount_due_cents: 1_000, currency: "USD"}, authorize?: false)
    |> Ash.create!()
  end

  defp price!(org_id, plan) do
    Samen.WebTest.Billing.Price
    |> Ash.Changeset.for_create(
      :create,
      %{org_id: org_id, plan_id: plan.id, unit_amount: Samen.Type.Money.from_cents(900, :USD), interval: :monthly, active: true, provider_price_ref: "price_1"},
      authorize?: false
    )
    |> Ash.create!()
  end

  defp rows(resource, org_id, select) do
    resource |> Ash.Query.ensure_selected([:org_id | select]) |> Ash.read!(authorize?: false) |> Enum.filter(&(&1.org_id == org_id))
  end

  defp customers(org_id), do: rows(Samen.WebTest.Billing.Customer, org_id, [:billing_name])
  defp invoices(org_id), do: rows(Samen.WebTest.Billing.Invoice, org_id, [:status])
  defp plans(org_id), do: rows(Samen.WebTest.Billing.Plan, org_id, [:name, :enabled])
  defp subscriptions(org_id), do: rows(Samen.WebTest.Billing.Subscription, org_id, [:status])

  defp seed(org_id) do
    customer = customer!(org_id)
    plan = plan!(org_id, "probe")
    price!(org_id, plan)
    sub = subscription!(org_id, customer, plan)
    invoice = invoice!(org_id, customer)
    %{customer: customer, plan: plan, sub: sub, invoice: invoice}
  end

  defp pages(org_id) do
    seeded = seed(org_id)

    [
      %{name: "OverviewLive", view: OverviewLive, path: "/billing", extra: %{}, events: [{"new_customer", %{}}, {"delete", %{"id" => seeded.sub.id}}]},
      %{name: "InvoicesLive", view: InvoicesLive, path: "/billing/invoices", extra: %{}, events: [{"new_invoice", %{}}, {"delete", %{"id" => seeded.invoice.id}}]},
      %{name: "PlansLive", view: PlansLive, path: "/billing/plans", extra: %{}, events: [{"new_plan", %{}}, {"delete", %{"id" => seeded.plan.id}}, {"toggle_plan", %{"id" => seeded.plan.id}}]},
      %{name: "DunningLive", view: DunningLive, path: "/billing/dunning", extra: %{}, events: [{"retry_load", %{}}]},
      %{name: "UsageLive", view: UsageLive, path: "/billing/usage", extra: %{}, events: [{"retry_load", %{}}]},
      %{name: "SettingsLive", view: SettingsLive, path: "/billing/settings", extra: %{}, events: [{"checkout", %{"plan_id" => seeded.plan.id}}, {"manage_payment_method", %{}}]}
    ]
  end

  # -- every page acts as the RESOLVED role --------------------------------------------------------------------

  test "every Billing page acts with the RESOLVED role, not :member", ctx do
    logins = for who <- [:viewer, :member, :admin, :owner], into: %{}, do: {who, H.log_in(Map.fetch!(ctx, who))}

    for page <- pages(ctx.org_id), role <- [:viewer, :member, :admin, :owner] do
      socket = H.live_socket(Map.fetch!(logins, role), page.view, page.path, ctx.org_id, page.extra)
      assert socket.assigns.actor_state == :ok, page.name
      assert socket.assigns.acting_scope.actor.role == role, "#{page.name} acted as #{socket.assigns.acting_scope.actor.role}, not #{role}"
      assert socket.assigns.acting_scope.actor.resolved == true
      refute String.starts_with?(socket.assigns.acting_scope.actor.id, "broker:")
    end
  end

  test "NAVIGATION: a suspended member's page is the denied state: nothing is read, no event reads or writes", ctx do
    pages = pages(ctx.org_id)
    login = H.log_in(ctx.member)
    sockets = for page <- pages, do: {page, H.live_socket(login, page.view, page.path, ctx.org_id, page.extra)}

    # positive control: while acting, the data pages show the seeded customer
    for {page, socket} <- sockets, page.view in [OverviewLive, InvoicesLive] do
      assert html(page.view, socket) =~ "Probe Customer Co", "#{page.name}: nothing to read while acting (vacuous control)"
    end

    before = {length(customers(ctx.org_id)), length(invoices(ctx.org_id)), length(plans(ctx.org_id)), length(subscriptions(ctx.org_id))}
    SpineAccounts.suspend!(ctx.member, ctx.org_id)

    for {page, socket} <- sockets do
      refused = H.params(page.view, socket, page.extra)
      assert refused.assigns.actor_state == :denied, page.name
      assert refused.assigns.acting_scope == nil, page.name
      out = html(page.view, refused)
      assert out =~ ~s(id="actor-denied"), page.name
      refute out =~ "Probe Customer Co", page.name

      for {name, p} <- page.events do
        assert H.event(page.view, name, p, refused).assigns == refused.assigns, "#{page.name} #{name} changed the refused page"
      end
    end

    assert before == {length(customers(ctx.org_id)), length(invoices(ctx.org_id)), length(plans(ctx.org_id)), length(subscriptions(ctx.org_id))}
    assert Enum.all?(plans(ctx.org_id), & &1.enabled)
  end

  test "a failed membership lookup is the UNAVAILABLE state on every Billing page, never an empty page", ctx do
    login = H.log_in(ctx.member)

    for page <- pages(ctx.org_id) do
      socket = H.live_socket(login, page.view, page.path, ctx.org_id, page.extra) |> H.break_identity()
      {refused, _log} = ExUnit.CaptureLog.with_log(fn -> H.params(page.view, socket, page.extra) end)
      assert refused.assigns.actor_state == :unavailable, page.name
      assert refused.assigns.acting_scope == nil
      out = html(page.view, refused)
      assert out =~ ~s(id="actor-unavailable"), page.name
      refute out =~ "Probe Customer Co"
    end
  end

  test "OPEN PAGE: an admin demoted or suspended while Plans is open writes nothing at the next event; an unchanged admin does", ctx do
    keep = plan!(ctx.org_id, "keep")
    lose = plan!(ctx.org_id, "lose")
    login = H.log_in(ctx.admin)

    open = H.open_socket(login, PlansLive, "/billing/plans", ctx.org_id)
    assert open.assigns.can_admin
    # positive control: the same event as an admin
    H.live_event(PlansLive, "toggle_plan", %{"id" => lose.id}, open)
    refute Enum.find(plans(ctx.org_id), &(&1.id == lose.id)).enabled

    SpineAccounts.set_role!(ctx.admin, ctx.org_id, :member)
    demoted = H.live_event(PlansLive, "toggle_plan", %{"id" => keep.id}, open)
    assert demoted.assigns.acting_scope.actor.role == :member
    refute demoted.assigns.can_admin
    assert Enum.find(plans(ctx.org_id), &(&1.id == keep.id)).enabled
    demoted = H.live_event(PlansLive, "delete", %{"id" => keep.id}, demoted)
    assert demoted.assigns.delete_error == "Could not delete this plan."
    assert Enum.find(plans(ctx.org_id), &(&1.id == keep.id))
    # the form built before the demotion is rebuilt with the member's scope
    demoted = H.live_event(PlansLive, "save_new", %{"form" => %{"name" => "sneaky", "label" => "Sneaky", "interval" => "monthly"}}, demoted)
    refute Enum.any?(plans(ctx.org_id), &(&1.name == "sneaky"))

    SpineAccounts.suspend!(ctx.admin, ctx.org_id)
    gone = H.live_event(PlansLive, "toggle_plan", %{"id" => keep.id}, demoted)
    assert gone.assigns.actor_state == :denied
    assert Enum.find(plans(ctx.org_id), &(&1.id == keep.id)).enabled
  end

  # -- writes -------------------------------------------------------------------------------------------------

  describe "OverviewLive writes (customer: member by the page; subscription delete: admin)" do
    test "a VIEWER cannot create a customer; a MEMBER can but cannot delete a subscription; an admin can", ctx do
      seeded = seed(ctx.org_id)
      before = length(customers(ctx.org_id))
      path = "/billing"

      create = fn account, name ->
        socket = H.live_socket(H.log_in(account), OverviewLive, path, ctx.org_id)
        socket = H.event(OverviewLive, "new_customer", %{}, socket)
        H.event(OverviewLive, "save_new", %{"form" => %{"billing_name" => name, "billing_email" => "x@example.test", "currency" => "USD"}}, socket)
      end

      create.(ctx.viewer, "Viewer Customer")
      assert length(customers(ctx.org_id)) == before
      viewer = H.live_socket(H.log_in(ctx.viewer), OverviewLive, path, ctx.org_id)
      viewer = H.event(OverviewLive, "delete", %{"id" => seeded.sub.id}, viewer)
      assert viewer.assigns.delete_error
      assert length(subscriptions(ctx.org_id)) == 1

      create.(ctx.member, "Member Customer")
      assert length(customers(ctx.org_id)) == before + 1
      member = H.live_socket(H.log_in(ctx.member), OverviewLive, path, ctx.org_id)
      member = H.event(OverviewLive, "delete", %{"id" => seeded.sub.id}, member)
      assert member.assigns.delete_error
      assert length(subscriptions(ctx.org_id)) == 1

      admin = H.live_socket(H.log_in(ctx.admin), OverviewLive, path, ctx.org_id)
      H.event(OverviewLive, "delete", %{"id" => seeded.sub.id}, admin)
      assert subscriptions(ctx.org_id) == []
    end
  end

  describe "InvoicesLive writes (admin)" do
    test "a VIEWER and a MEMBER cannot create or delete an invoice; an admin can", ctx do
      seeded = seed(ctx.org_id)
      before = length(invoices(ctx.org_id))
      path = "/billing/invoices"

      create = fn account ->
        socket = H.live_socket(H.log_in(account), InvoicesLive, path, ctx.org_id)
        socket = H.event(InvoicesLive, "new_invoice", %{}, socket)
        H.event(InvoicesLive, "save_new", %{"form" => %{"customer_id" => seeded.customer.id, "amount_due_cents" => "500", "status" => "open", "currency" => "USD"}}, socket)
      end

      for account <- [ctx.viewer, ctx.member] do
        create.(account)
        assert length(invoices(ctx.org_id)) == before
        socket = H.live_socket(H.log_in(account), InvoicesLive, path, ctx.org_id)
        socket = H.event(InvoicesLive, "delete", %{"id" => seeded.invoice.id}, socket)
        assert socket.assigns.delete_error
        assert length(invoices(ctx.org_id)) == before
      end

      create.(ctx.admin)
      assert length(invoices(ctx.org_id)) == before + 1
      admin = H.live_socket(H.log_in(ctx.admin), InvoicesLive, path, ctx.org_id)
      H.event(InvoicesLive, "delete", %{"id" => seeded.invoice.id}, admin)
      assert length(invoices(ctx.org_id)) == before
    end
  end

  describe "PlansLive writes (admin)" do
    test "a VIEWER and a MEMBER cannot create, toggle, edit features of, or delete a plan; an admin can", ctx do
      seeded = seed(ctx.org_id)
      path = "/billing/plans"
      before = length(plans(ctx.org_id))

      for account <- [ctx.viewer, ctx.member] do
        socket = H.live_socket(H.log_in(account), PlansLive, path, ctx.org_id)
        socket = H.event(PlansLive, "new_plan", %{}, socket)
        socket = H.event(PlansLive, "save_new", %{"form" => %{"name" => "denied", "label" => "Denied", "interval" => "monthly"}}, socket)
        assert length(plans(ctx.org_id)) == before

        socket = H.event(PlansLive, "toggle_plan", %{"id" => seeded.plan.id}, socket)
        assert socket.assigns.delete_error == "Could not update this plan."
        assert Enum.find(plans(ctx.org_id), &(&1.id == seeded.plan.id)).enabled

        socket = H.event(PlansLive, "toggle_feature", %{"id" => seeded.plan.id, "feature" => "sso"}, socket)
        assert socket.assigns.delete_error == "Could not update plan features."

        socket = H.event(PlansLive, "grant_ent", %{"subscription_id" => seeded.sub.id, "feature" => "sso"}, socket)
        assert socket.assigns.delete_error == "Could not grant this entitlement."

        socket = H.event(PlansLive, "delete", %{"id" => seeded.plan.id}, socket)
        assert socket.assigns.delete_error == "Could not delete this plan."
        assert length(plans(ctx.org_id)) == before
      end

      admin = H.live_socket(H.log_in(ctx.admin), PlansLive, path, ctx.org_id)
      admin = H.event(PlansLive, "new_plan", %{}, admin)
      admin = H.event(PlansLive, "save_new", %{"form" => %{"name" => "granted", "label" => "Granted", "interval" => "monthly"}}, admin)
      assert length(plans(ctx.org_id)) == before + 1
      admin = H.event(PlansLive, "toggle_plan", %{"id" => seeded.plan.id}, admin)
      refute Enum.find(plans(ctx.org_id), &(&1.id == seeded.plan.id)).enabled
      H.event(PlansLive, "delete", %{"id" => seeded.plan.id}, admin)
      assert length(plans(ctx.org_id)) == before
    end
  end

  describe "SettingsLive writes (subscribe, payment portal: admin)" do
    setup do
      Application.put_env(:samen_core, :billing_provider, {FakeProvider, %{}})
      on_exit(fn -> Application.delete_env(:samen_core, :billing_provider) end)
    end

    test "a VIEWER and a MEMBER cannot start checkout or open the portal; an admin and an owner can", ctx do
      seeded = seed(ctx.org_id)
      path = "/billing/settings"

      for account <- [ctx.viewer, ctx.member] do
        socket = H.live_socket(H.log_in(account), SettingsLive, path, ctx.org_id)
        refute socket.assigns.billing_admin?
        socket = H.event(SettingsLive, "checkout", %{"plan_id" => seeded.plan.id}, socket)
        assert socket.assigns.checkout_error == "Only an admin can manage billing for this workspace."
        assert socket.redirected == nil
        socket = H.event(SettingsLive, "manage_payment_method", %{}, socket)
        assert socket.assigns.portal_error == "Only an admin can manage billing for this workspace."
        assert socket.redirected == nil
      end

      for account <- [ctx.admin, ctx.owner] do
        socket = H.live_socket(H.log_in(account), SettingsLive, path, ctx.org_id)
        assert socket.assigns.billing_admin?
        socket = H.event(SettingsLive, "checkout", %{"plan_id" => seeded.plan.id}, socket)
        assert socket.redirected == {:redirect, %{external: "https://checkout.fake.test/cs_fake_1", status: 302}}
      end
    end

    test "OPEN PAGE: an admin demoted while Settings is open can no longer subscribe", ctx do
      seeded = seed(ctx.org_id)
      open = H.open_socket(H.log_in(ctx.admin), SettingsLive, "/billing/settings", ctx.org_id)
      assert open.assigns.billing_admin?
      SpineAccounts.set_role!(ctx.admin, ctx.org_id, :viewer)
      after_event = H.live_event(SettingsLive, "checkout", %{"plan_id" => seeded.plan.id}, open)
      refute after_event.assigns.billing_admin?
      assert after_event.assigns.checkout_error == "Only an admin can manage billing for this workspace."
      assert after_event.redirected == nil
    end
  end

  describe "write controls follow the acting role" do
    test "the pages offer a control only to a role that can use it", ctx do
      seed(ctx.org_id)
      logins = %{viewer: H.log_in(ctx.viewer), member: H.log_in(ctx.member), admin: H.log_in(ctx.admin)}

      # {view, path, controls offered from :member, controls offered from :admin}
      pages = [
        {OverviewLive, "/billing", ["new-customer"], [~s(phx-click="delete")]},
        {InvoicesLive, "/billing/invoices", [], ["new-invoice", ~s(phx-click="delete")]},
        {PlansLive, "/billing/plans", [], ["new-plan", "manage-entitlements", ~s(phx-click="delete")]}
      ]

      for {view, path, member_controls, admin_controls} <- pages do
        render = fn who -> html(view, H.live_socket(logins[who], view, path, ctx.org_id)) end
        {viewer, member, admin} = {render.(:viewer), render.(:member), render.(:admin)}

        for control <- member_controls ++ admin_controls do
          assert admin =~ control, "#{inspect(view)}: the admin's page has no #{control} (vacuous)"
          refute viewer =~ control, "#{inspect(view)}: the viewer's page offers #{control}"
        end

        for control <- member_controls, do: assert(member =~ control)
        for control <- admin_controls, do: refute(member =~ control, "#{inspect(view)}: the member's page offers #{control}")
      end
    end
  end
end
